#!/usr/bin/env bash
# 验证 Strata 安装：bin 存在 + --version + 运行时能检测到 CUDA GPU
# 后端由 $STRATA_BACKEND 决定（strata-cuda → cuda）
# 不加载模型、不启动服务
# 所需环境变量（由 pixi 注入）: CONDA_PREFIX, STRATA_BACKEND
set -euo pipefail

BACKEND="${STRATA_BACKEND:-}"
if [ -z "$BACKEND" ]; then
    echo "FATAL: STRATA_BACKEND 未设置（须在 strata-cuda 环境中运行）" >&2
    exit 1
fi

BIN="$CONDA_PREFIX/bin"
echo "bin dir: $BIN"
test -d "$BIN" || { echo "FATAL: $BIN not a directory"; exit 1; }

# strata-engine 是主引擎本体（官方名 strata，改名避免与 Python 终端启动器
# 冲突）；strata-device 是 GPU 诊断/自检；strata-vision 是图片编码器（QFN
# 多模态必需）；strata 是 Python 终端。三者都是 strata-build 的默认产物
for b in strata-engine strata-device strata-vision strata; do
    test -e "$BIN/$b" || { echo "FATAL: $BIN/$b missing"; exit 1; }
done
echo "binaries present: strata-engine, strata-device, strata-vision, strata (terminal)"

# 动态库全部可解析（RPATH 指向环境 lib）
for b in strata-engine strata-device strata-vision; do
    echo
    echo "== ldd $b =="
    if ldd "$BIN/$b" | grep -q "not found"; then
        ldd "$BIN/$b" | grep "not found"
        echo "FATAL: $b 有解析不到的动态库"
        exit 1
    fi
    echo "all shared libraries resolved"
done

echo
echo "== strata-engine --version =="
"$BIN/strata-engine" --version

# 图片编码器没有 --version：无参数时打印 usage（非零退出）
echo
echo "== strata-vision usage =="
VISION_USAGE="$("$BIN/strata-vision" 2>&1 | head -1 || true)"
echo "$VISION_USAGE"
case "$VISION_USAGE" in
    usage:*) ;;
    *) echo "FATAL: strata-vision 未打印 usage（安装损坏？）"; exit 1 ;;
esac

# 运行时设备检测：后端未启用（或本机无对应 GPU/驱动）时 list-devices
# 只会报 (no GPU device)；架构不匹配时报 cannot run，据此可发现
# "编译成功但后端没编进去 / 架构不对"的静默失败
echo
echo "== strata-device --list-devices =="
DEVICES_OUT="$("$BIN/strata-device" --list-devices)"
echo "$DEVICES_OUT"

case "$BACKEND" in
    cuda) PATTERN="compute capability [0-9]" ;;
    *) PATTERN="" ;;
esac
if ! echo "$DEVICES_OUT" | grep -qE "$PATTERN"; then
    echo "FATAL: list-devices 中没有 $BACKEND GPU 设备（后端未启用，或本机缺少对应 GPU/驱动？）"
    exit 1
fi
if echo "$DEVICES_OUT" | grep -q "cannot run"; then
    echo "FATAL: 本机有 GPU 是这个引擎不能跑的（架构不匹配？检查 STRATA_CUDA_ARCHS）"
    exit 1
fi

# 真实占用显存：64 MiB arena 分配/释放往返（只碰 GPU 内存，不加载模型）
echo
echo "== strata-device --selftest =="
"$BIN/strata-device" --selftest | tail -4

# Python 终端：环境内 preflight 依赖 + 代码树可导入
echo
echo "== python terminal =="
"$BIN/python3" -c "import jinja2, yaml, regex, psutil, requests, numpy, PIL, tqdm; print('preflight deps ok')"
PYTHONPATH="$CONDA_PREFIX/strata" "$BIN/python3" -c \
    "import strata_cli, strata_control, serve; print('terminal import ok')"
"$BIN/strata" --help >/dev/null && echo "strata --help ok"

echo
echo "OK: install verified ($BACKEND backend, GPU detected)"
