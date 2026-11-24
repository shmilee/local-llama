#!/usr/bin/env bash
# 下载并解压 Strata 源码（幂等，可重复执行）
# 所需环境变量（由 pixi 注入）: PIXI_PROJECT_ROOT, STRATA_VERSION（如 v0.2.4.2）
set -euo pipefail

V="${STRATA_VERSION#v}"
DL_DIR="$PIXI_PROJECT_ROOT/download"
SRC_DIR="$DL_DIR/Strata-$V"
TARBALL="$DL_DIR/Strata-$V.tar.gz"

mkdir -p "$DL_DIR"
cd "$DL_DIR"

# --- 下载源码（tag tarball，含 vendored 依赖；0.2.4.2 时代的 ggml 走
#     CMake FetchContent，由下面的 llama.cpp 步骤提供）---
# 直连 codeload 失败（内网/墙）时回退 gh-proxy.com 镜像
if [ ! -f "$TARBALL" ]; then
    curl -fL --retry 2 --connect-timeout 30 -o "$TARBALL" \
        "https://codeload.github.com/Niko1221/Strata/tar.gz/refs/tags/v$V" \
        || { rm -f "$TARBALL"
             curl -fL --retry 2 --connect-timeout 30 -o "$TARBALL" \
                 "https://gh-proxy.com/https://codeload.github.com/Niko1221/Strata/tar.gz/refs/tags/v$V"; }
fi
if [ ! -d "$SRC_DIR" ]; then
    tar -xzf "$TARBALL"
fi

# --- BUILD_ID：tarball 无 .git，引擎 --version 的 commit 后缀靠这个文件
#     （CMake: STRATA_BUILD_ID <- BUILD_ID <- git rev-parse；官方
#      packaging/build_dsv41_cuda.sh 同款做法）。取 tag 指向的 commit
#     （git ls-remote 走 codeload 之外的 https refs 接口，gh-proxy 兜底）
if [ ! -f "$SRC_DIR/BUILD_ID" ] && [ ! -d "$SRC_DIR/.git" ]; then
    COMMIT=""
    for URL in "https://github.com/Niko1221/Strata.git" \
               "https://gh-proxy.com/https://github.com/Niko1221/Strata.git"; do
        COMMIT=$(timeout 30 git ls-remote "$URL" "refs/tags/v$V" 2>/dev/null \
                 | grep -v "{}" | awk '{print substr($1,1,9)}' | head -1 || true)
        [ -n "$COMMIT" ] && break
    done
    if [ -n "$COMMIT" ]; then
        echo "$COMMIT" > "$SRC_DIR/BUILD_ID"
    else
        echo "WARN: 取不到 tag v$V 的 commit，BUILD_ID 缺失（引擎 --version 显示 build unknown，不影响运行）" >&2
    fi
fi

# --- 旧版（v0.2.4.2 等）的 ggml 来自 CMake FetchContent 的 llama.cpp
#     （GIT_REPOSITORY 指向 github.com，构建机不可达）：预下载 pinned
#     commit 的 tarball，strata-build.sh 用 FETCHCONTENT_SOURCE_DIR_* 指过去
if [ -f "$SRC_DIR/CMakeLists.txt" ] && grep -q "FetchContent_Declare(strata_llamacpp" "$SRC_DIR/CMakeLists.txt"; then
    GG_COMMIT=$(grep -oE "GIT_TAG [0-9a-f]{40}" "$SRC_DIR/CMakeLists.txt" | awk '{print $2}' | head -1)
    if [ -n "$GG_COMMIT" ]; then
        GG_DIR="$DL_DIR/llama.cpp-${GG_COMMIT:0:12}"
        GG_TARBALL="$DL_DIR/llama.cpp-${GG_COMMIT:0:12}.tar.gz"
        if [ ! -f "$GG_TARBALL" ]; then
            curl -fL --retry 2 --connect-timeout 30 -o "$GG_TARBALL" \
                "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$GG_COMMIT" \
                || { rm -f "$GG_TARBALL"
                     curl -fL --retry 2 --connect-timeout 30 -o "$GG_TARBALL" \
                         "https://gh-proxy.com/https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$GG_COMMIT"; }
        fi
        if [ ! -d "$GG_DIR/ggml" ]; then
            tar -xzf "$GG_TARBALL" -C "$DL_DIR"
            # codeload tarball 顶层目录是完整 40 位 commit 名，归一到短名目录
            [ -d "$DL_DIR/llama.cpp-$GG_COMMIT" ] && mv "$DL_DIR/llama.cpp-$GG_COMMIT" "$GG_DIR"
        fi
        test -d "$GG_DIR/ggml" || { echo "FATAL: llama.cpp@${GG_COMMIT:0:12} 解压失败（$GG_DIR 缺失 ggml/）" >&2; exit 1; }
    fi
fi

echo "source ready: $SRC_DIR"
