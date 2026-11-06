#!/usr/bin/env bash
# 验证 stable-diffusion.cpp 安装：bin 存在 + --version 正常 + 运行时能检测到对应后端的 GPU
# 后端由 $SDCPP_BACKEND 决定（sdcpp-cuda → cuda / sdcpp-vulkan → vulkan）
# 不加载模型、不启动服务
# 所需环境变量（由 pixi 注入）: CONDA_PREFIX, SDCPP_BACKEND
set -euo pipefail

BACKEND="${SDCPP_BACKEND:-}"
if [ -z "$BACKEND" ]; then
    echo "FATAL: SDCPP_BACKEND 未设置（须在 sdcpp-cuda / sdcpp-vulkan 环境中运行）" >&2
    exit 1
fi

BIN="$CONDA_PREFIX/bin"
echo "bin dir: $BIN"
test -d "$BIN" || { echo "FATAL: $BIN not a directory"; exit 1; }

# sd-cli 是推理 CLI，sd-server 是 llama-swap 实际调用的 HTTP 服务
for b in sd-cli sd-server; do
    test -x "$BIN/$b" || { echo "FATAL: $BIN/$b missing or not executable"; exit 1; }
done
echo "binaries present: sd-cli, sd-server"

echo
echo "== sd-cli --version =="
"$BIN/sd-cli" --version

# 运行时设备检测：后端未启用（或本机无对应 GPU/驱动）时 list-devices
# 只会列出 CPU，据此可发现"编译成功但后端没编进去"的静默失败。
# 注意：sd.cpp 的输出格式是 "name<TAB>description"（非 llama.cpp 的 "Name:" 冒号格式）
echo
echo "== sd-cli --list-devices =="
DEVICES_OUT="$("$BIN/sd-cli" --list-devices)"
echo "$DEVICES_OUT"

case "$BACKEND" in
    cuda)   PATTERN="CUDA[0-9]+" ;;
    vulkan) PATTERN="Vulkan[0-9]+" ;;
esac
if ! echo "$DEVICES_OUT" | grep -qE "$PATTERN"; then
    echo "FATAL: list-devices 中没有 $BACKEND GPU 设备（后端未启用，或本机缺少对应 GPU/驱动？）"
    exit 1
fi

echo
echo "OK: install verified ($BACKEND backend, GPU detected)"
