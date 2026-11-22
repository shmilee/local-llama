#!/usr/bin/env bash
# 编译并安装 stable-diffusion.cpp 到当前 pixi 环境 prefix（CUDA / Vulkan 共用）
#
# 后端由 $SDCPP_BACKEND 决定（sdcpp-cuda → cuda / sdcpp-vulkan → vulkan）
# 所需环境变量（由 pixi 注入）:
#   PIXI_PROJECT_ROOT, SDCPP_VERSION, SDCPP_BACKEND,
#   CONDA_PREFIX, CMAKE_PREFIX_PATH, CUDACXX（仅 cuda）
# 可选环境变量:
#   SDCPP_BUILD_DIR  构建目录（相对源码目录，默认 build-${BACKEND}）
set -euo pipefail

BACKEND="${SDCPP_BACKEND:-}"
if [ -z "$BACKEND" ]; then
    echo "FATAL: SDCPP_BACKEND 未设置（须在 sdcpp-cuda / sdcpp-vulkan 环境中运行）" >&2
    exit 1
fi

# 构建目录（相对源码目录）：按后端区分，避免 CMake 缓存互相污染
BUILD_DIR="${SDCPP_BUILD_DIR:-build-$BACKEND}"

case "$BACKEND" in
    cuda)
        BACKEND_FLAGS=(
            -DSD_CUDA=ON
        )
        ;;
    vulkan)
        BACKEND_FLAGS=(
            -DSD_VULKAN=ON
        )
        ;;
    *)
        echo "FATAL: unknown backend '$BACKEND' (expected cuda or vulkan)" >&2
        exit 1
        ;;
esac

cd "$PIXI_PROJECT_ROOT/download/stable-diffusion.cpp-$SDCPP_VERSION"

# 构建缓存失效防护（两种情况，与 llamacpp-build.sh 同）:
# 1. 缓存记录的编译器路径已不存在（环境路径变了）
if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    CACHED_CC=$(grep -E '^CMAKE_C_COMPILER:' "$BUILD_DIR/CMakeCache.txt" | cut -d= -f2-)
    if [ -n "$CACHED_CC" ] && [ ! -x "$CACHED_CC" ]; then
        echo "CMake 缓存引用了不存在的编译器 ${CACHED_CC}，清除构建缓存"
        rm -rf "$BUILD_DIR"
    fi
fi
# 2. 工具链被 re-lock/重装替换（包构建变了，旧构建文件的链接引用全部失效）
TOOL_FP="$(stat -c '%Y' "$(command -v gcc)" 2>/dev/null)-$(cmake --version 2>/dev/null | head -1)"
FP_FILE="$BUILD_DIR/.toolchain-fingerprint"
if [ -f "$FP_FILE" ] && [ "$(cat "$FP_FILE" 2>/dev/null)" != "$TOOL_FP" ]; then
    echo "检测到工具链变化（gcc/cmake 被替换），清除构建缓存"
    rm -rf "$BUILD_DIR"
fi

# 构建要点:
# * 静态库（SD_BUILD_SHARED_LIBS 默认 OFF）：sd-cli / sd-server 自包含，
#   无 libstable-diffusion 运行时链接问题
# * 前端（SD_SERVER_BUILD_FRONTEND）关闭：server 只提供 API（OpenAI /v1/images/*
#   与 SDAPI /sdapi/v1/txt2img 均内置），避免 pnpm/node 构建链
# * WebP/WebM 关闭：避免触发 thirdparty/libwebp 子模块下载
# * 版本串：上游用 git describe / rev-parse 探测。两个坑（均实测）：
#   1) tarball 无 .git，但源码目录在外层 git 仓库（本仓库）内，git 会向上
#      查到外层 HEAD → 编入错误的 commit（曾编入 local-llama 的 0e869ff）
#   2) execute_process(OUTPUT_VARIABLE) 无条件覆盖 -D 传入的缓存值
#   解法：-DGIT_EXE=GIT_EXE-NOTFOUND（find_program 对已设为 falsy 的变量
#   跳过搜索，if(GIT_EXE) 整个探测块被绕过），再 -D 显式注入版本/commit
cmake -B "$BUILD_DIR" \
    -G Ninja \
    -S . \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CONDA_PREFIX" \
    -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DSD_BUILD_EXAMPLES=ON \
    -DSD_SERVER_BUILD_FRONTEND=OFF \
    -DSD_WEBP=OFF \
    -DSD_WEBM=OFF \
    -DGIT_EXE=GIT_EXE-NOTFOUND \
    -DSDCPP_BUILD_VERSION="$SDCPP_VERSION" \
    -DSDCPP_BUILD_COMMIT="${SDCPP_VERSION##*-}" \
    "${BACKEND_FLAGS[@]}"
cmake --build "$BUILD_DIR" --config Release -j
cmake --install "$BUILD_DIR"
echo "$TOOL_FP" > "$FP_FILE"

echo "installed ($BACKEND) to: $CONDA_PREFIX/bin"
