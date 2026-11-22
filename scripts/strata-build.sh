#!/usr/bin/env bash
# 编译并安装 Strata（CUDA 引擎 + Python 终端）到当前 pixi 环境 prefix
#
# 后端由 $STRATA_BACKEND 决定（strata-cuda → cuda）
# 所需环境变量（由 pixi 注入）:
#   PIXI_PROJECT_ROOT, STRATA_VERSION, STRATA_BACKEND,
#   CONDA_PREFIX, CMAKE_PREFIX_PATH, CUDACXX（仅 cuda）
# 可选环境变量:
#   STRATA_BUILD_DIR    主引擎构建目录（相对源码目录，默认 build-${BACKEND}）
#   STRATA_CUDA_ARCHS   CUDA 架构（默认 = 本机 GPU 探测出的架构号，如 120；
#                       跨卡发行可设 "75;86;89;120"，见 packaging/build_cuda_linux.sh）
#   STRATA_CMAKE_EXTRA  追加 cmake 参数（如 -DSTRATA_GEOMETRY=<name>）
#   STRATA_DSV41_BUILD_DIR / STRATA_VISION_BUILD_DIR  覆盖对应构建目录
#   STRATA_VISION_LLAMA_DIR  覆盖 strata-vision 用的 llama.cpp 源码目录
#
# 默认一次构建三个必需产物（都装进 $CONDA_PREFIX/bin）：
#   strata-engine   主引擎（flash_next 形状，Qwen3.8-Flash-Next 等）
#   strata-dsv41    DeepSeek-V4.1 引擎（独立构建目录：BMI2 等缓存级选项
#                   与主引擎冲突，共用会互相污染）
#   strata-vision   图片编码器（tools/vision 独立 CMake 工程；QFN 多模态
#                   必需——run config 有 vision 段而缺它时模型起不来）
set -euo pipefail

BACKEND="${STRATA_BACKEND:-}"
if [ -z "$BACKEND" ]; then
    echo "FATAL: STRATA_BACKEND 未设置（须在 strata-cuda 环境中运行）" >&2
    exit 1
fi

case "$BACKEND" in
    cuda) ;;
    *)
        echo "FATAL: unknown backend '$BACKEND' (expected cuda)" >&2
        exit 1
        ;;
esac

V="${STRATA_VERSION#v}"
SRC_DIR="$PIXI_PROJECT_ROOT/download/Strata-$V"
test -d "$SRC_DIR" || { echo "FATAL: 源码目录 $SRC_DIR 不存在（先跑 strata-src）"; exit 1; }

# CUDA 架构：默认探测本机 GPU（取最高 compute_cap → 架构号）。
# 不用 "native"：v0.2.4.2 等旧版的 NVFP4 W4A4 单元 12x→12xa 重写只认数字
# 架构，"native" 会原样透传给 ptxas 而拒编 sm_120 的 FP4 MMA（上游 #4023；
# v0.2.13 的 cuda.cmake 补了 native 预处理，显式架构号对两个版本都正确）
ARCHS="${STRATA_CUDA_ARCHS:-}"
if [ -z "$ARCHS" ]; then
    CCAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | sort -Vu | tail -1)
    ARCHS=$(echo "${CCAP:-}" | tr -d '.')
fi
[ -n "$ARCHS" ] || { echo "FATAL: 探测不到 GPU 架构（nvidia-smi compute_cap），请显式设 STRATA_CUDA_ARCHS（如 120）" >&2; exit 1; }

# 编译器：显式指向 conda 交叉工具链。CMake 4.x 的 enable_language(C/CXX) 在
# pixi task 上下文里读不到 CC/CXX 环境变量（手动 `pixi run -- bash` 能读到），
# 干净缓存目录会报 "CMAKE_C_COMPILER not set, after EnableLanguage"。
HOST_CC="$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-cc"
HOST_CXX="$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-g++"
[ -x "$HOST_CC" ] && [ -x "$HOST_CXX" ] || { echo "FATAL: conda 交叉编译器缺失：$HOST_CC / $HOST_CXX" >&2; exit 1; }
COMPILER_ARGS=(-DCMAKE_C_COMPILER="$HOST_CC" -DCMAKE_CXX_COMPILER="$HOST_CXX")

# 构建目录（相对源码目录）：按后端区分，避免 CMake 缓存互相污染
BUILD_DIR="${STRATA_BUILD_DIR:-build-$BACKEND}"
cd "$SRC_DIR"

# 构建缓存失效防护（与 llamacpp-build.sh 相同策略）:
# 1. 缓存记录的编译器路径已不存在（环境路径变了）
if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    CACHED_CC=$(grep -E '^CMAKE_C_COMPILER:' "$BUILD_DIR/CMakeCache.txt" | cut -d= -f2-)
    if [ -n "$CACHED_CC" ] && [ ! -x "$CACHED_CC" ]; then
        echo "CMake 缓存引用了不存在的编译器 ${CACHED_CC}，清除构建缓存"
        rm -rf "$BUILD_DIR"
    fi
