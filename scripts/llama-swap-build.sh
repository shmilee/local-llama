#!/bin/bash
# 构建 llama-swap 本地补丁版：下载固定 tag 的官方源码包（非 git 克隆），
# 打本地补丁，编译，安装到 bin/（官方预编译二进制不含本补丁）。
#
# 用法: bash scripts/llama-swap-build.sh [tag]
#   tag 缺省 = 补丁针对的版本（与补丁文件名绑定，两者须一致）；
#   上游发新版后，先按新 tag 生成/更新补丁文件，再以新 tag 运行本脚本。
#   幂等，可重复执行；源码包与构建位于 download/（与 llama.cpp 约定一致）；
#   go 优先用 PATH 中的系统 go，回退 $HOME/.local/go（缺失时自动下载）。
# 安装后重启 llama-swap 进程生效。
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DL_DIR="$REPO_ROOT/download"
TAG="${1:-v262}"  # 固定 tag，须与补丁针对的版本一致
PATCH="$REPO_ROOT/patches/llama-swap-sglext-$TAG.patch"
BIN="$REPO_ROOT/bin/llama-swap"
GO_MIN="1.27.1"      # go.mod 的 go 指令
GO_VERSION="1.27.1"  # fallback 缺失时安装的版本
GO_LOCAL="$HOME/.local/go"

if [ ! -f "$PATCH" ]; then
    echo "FATAL: 补丁文件不存在: $PATCH" >&2
    echo "补丁与 tag 绑定：请先按 $TAG 生成/更新补丁文件，再运行。" >&2
    exit 1
fi
SRC_DIR="$DL_DIR/llama-swap-${TAG#v}"  # GitHub archive 解压目录名去掉 v 前缀

# --- go（系统 go 优先；$GO_LOCAL 回退，缺失时自动下载）---
# 系统 go 版本过低也走回退：旧 go 会触发 GOTOOLCHAIN 自动下载工具链（国内网络常不可达）
go_usable() {
    command -v go >/dev/null 2>&1 || return 1
    local ver
    ver="$(go env GOVERSION | sed 's/^go//')"
    [ "$(printf '%s\n%s\n' "$GO_MIN" "$ver" | sort -V | head -n1)" = "$GO_MIN" ]
}

if go_usable; then
    echo "==> 使用系统 go $(go env GOVERSION)"
elif [ -x "$GO_LOCAL/bin/go" ]; then
    echo "==> 系统 go 不可用，使用 $GO_LOCAL"
    export PATH="$GO_LOCAL/bin:$PATH"
else
    echo "==> 系统 go 不可用，安装 Go $GO_VERSION 到 $GO_LOCAL（镜像）"
    mkdir -p "$DL_DIR"
    curl -fL --retry 3 -o "$DL_DIR/go$GO_VERSION.linux-amd64.tar.gz" \
        "https://mirrors.ustc.edu.cn/golang/go$GO_VERSION.linux-amd64.tar.gz" \
        || curl -fL --retry 3 -o "$DL_DIR/go$GO_VERSION.linux-amd64.tar.gz" \
        "https://mirrors.aliyun.com/golang/go$GO_VERSION.linux-amd64.tar.gz"
    mkdir -p "$HOME/.local"
    tar -xzf "$DL_DIR/go$GO_VERSION.linux-amd64.tar.gz" -C "$HOME/.local"
    export PATH="$GO_LOCAL/bin:$PATH"
fi
# proxy.golang.org 国内网络不可达
export GOPROXY="https://goproxy.cn,direct"

# --- 下载源码（幂等；GitHub 链路不稳，显式重试，失败清掉半截文件）---
echo "==> llama-swap $TAG"
mkdir -p "$DL_DIR"
if [ ! -f "$DL_DIR/llama-swap-$TAG.tar.gz" ]; then
    for attempt in 1 2 3; do
        if curl -fL --connect-timeout 20 --max-time 300 \
            -o "$DL_DIR/llama-swap-$TAG.tar.gz" \
            "https://github.com/mostlygeek/llama-swap/archive/refs/tags/$TAG.tar.gz"; then
            break
        fi
        rm -f "$DL_DIR/llama-swap-$TAG.tar.gz"
        if [ "$attempt" -eq 3 ]; then
            echo "FATAL: 源码包下载失败（网络抖动？）" >&2
            exit 1
        fi
        echo "    下载失败，重试 ($attempt/3)..."
        sleep 3
    done
fi
if [ ! -d "$SRC_DIR" ]; then
    tar -xzf "$DL_DIR/llama-swap-$TAG.tar.gz" -C "$DL_DIR"
fi

# --- 打补丁（幂等：已打过则跳过）---
if grep -q 'sglext := parsed.Get("sglext")' "$SRC_DIR/internal/server/metrics.go"; then
    echo "==> 补丁已应用，跳过"
else
    echo "==> 打补丁"
    if ! patch -p1 -d "$SRC_DIR" < "$PATCH"; then
        echo "FATAL: 补丁失败（$TAG 源码与补丁不匹配？）。" >&2
        echo "请核对补丁是否针对 $TAG 生成，修正后重跑。" >&2
        rm -rf "$SRC_DIR"  # 清掉半打状态，下次全新解压
        exit 1
    fi
fi

# --- 编译（在源码目录内，产物输出到源码目录根）---
echo "==> 编译"
(cd "$SRC_DIR" && go build -o llama-swap .)

# --- 安装 ---
echo "==> 安装 $BIN"
mkdir -p "$(dirname "$BIN")"
if [ -x "$BIN" ] && [ ! -f "$BIN.prev" ]; then
    cp -f "$BIN" "$BIN.prev"  # 保留首个（官方）二进制作回退基线
fi
install -m 755 "$SRC_DIR/llama-swap" "$BIN"
"$BIN" --version
echo "==> 完成，重启 llama-swap 进程后生效"
