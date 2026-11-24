#!/usr/bin/env bash
# 编译并安装 Strata（CUDA 引擎 + 图片编码器 + Python 终端）到当前 pixi 环境 prefix
#
# 后端由 $STRATA_BACKEND 决定（strata-cuda → cuda）
# 所需环境变量（由 pixi 注入）:
#   PIXI_PROJECT_ROOT, STRATA_VERSION, STRATA_BACKEND,
#   CONDA_PREFIX, CMAKE_PREFIX_PATH, CUDACXX（仅 cuda）
# 可选环境变量:
#   STRATA_BUILD_DIR      主引擎构建目录（相对 engine/，默认 build-$BACKEND）
#   STRATA_VISION_BUILD_DIR  图片编码器构建目录（默认 <源码>/build-vision）
#   STRATA_CUDA_ARCHS     CUDA 架构（默认 = 本机 GPU 探测出的架构号，如 120；
#                         跨卡发行可设 "75;86;89;120"）
#   STRATA_CMAKE_EXTRA    追加 cmake 参数（如 -DSTRATA_GEOMETRY=<name>）
#
# 源码布局（0.2.16+）: engine/（C++/CUDA 引擎）+ terminal/（Python 终端，
# tools/vision 是图片编码器）+ tools/（仓库工具）。0.2.14 起上游移除
# DeepSeek（dsv41）引擎，故这里只构建主引擎（flash_next 形状，QFN 用）+
# 图片编码器 + 终端。
#
# 产物（都装进 $CONDA_PREFIX/bin）：
#   strata-engine   主引擎（flash_next 形状：Qwen3.8-Flash-Next 等）
#   strata-device   GPU 诊断/自检
#   strata-vision   图片编码器（QFN 多模态必需；0.2.16+ 是 Strata 自有
#                   Qwen 视觉塔，不再依赖 llama.cpp/mtmd）
#   strata          Python 终端启动器（strata serve / CLI）
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
ENGINE_DIR="$SRC_DIR/engine"
TERMINAL_DIR="$SRC_DIR/terminal"
VISION_DIR="$TERMINAL_DIR/tools/vision"
test -d "$ENGINE_DIR" || { echo "FATAL: 源码目录 $SRC_DIR 不存在或不是 0.2.16+ 布局（先跑 strata-src）" >&2; exit 1; }
test -d "$VISION_DIR" || { echo "FATAL: $VISION_DIR 缺失（0.2.16+ 的图片编码器源码）" >&2; exit 1; }

# CUDA 架构：默认探测本机 GPU（取最高 compute_cap → 架构号）。
# 不用 "native"：部分版本的 NVFP4 W4A4 单元只认数字架构，native 会原样
# 透传给 ptxas（上游 #4023；显式架构号在各版本都正确）
ARCHS="${STRATA_CUDA_ARCHS:-}"
if [ -z "$ARCHS" ]; then
    CCAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | sort -Vu | tail -1)
    ARCHS=$(echo "${CCAP:-}" | tr -d '.')
fi
[ -n "$ARCHS" ] || { echo "FATAL: 探测不到 GPU 架构（nvidia-smi compute_cap），请显式设 STRATA_CUDA_ARCHS（如 120）" >&2; exit 1; }

# 编译器：显式指向 conda 交叉工具链。CMake 4.x 的 enable_language(C/CXX) 在
# pixi task 上下文里读不到 CC/CXX 环境变量，干净缓存目录会报
# "CMAKE_C_COMPILER not set, after EnableLanguage"
HOST_CC="$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-cc"
HOST_CXX="$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-g++"
[ -x "$HOST_CC" ] && [ -x "$HOST_CXX" ] || { echo "FATAL: conda 交叉编译器缺失：$HOST_CC / $HOST_CXX" >&2; exit 1; }
COMPILER_ARGS=(-DCMAKE_C_COMPILER="$HOST_CC" -DCMAKE_CXX_COMPILER="$HOST_CXX")

EXTRA=()
[ -n "${STRATA_CMAKE_EXTRA:-}" ] && read -r -a EXTRA <<< "$STRATA_CMAKE_EXTRA"

# --- 主引擎（flash_next 形状）---
ENGINE_BUILD_DIR="${STRATA_BUILD_DIR:-build-$BACKEND}"
cd "$ENGINE_DIR"