fi
# 2. 工具链被 re-lock/重装替换 → 旧构建文件的链接引用全部失效
TOOL_FP="$(stat -c '%Y' "$(command -v gcc)" 2>/dev/null)-$(cmake --version 2>/dev/null | head -1)-$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/cuda-\1/p' | head -1)"
FP_FILE="$BUILD_DIR/.toolchain-fingerprint"
if [ -f "$FP_FILE" ] && [ "$(cat "$FP_FILE" 2>/dev/null)" != "$TOOL_FP" ]; then
    echo "检测到工具链变化（gcc/cmake/nvcc 被替换），清除构建缓存"
    rm -rf "$BUILD_DIR"
fi

# 发布构建基线（packaging/build_cuda_linux.sh, VARIANT=cuda13）的单机版：
#  - STRATA_PORTABLE 不开：CPU 回退按本机编译（ggml-cpu native），
#    portable 是"发到别的机器"的 AVX2 基线，本环境只服务本机
#  - STRATA_GGML_DIR 不传：新版用仓库 vendored 的 third_party/strata-ggml
#    （STRATA_MMQ_TAB 指针表 MMQ 针对它验证，效果最好）；v0.2.4.2 等旧版
#    的 ggml 走 CMake FetchContent(llama.cpp@pinned)，strata-src.sh 已预下载，
#    下面用 FETCHCONTENT_SOURCE_DIR_* 指过去（构建机 github git 不可达）
#  - 默认 STRATA_GEOMETRY=flash_next（Qwen3.8-Flash-Next 形状），
#    其他形状用 STRATA_CMAKE_EXTRA="-DSTRATA_GEOMETRY=<name>"
EXTRA=()
[ -n "${STRATA_CMAKE_EXTRA:-}" ] && read -r -a EXTRA <<< "$STRATA_CMAKE_EXTRA"

FETCH_ARGS=()
if grep -q "FetchContent_Declare(strata_llamacpp" CMakeLists.txt; then
    GG_COMMIT=$(grep -oE "GIT_TAG [0-9a-f]{40}" CMakeLists.txt | awk '{print $2}' | head -1)
    GG_DIR="$PIXI_PROJECT_ROOT/download/llama.cpp-${GG_COMMIT:0:12}"
    test -d "$GG_DIR/ggml" || { echo "FATAL: $GG_DIR 缺失（strata-src.sh 应已下载 llama.cpp@${GG_COMMIT:0:12}）"; exit 1; }
    FETCH_ARGS=(-DFETCHCONTENT_SOURCE_DIR_STRATA_LLAMACPP="$GG_DIR")
fi

cmake -B "$BUILD_DIR" \
    -G Ninja \
    -S . \
    -DCMAKE_BUILD_TYPE=Release \
    "${COMPILER_ARGS[@]}" \
    -DSTRATA_ENABLE_CUDA=ON \
    -DSTRATA_BUILD_TESTS=OFF \
    -DSTRATA_NATIVE_EXPERTS=ON \
    -DSTRATA_Q6K_EXPERTS=ON \
    -DSTRATA_MMQ_KQUANTS=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" \
    "${FETCH_ARGS[@]}" \
    "${EXTRA[@]}"
cmake --build "$BUILD_DIR" --target strata strata_kq strata-device -j
echo "$TOOL_FP" > "$FP_FILE"

# --- 安装引擎到 $CONDA_PREFIX/bin ---
# 引擎名 strata-engine（官方名 strata 留给 Python 终端启动器，
# server 通过 run config 里的绝对路径调用引擎，改名无副作用）
BIN="$CONDA_PREFIX/bin"
install -m 755 "$BUILD_DIR/strata" "$BIN/strata-engine"
install -m 755 "$BUILD_DIR/strata-device" "$BIN/strata-device"
KQ_LIB=0
if [ -f "$BUILD_DIR/libstrata_kq.so" ]; then
    install -m 755 "$BUILD_DIR/libstrata_kq.so" "$BIN/"
    KQ_LIB=1
fi
# 仓库无 CMake install 规则：手动设 RPATH 指向环境 lib（CUDA 运行库）
# （llama.cpp 用 CMAKE_INSTALL_RPATH 达到同样效果）
patchelf --set-rpath '$ORIGIN/../lib' "$BIN/strata-engine" "$BIN/strata-device"
[ "$KQ_LIB" = 1 ] && patchelf --set-rpath '$ORIGIN/../lib' "$BIN/libstrata_kq.so"
# 引擎从自己的目录 dlopen libstrata_kq.so（mmq_kq_loader.cpp），
# 故它必须与 strata-engine 同目录（上面已装入 bin/）

