#!/usr/bin/env bash
# 下载并解压 llama.cpp 源码 + 预构建 UI 包（幂等，可重复执行）
# 所需环境变量（由 pixi 注入）: PIXI_PROJECT_ROOT, LLAMACPP_VERSION
set -euo pipefail

DL_DIR="$PIXI_PROJECT_ROOT/download"
SRC_DIR="$DL_DIR/llama.cpp-$LLAMACPP_VERSION"

mkdir -p "$DL_DIR"
cd "$DL_DIR"

# --- 下载源码 ---
if [ ! -f "llama.cpp-$LLAMACPP_VERSION.tar.gz" ]; then
    curl -fL --retry 3 -o "llama.cpp-$LLAMACPP_VERSION.tar.gz" \
        "https://github.com/ggml-org/llama.cpp/archive/refs/tags/$LLAMACPP_VERSION.tar.gz"
fi
if [ ! -d "$SRC_DIR" ]; then
    tar -xzf "llama.cpp-$LLAMACPP_VERSION.tar.gz"
fi

# --- 下载 UI 包（离线环境避免 npm 构建 / HF 下载）---
if [ ! -f "llama-$LLAMACPP_VERSION-ui.tar.gz" ]; then
    curl -fL --retry 3 -o "llama-$LLAMACPP_VERSION-ui.tar.gz" \
        "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMACPP_VERSION/llama-$LLAMACPP_VERSION-ui.tar.gz"
fi
# UI 预置资产目录：b12500 起 UI 源码从 tools/ui/ 移到 ui/apps/chat/
# （ui-assets.cmake 首选 <UI_SOURCE_DIR>/dist 作为预构建资产，找不到才走 npm/HF）
if [ -d "$SRC_DIR/ui/apps/chat" ]; then
    UI_DIST_DIR="$SRC_DIR/ui/apps/chat/dist"
else
    UI_DIST_DIR="$SRC_DIR/tools/ui/dist"
fi
mkdir -p "$UI_DIST_DIR"
if [ ! -f "$UI_DIST_DIR/index.html" ]; then
    tar -xzf "llama-$LLAMACPP_VERSION-ui.tar.gz" -C "$UI_DIST_DIR" --strip-components=1
fi

echo "source ready: $SRC_DIR"
