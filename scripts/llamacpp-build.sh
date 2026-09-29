#!/usr/bin/env bash
# 编译并安装 llama.cpp 到当前 pixi 环境 prefix（CUDA / Vulkan 共用）
#
# 后端由 $LLAMACPP_BACKEND 决定（llamacpp-cuda → cuda / llamacpp-vulkan → vulkan）
# 所需环境变量（由 pixi 注入）:
#   PIXI_PROJECT_ROOT, LLAMACPP_VERSION, LLAMACPP_BACKEND,
#   CONDA_PREFIX, CMAKE_PREFIX_PATH, CUDACXX（仅 cuda）
# 可选环境变量:
#   LLAMACPP_BUILD_DIR  构建目录（相对源码目录，默认 build-$BACKEND）
set -euo pipefail

BACKEND="${LLAMACPP_BACKEND:-}"
if [ -z "$BACKEND" ]; then
    echo "FATAL: LLAMACPP_BACKEND 未设置（须在 llamacpp-cuda / llamacpp-vulkan 环境中运行）" >&2
    exit 1
fi

# 构建目录（相对源码目录）：按后端区分，避免 CMake 缓存互相污染
BUILD_DIR="${LLAMACPP_BUILD_DIR:-build-$BACKEND}"

case "$BACKEND" in
    cuda)
        # 不指定 CMAKE_CUDA_ARCHITECTURES：GGML_NATIVE=ON（默认）自动检测本机 GPU
        # （Blackwell 上为 sm_120a，需 CUDA >=12.8）
        BACKEND_FLAGS=(
            -DGGML_CUDA=ON
            -DGGML_CUDA_FA_ALL_QUANTS=ON
        )
        ;;
    vulkan)
        BACKEND_FLAGS=(
            -DGGML_VULKAN=ON
        )
        ;;
    *)
        echo "FATAL: unknown backend '$BACKEND' (expected cuda or vulkan)" >&2
        exit 1
        ;;
esac

cd "$PIXI_PROJECT_ROOT/download/llama.cpp-$LLAMACPP_VERSION"

# 构建缓存失效防护（两种情况）:
# 1. 缓存记录的编译器路径已不存在（环境路径变了）
if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    CACHED_CC=$(grep -E '^CMAKE_C_COMPILER:' "$BUILD_DIR/CMakeCache.txt" | cut -d= -f2-)
    if [ -n "$CACHED_CC" ] && [ ! -x "$CACHED_CC" ]; then
        echo "CMake 缓存引用了不存在的编译器 $CACHED_CC，清除构建缓存"
        rm -rf "$BUILD_DIR"
    fi
fi
# 2. 工具链被 re-lock/重装替换（包构建变了，sysroot 内容随之变化，
#    如新版 glibc 的 sysroot 不再有 libpthread.a）→ 旧构建文件的链接引用全部失效
TOOL_FP="$(stat -c '%Y' "$(command -v gcc)" 2>/dev/null)-$(cmake --version 2>/dev/null | head -1)"
FP_FILE="$BUILD_DIR/.toolchain-fingerprint"
if [ -f "$FP_FILE" ] && [ "$(cat "$FP_FILE" 2>/dev/null)" != "$TOOL_FP" ]; then
    echo "检测到工具链变化（gcc/cmake 被替换），清除构建缓存"
    rm -rf "$BUILD_DIR"
fi

cmake -B "$BUILD_DIR" \
    -G Ninja \
    -S . \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CONDA_PREFIX" \
    -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DBUILD_SHARED_LIBS=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_USE_SYSTEM_GGML=OFF \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=ON \
    -DGGML_ALL_WARNINGS=OFF \
    -DGGML_ALL_WARNINGS_3RD_PARTY=OFF \
    -DGGML_BUILD_EXAMPLES=OFF \
    -DGGML_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_NUMBER="${LLAMACPP_VERSION#b}" \
    -Wno-dev \
    "${BACKEND_FLAGS[@]}"
cmake --build "$BUILD_DIR" --config Release -j
cmake --install "$BUILD_DIR"
echo "$TOOL_FP" > "$FP_FILE"

echo "installed ($BACKEND) to: $CONDA_PREFIX/bin"
