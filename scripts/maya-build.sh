#!/usr/bin/env bash
# 编译并安装 Project Maya 的 DeepSeek 引擎（maya-ds4）到当前 pixi 环境
#
# 后端由 $MAYA_BACKEND 决定（maya-cuda → cuda）
# 所需环境变量（由 pixi 注入）:
#   PIXI_PROJECT_ROOT, MAYA_VERSION, MAYA_BACKEND,
#   CONDA_PREFIX, CMAKE_PREFIX_PATH, CUDACXX（仅 cuda）
# 可选环境变量:
#   MAYA_BUILD_DIR     构建目录（相对源码目录，默认 build-${BACKEND}）
#   MAYA_CUDA_ARCHS    CUDA 架构（默认 = 本机 GPU 探测出的架构号，如 120；
#                      跨卡发行可设 "75;86;89;120"）
#   MAYA_CMAKE_EXTRA   追加 cmake 参数
#
# 构建三个产物（都装进 $CONDA_PREFIX/maya/build）：
#   maya           主引擎（GLM-5.3-Flash / GLM-5.3 / Qwen）
#   maya-ds4        DeepSeek-V4.1 引擎（maya.py 通过 run config 的 exe 调用）
#   strata-device   GPU 诊断/自检程序（maya-verify 用）
# Qwen3.8-Flash-Next 仍走 strata-cuda；这里的 maya 只用于 GLM 系。
set -euo pipefail

BACKEND="${MAYA_BACKEND:-}"
if [ -z "$BACKEND" ]; then
    echo "FATAL: MAYA_BACKEND 未设置（须在 maya-cuda 环境中运行）" >&2
    exit 1
fi

case "$BACKEND" in
    cuda) ;;
    *)
        echo "FATAL: unknown backend '$BACKEND' (expected cuda)" >&2
        exit 1
        ;;
esac

V="${MAYA_VERSION#v}"
SRC_DIR="$PIXI_PROJECT_ROOT/download/project-maya-$V"
test -d "$SRC_DIR" || { echo "FATAL: 源码目录 $SRC_DIR 不存在（先跑 maya-src）"; exit 1; }

# CUDA 架构：默认探测本机 GPU（取最高 compute_cap → 架构号）。
# 不用 "native"：与 strata-build 相同原因（ptxas 只认数字架构号）。
ARCHS="${MAYA_CUDA_ARCHS:-}"
if [ -z "$ARCHS" ]; then
    CCAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | sort -Vu | tail -1)
    ARCHS=$(echo "${CCAP:-}" | tr -d '.')
fi
[ -n "$ARCHS" ] || { echo "FATAL: 探测不到 GPU 架构（nvidia-smi compute_cap），请显式设 MAYA_CUDA_ARCHS（如 120）" >&2; exit 1; }

# 编译器：显式指向 conda 交叉工具链（CMake 4.x 在 pixi task 上下文里
# 读不到 CC/CXX 环境变量，干净缓存目录会报 CMAKE_C_COMPILER not set）
HOST_CC="$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-cc"
HOST_CXX="$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-g++"
[ -x "$HOST_CC" ] && [ -x "$HOST_CXX" ] || { echo "FATAL: conda 交叉编译器缺失：$HOST_CC / $HOST_CXX" >&2; exit 1; }
COMPILER_ARGS=(-DCMAKE_C_COMPILER="$HOST_CC" -DCMAKE_CXX_COMPILER="$HOST_CXX")

BUILD_DIR="${MAYA_BUILD_DIR:-build-$BACKEND}"
cd "$SRC_DIR"

# 构建缓存失效防护（与 strata-build.sh 相同策略）:
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

# ggml：上游 CMake 默认 FetchContent 拉 llama.cpp pin（构建机不可达），
# maya-src.sh 已预取；这里用 MAYA_GGML_DIR 指过去（与 strata-build 同款）。
GG_ARGS=()
if grep -q "FetchContent_Declare(strata_llamacpp" CMakeLists.txt; then
    GG_COMMIT=$(grep -oE "GIT_TAG [0-9a-f]{40}" CMakeLists.txt | awk '{print $2}' | head -1)
    GG_DIR="$PIXI_PROJECT_ROOT/download/llama.cpp-${GG_COMMIT:0:12}"
    test -d "$GG_DIR/ggml" || { echo "FATAL: $GG_DIR 缺失（maya-src.sh 应已下载 llama.cpp@${GG_COMMIT:0:12}）"; exit 1; }
    GG_ARGS=(-DMAYA_GGML_DIR="$GG_DIR")