# 构建缓存失效防护:
# 1. 缓存记录的编译器路径已不存在（环境路径变了）
if [ -f "$ENGINE_BUILD_DIR/CMakeCache.txt" ]; then
    CACHED_CC=$(grep -E '^CMAKE_C_COMPILER:' "$ENGINE_BUILD_DIR/CMakeCache.txt" | cut -d= -f2-)
    if [ -n "$CACHED_CC" ] && [ ! -x "$CACHED_CC" ]; then
        echo "CMake 缓存引用了不存在的编译器 $CACHED_CC，清除构建缓存"
        rm -rf "$ENGINE_BUILD_DIR"
    fi
fi
# 2. 工具链被 re-lock/重装替换 → 旧构建文件的链接引用全部失效
TOOL_FP="$(stat -c '%Y' "$(command -v gcc)" 2>/dev/null)-$(cmake --version 2>/dev/null | head -1)-$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/cuda-\1/p' | head -1)"
FP_FILE="$ENGINE_BUILD_DIR/.toolchain-fingerprint"
if [ -f "$FP_FILE" ] && [ "$(cat "$FP_FILE" 2>/dev/null)" != "$TOOL_FP" ]; then
    echo "检测到工具链变化（gcc/cmake/nvcc 被替换），清除构建缓存"
    rm -rf "$ENGINE_BUILD_DIR"
fi

cmake -B "$ENGINE_BUILD_DIR" \
    -G Ninja \
    -S . \
    -DCMAKE_BUILD_TYPE=Release \
    "${COMPILER_ARGS[@]}" \
    -DSTRATA_ENABLE_CUDA=ON \
    -DSTRATA_BUILD_TESTS=OFF \
    -DSTRATA_NATIVE_EXPERTS=ON \
    -DSTRATA_Q6K_EXPERTS=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" \
    "${EXTRA[@]}"
cmake --build "$ENGINE_BUILD_DIR" --target strata strata-device -j
echo "$TOOL_FP" > "$FP_FILE"

# --- 安装引擎到 $CONDA_PREFIX/bin ---
# 引擎名 strata-engine（官方名 strata 留给 Python 终端启动器）
BIN="$CONDA_PREFIX/bin"
install -m 755 "$ENGINE_BUILD_DIR/strata" "$BIN/strata-engine"
install -m 755 "$ENGINE_BUILD_DIR/strata-device" "$BIN/strata-device"
# 仓库无 CMake install 规则：手动设 RPATH 指向环境 lib（CUDA 运行库）
patchelf --set-rpath '$ORIGIN/../lib' "$BIN/strata-engine" "$BIN/strata-device"
echo "installed strata-engine, strata-device to: $BIN"

# --- 图片编码器 strata-vision（QFN 多模态必需）---
# 0.2.16+ 是 Strata 自有 Qwen 视觉塔（terminal/tools/vision/own），
# 不编译 llama.cpp/mtmd/ggml；run config 有 vision 段而缺它时模型起不来
VISION_BUILD_DIR="${STRATA_VISION_BUILD_DIR:-$SRC_DIR/build-vision}"
cmake -S "$VISION_DIR" -B "$VISION_BUILD_DIR" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    "${COMPILER_ARGS[@]}" \
    -DSTRATA_VISION_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" \
    -DSTRATA_PORTABLE=OFF
cmake --build "$VISION_BUILD_DIR" --target strata-vision -j
install -m 755 "$VISION_BUILD_DIR/bin/strata-vision" "$BIN/strata-vision"
patchelf --set-rpath '$ORIGIN/../lib' "$BIN/strata-vision"
echo "installed strata-vision to: $BIN"

# --- 安装 Python 终端到 $CONDA_PREFIX/strata ---
# strata.py 以自身位置定 ROOT，strata_cli/serve 按 ROOT 找 serve/ tools/ data/；
# 依赖（jinja2 等）在环境 site-packages，无需 venv
APP_DIR="$CONDA_PREFIX/strata"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
for item in strata.py strata_cli strata_control serve data tools setup.py \
            requirements.txt requirements-build.txt requirements-monitor.txt; do
    [ -e "$TERMINAL_DIR/$item" ] && cp -r "$TERMINAL_DIR/$item" "$APP_DIR/"
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

echo "installed ($BACKEND) to: $BIN (strata-engine, strata-device, strata-vision, strata) + $APP_DIR (terminal)"
