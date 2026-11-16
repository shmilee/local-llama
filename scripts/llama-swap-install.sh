#!/bin/bash
# 安装 llama-swap 官方预编译二进制（release 资产，已含 UI）。
# 2026-11-16 起弃用源码补丁构建（sglext 补丁，v262 及以前）：
#   其受益者仅为已归档的 SGLang LLM 条目（投机解码统计 + 流式 decode 速率回退）；
#   现役 llama.cpp / vLLM / Strata 后端均自报逐请求指标，不受影响；
#   规划的 SGLang 用途（T2I）无 token/投机解码，补丁不触发。
#   补丁内容与旧构建脚本见 git 历史（83d14e7、64d2624）。
#
# 用法: bash scripts/llama-swap-install.sh
#   TAG 硬编码于下方；上游发新版后更新 TAG 重跑即可（下载幂等，sha256 校验）。
#   安装后重启 llama-swap 进程生效——重启会卸载在跑的模型，选空闲时段。
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DL_DIR="$REPO_ROOT/download"
TAG="v273"
VERSION="${TAG#v}"
ARCH="linux_amd64"
ASSET="llama-swap_${VERSION}_${ARCH}.tar.gz"
CHECKSUMS="llama-swap_${VERSION}_checksums.txt"
BASE_URL="https://github.com/mostlygeek/llama-swap/releases/download/$TAG"
BIN="$REPO_ROOT/bin/llama-swap"

mkdir -p "$DL_DIR"

# --- 下载（幂等；GitHub 链路不稳，显式重试，失败清掉半截文件）---
if [ ! -f "$DL_DIR/$ASSET" ]; then
    for attempt in 1 2 3; do
        if curl -fL --connect-timeout 20 --max-time 600 \
            -o "$DL_DIR/$ASSET" "$BASE_URL/$ASSET"; then
            break
        fi
        rm -f "$DL_DIR/$ASSET"
        if [ "$attempt" -eq 3 ]; then
            echo "FATAL: 下载 $ASSET 失败（网络抖动？）" >&2
            exit 1
        fi
        echo "    下载失败，重试 ($attempt/3)..."
        sleep 3
    done
fi
if [ ! -f "$DL_DIR/$CHECKSUMS" ]; then
    curl -fL --retry 3 -o "$DL_DIR/$CHECKSUMS" "$BASE_URL/$CHECKSUMS"
fi

# --- 校验 sha256 ---
if ! (cd "$DL_DIR" && grep " $ASSET\$" "$CHECKSUMS" | sha256sum -c -); then
    echo "FATAL: $ASSET 校验和不符" >&2
    rm -f "$DL_DIR/$ASSET"
    exit 1
fi

# --- 安装（只取二进制；首个旧二进制作 .prev 回退基线）---
STAGE="$(mktemp -d "$DL_DIR/.llama-swap-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$DL_DIR/$ASSET" -C "$STAGE" llama-swap
mkdir -p "$(dirname "$BIN")"
if [ -x "$BIN" ] && [ ! -f "$BIN.prev" ]; then
    cp -f "$BIN" "$BIN.prev"
fi
install -m 755 "$STAGE/llama-swap" "$BIN"

# --- 验证版本 ---
VER_OUT="$("$BIN" --version)"
echo "$VER_OUT"
case "$VER_OUT" in
    *"$VERSION"*) ;;
    *) echo "FATAL: 安装的二进制版本不是 $TAG" >&2; exit 1 ;;
esac
echo "==> 完成，重启 llama-swap 进程后生效"