# --- DeepSeek-V4.1 引擎（标配产物，独立构建目录）---
# 独立构建目录：STRATA_BUILD_DSV41 会改 ggml-cpu 的 BMI2 等缓存级选项，
# 与主引擎共用 build 目录会互相污染（官方 packaging/build_dsv41_cuda.sh 同理）
DSV_BUILD_DIR="${STRATA_DSV41_BUILD_DIR:-build-$BACKEND-dsv41}"
DSV_EXTRA=()
[ -n "${STRATA_CMAKE_EXTRA:-}" ] && read -r -a DSV_EXTRA <<< "$STRATA_CMAKE_EXTRA"
cmake -B "$DSV_BUILD_DIR" \
    -G Ninja \
    -S . \
    -DCMAKE_BUILD_TYPE=Release \
    "${COMPILER_ARGS[@]}" \
    -DSTRATA_ENABLE_CUDA=ON \
    -DSTRATA_BUILD_TESTS=OFF \
    -DSTRATA_BUILD_DSV41=ON \
    -DSTRATA_NATIVE_EXPERTS=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" \
    "${FETCH_ARGS[@]}" \
    "${DSV_EXTRA[@]}"
cmake --build "$DSV_BUILD_DIR" --target strata-dsv41 -j
install -m 755 "$DSV_BUILD_DIR/strata-dsv41" "$BIN/"
patchelf --set-rpath '$ORIGIN/../lib' "$BIN/strata-dsv41"
echo "installed strata-dsv41 to: $BIN"

# --- 图片编码器 strata-vision（标配产物，QFN 多模态必需）---
# tools/vision 是独立 CMake 工程（llama.cpp mtmd），与引擎同 llama.cpp pin /
# 同 CUDA 架构；run config 有 vision 段而缺它时，终端 server 启动编码器失败，
# 整个模型起不来
if [ -d tools/vision ]; then
    VISION_LLAMA_DIR="${STRATA_VISION_LLAMA_DIR:-${GG_DIR:-}}"
    if [ -z "$VISION_LLAMA_DIR" ] && [ -d third_party/llama.cpp ]; then
        VISION_LLAMA_DIR="$PWD/third_party/llama.cpp"
    fi
    test -n "$VISION_LLAMA_DIR" || { echo "FATAL: strata-vision 需要 llama.cpp 源码（设 STRATA_VISION_LLAMA_DIR）" >&2; exit 1; }
    VISION_BUILD_DIR="${STRATA_VISION_BUILD_DIR:-build-vision}"
    cmake -S tools/vision -B "$VISION_BUILD_DIR" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        "${COMPILER_ARGS[@]}" \
        -DLLAMA_DIR="$VISION_LLAMA_DIR" \
        -DSTRATA_VISION_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" \
        -DSTRATA_PORTABLE=OFF
    cmake --build "$VISION_BUILD_DIR" --target strata-vision -j
    install -m 755 "$VISION_BUILD_DIR/bin/strata-vision" "$BIN/strata-vision"
    patchelf --set-rpath '$ORIGIN/../lib' "$BIN/strata-vision"
    echo "installed strata-vision to: $BIN"
else
    echo "warning: 源码没有 tools/vision，跳过 strata-vision（该版本无图片功能？）" >&2
fi

# --- 安装 Python 终端到 $CONDA_PREFIX/strata ---
# strata.py 以自身位置定 ROOT，strata_cli/serve 按 ROOT 找 serve/ tools/ data/，
# 故整套 python 树拷入 prefix；依赖（jinja2 等）在环境 site-packages，无需 venv
APP_DIR="$CONDA_PREFIX/strata"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
for item in strata.py strata_cli strata_control serve data tools setup.py \
            requirements.txt requirements-build.txt requirements-monitor.txt; do
    [ -e "$SRC_DIR/$item" ] && cp -r "$SRC_DIR/$item" "$APP_DIR/"
done

# bin/strata 启动器：环境 python3 + prefix 内的 strata.py
cat > "$BIN/strata" <<'EOF'
#!/bin/sh
# Strata terminal launcher (pixi env): 环境 python3 + $CONDA_PREFIX/strata/strata.py
# PYTHONPATH 自设：pixi 激活时与 activation.env 一致，未激活直接调用也能跑
self=$(readlink -f -- "$0")
dir=$(dirname -- "$self")
PYTHONPATH="$dir/../strata${PYTHONPATH:+:$PYTHONPATH}" exec "$dir/python3" "$dir/../strata/strata.py" "$@"
EOF
chmod 755 "$BIN/strata"

echo "installed ($BACKEND) to: $BIN (engine) + $APP_DIR (terminal)"
