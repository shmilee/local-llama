#!/usr/bin/env bash
# 下载并解压 Project Maya 源码（幂等，可重复执行）
# 所需环境变量（由 pixi 注入）: PIXI_PROJECT_ROOT, MAYA_VERSION（如 v1.1.76）
set -euo pipefail

V="${MAYA_VERSION#v}"
DL_DIR="$PIXI_PROJECT_ROOT/download"
SRC_DIR="$DL_DIR/project-maya-$V"
TARBALL="$DL_DIR/project-maya-$V.tar.gz"

mkdir -p "$DL_DIR"
cd "$DL_DIR"

# --- 下载源码（tag tarball）---
# 直连 codeload 失败（内网/墙）时回退 gh-proxy.com 镜像
if [ ! -f "$TARBALL" ]; then
    curl -fL --retry 2 --connect-timeout 30 -o "$TARBALL" \
        "https://codeload.github.com/mw00/project-maya/tar.gz/refs/tags/v$V" \
        || { rm -f "$TARBALL"
             curl -fL --retry 2 --connect-timeout 30 -o "$TARBALL" \
                 "https://gh-proxy.com/https://codeload.github.com/mw00/project-maya/tar.gz/refs/tags/v$V"; }
fi
if [ ! -d "$SRC_DIR" ]; then
    tar -xzf "$TARBALL"
fi

# --- BUILD_ID：tarball 无 .git，maya-ds4 --version 的 commit 后缀靠这个
#     文件（cmake/build_id.cmake 读 $SRC/BUILD_ID 第一行）。取 tag 指向的
#     commit（git ls-remote 走 https refs 接口，gh-proxy 兜底）
if [ ! -f "$SRC_DIR/BUILD_ID" ] && [ ! -d "$SRC_DIR/.git" ]; then
    COMMIT=""
    for URL in "https://github.com/mw00/project-maya.git" \
               "https://gh-proxy.com/https://github.com/mw00/project-maya.git"; do
        COMMIT=$(timeout 30 git ls-remote "$URL" "refs/tags/v$V" 2>/dev/null \
                 | grep -v "{}" | awk '{print substr($1,1,12)}' | head -1 || true)
        [ -n "$COMMIT" ] && break
    done
    if [ -n "$COMMIT" ]; then
        echo "$COMMIT" > "$SRC_DIR/BUILD_ID"
    else
        echo "WARN: 取不到 tag v$V 的 commit，BUILD_ID 缺失（引擎 --version 显示 build unknown，不影响运行）" >&2
    fi
fi

# --- ggml 来自 llama.cpp pin（CMake FetchContent，构建机 GitHub 不可达）：
#     预下载 pinned commit 的 tarball，maya-build.sh 用 -DMAYA_GGML_DIR 指过去。
#     同一个 commit 与 strata-src.sh 共用，已存在则跳过。
if grep -q "FetchContent_Declare(strata_llamacpp" "$SRC_DIR/CMakeLists.txt"; then
    GG_COMMIT=$(grep -oE "GIT_TAG [0-9a-f]{40}" "$SRC_DIR/CMakeLists.txt" | awk '{print $2}' | head -1)
    if [ -n "$GG_COMMIT" ]; then
        GG_DIR="$DL_DIR/llama.cpp-${GG_COMMIT:0:12}"
        GG_TARBALL="$DL_DIR/llama.cpp-${GG_COMMIT:0:12}.tar.gz"
        if [ ! -d "$GG_DIR/ggml" ]; then
            if [ ! -f "$GG_TARBALL" ]; then
                curl -fL --retry 2 --connect-timeout 30 -o "$GG_TARBALL" \
                    "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$GG_COMMIT" \
                    || { rm -f "$GG_TARBALL"
                         curl -fL --retry 2 --connect-timeout 30 -o "$GG_TARBALL" \
                             "https://gh-proxy.com/https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$GG_COMMIT"; }
            fi
            tar -xzf "$GG_TARBALL" -C "$DL_DIR"
            # codeload tarball 顶层目录是完整 40 位 commit 名，归一到短名目录
            [ -d "$DL_DIR/llama.cpp-$GG_COMMIT" ] && mv "$DL_DIR/llama.cpp-$GG_COMMIT" "$GG_DIR"
        fi
        test -d "$GG_DIR/ggml" || { echo "FATAL: llama.cpp@${GG_COMMIT:0:12} 解压失败（$GG_DIR 缺失 ggml/）" >&2; exit 1; }
    fi
fi

echo "source ready: $SRC_DIR"