fi

EXTRA=()
[ -n "${MAYA_CMAKE_EXTRA:-}" ] && read -r -a EXTRA <<< "$MAYA_CMAKE_EXTRA"

# 发布构建基线：MAYA_PORTABLE 不开（只服务本机，CPU 回退按本机指令集）；
# MAYA_BUILD_TESTS 关掉（源码树带 tests/，默认会开）；
# MAYA_NATIVE_EXPERTS 打开（CPU lane 用 ggml-cpu 的 IQ 点积，
# GGUF 的专家 offload 需要）。
cmake -B "$BUILD_DIR" \
    -G Ninja \
    -S . \
    -DCMAKE_BUILD_TYPE=Release \
    "${COMPILER_ARGS[@]}" \
    -DMAYA_ENABLE_CUDA=ON \
    -DMAYA_NATIVE_EXPERTS=ON \
    -DMAYA_BUILD_TESTS=OFF \
    -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" \
    "${GG_ARGS[@]}" \
    "${EXTRA[@]}"
cmake --build "$BUILD_DIR" --target maya maya-ds4 strata-device -j
echo "$TOOL_FP" > "$FP_FILE"

# --- 安装：整棵源码树 + 引擎/诊断程序到 $CONDA_PREFIX/maya ---
# maya.py 以自身位置定 ROOT（setup.py 的 ROOT），并在 start 时检查
# build/MAYA-BUILD.json 决定是否重编。我们整树安装、只放二进制、不写
# 该 stamp：llama-swap 启动时不会触发意外重编译。
APP_DIR="$CONDA_PREFIX/maya"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/build"
# 排除本地构建目录与 .venv（上游 setup.sh 的私有环境）
tar -C "$SRC_DIR" -cf - \
    --exclude='./build' --exclude='./build-*' --exclude='./.venv' . \
    | tar -C "$APP_DIR" -xf -
test -f "$APP_DIR/maya.py" || { echo "FATAL: 安装后缺 $APP_DIR/maya.py"; exit 1; }

BIN="$CONDA_PREFIX/bin"
mkdir -p "$BIN"
install -m 755 "$BUILD_DIR/maya" "$APP_DIR/build/maya"
install -m 755 "$BUILD_DIR/maya-ds4" "$APP_DIR/build/maya-ds4"
install -m 755 "$BUILD_DIR/strata-device" "$APP_DIR/build/strata-device"
# 仓库无 CMake install 规则：手动设 RPATH 指向环境 lib（CUDA 运行库）
# （二进制在 $CONDA_PREFIX/maya/build，往上两级才是 $CONDA_PREFIX/lib）
patchelf --set-rpath '$ORIGIN/../../lib' "$APP_DIR/build/maya" "$APP_DIR/build/maya-ds4" "$APP_DIR/build/strata-device"
ln -sfn ../maya/build/maya-ds4 "$BIN/maya-ds4"
ln -sfn ../maya/build/maya "$BIN/maya-engine"
ln -sfn ../maya/build/strata-device "$BIN/strata-device"

# bin/maya 启动器：环境 python3 + prefix 内的 maya.py
cat > "$BIN/maya" <<'EOF'
#!/bin/sh
# Project Maya launcher (pixi env): 环境 python3 + $CONDA_PREFIX/maya/maya.py
# PYTHONPATH 自设：pixi 激活时与 activation.env 一致，未激活直接调用也能跑
self=$(readlink -f -- "$0")
dir=$(dirname -- "$self")
# MAYA_SH=1: 不 exec 到 maya.sh 自建 .venv（固定用 pixi 环境）
PYTHONPATH="$dir/../maya${PYTHONPATH:+:$PYTHONPATH}" MAYA_SH=1 exec "$dir/python3" "$dir/../maya/maya.py" "$@"
EOF
chmod 755 "$BIN/maya"

echo "installed ($BACKEND) to: $APP_DIR (engine: build/maya-ds4) + $BIN/maya"
