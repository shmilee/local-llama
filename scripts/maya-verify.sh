#!/usr/bin/env bash
# 验证 Project Maya 安装：文件 + --version + GPU 自检 + python 依赖
# 后端由 $MAYA_BACKEND 决定（maya-cuda → cuda）
# 不加载模型、不启动服务
# 所需环境变量（由 pixi 注入）: CONDA_PREFIX, MAYA_BACKEND
# 可选: MAYA_VERIFY_GPU（默认 0；只用于 strata-device 的设备自检）
set -euo pipefail

BACKEND="${MAYA_BACKEND:-}"
if [ -z "$BACKEND" ]; then
    echo "FATAL: MAYA_BACKEND 未设置（须在 maya-cuda 环境中运行）" >&2
    exit 1
fi

BIN="$CONDA_PREFIX/bin"
APP_DIR="$CONDA_PREFIX/maya"
echo "app dir: $APP_DIR"
test -d "$APP_DIR" || { echo "FATAL: $APP_DIR not a directory"; exit 1; }

# maya-ds4 是 DeepSeek 引擎；strata-device 是 GPU 诊断/自检程序；
# maya.py / serve / tools / data 是 Python 服务端；expert-profile-ds4.bin
# 是引擎的初始专家放置表（缺了仍能跑，但首启会从零学习）
for f in "$APP_DIR/maya.py" "$APP_DIR/setup.py" "$APP_DIR/serve/server.py" \
         "$APP_DIR/tools/ds4/pack_gguf.py" "$APP_DIR/data/expert-profile-ds4.bin" \
         "$APP_DIR/build/maya" "$APP_DIR/build/maya-ds4" "$APP_DIR/build/strata-device" \
         "$BIN/maya" "$BIN/maya-ds4"; do
    test -e "$f" || { echo "FATAL: $f missing"; exit 1; }
done
echo "files present: maya.py, serve/, tools/ds4/, data/, build/maya, build/maya-ds4, build/strata-device, bin/maya"

# 动态库全部可解析（RPATH 指向环境 lib）
for b in "$APP_DIR/build/maya" "$APP_DIR/build/maya-ds4" "$APP_DIR/build/strata-device"; do
    echo
    echo "== ldd $(basename "$b") =="
    if ldd "$b" | grep -q "not found"; then
        ldd "$b" | grep "not found"
        echo "FATAL: $(basename "$b") 有解析不到的动态库"
        exit 1
    fi
    echo "all shared libraries resolved"
done

echo
echo "== maya (GLM 主引擎) --help =="
"$APP_DIR/build/maya" --help 2>&1 | grep -q -- "--glm-pack" && echo "maya engine ok (--glm-pack present)"

echo
echo "== maya-ds4 --version =="
"$APP_DIR/build/maya-ds4" --version

echo
echo "== strata-device (GPU 信息) =="
GPU="${MAYA_VERIFY_GPU:-0}"
DEVICES_OUT="$(CUDA_VISIBLE_DEVICES="$GPU" "$APP_DIR/build/strata-device")"
echo "$DEVICES_OUT"

case "$BACKEND" in
    cuda) PATTERN="compute capability +[0-9]" ;;
    *) PATTERN="" ;;
esac
if ! echo "$DEVICES_OUT" | grep -qE "$PATTERN"; then
    echo "FATAL: strata-device 没有报告 CUDA GPU（后端未启用，或本机缺少 GPU/驱动？）"
    exit 1
fi

# 真实占用显存：64 MiB arena 分配/释放往返（只碰 GPU 内存，不加载模型）
echo
echo "== strata-device --selftest =="
CUDA_VISIBLE_DEVICES="$GPU" "$APP_DIR/build/strata-device" --selftest | tail -4

# nvtx3 头文件（GLM 引擎编译需要；来自 pypi nvidia-nvtx wheel + CPATH）
NVTX_H="$CONDA_PREFIX/lib/python3.12/site-packages/nvidia/cu13/include/nvtx3/nvToolsExt.h"
test -f "$NVTX_H" || { echo "FATAL: nvtx3 header missing: $NVTX_H"; exit 1; }
echo
echo "nvtx3 header: $NVTX_H"

# Python 服务：环境内 preflight 依赖 + 代码树可导入
echo
echo "== python service =="
"$BIN/python3" -c "import numpy, jinja2, regex, yaml, tqdm, requests, PIL, psutil, jsonschema; print('preflight deps ok')"
PYTHONPATH="$APP_DIR:$APP_DIR/tools" "$BIN/python3" -c \
    "import setup, maya_names, maya_quants, serve.server; print('service import ok')"
"$BIN/maya" --help >/dev/null && echo "maya --help ok"

# PC 自检（GPU/驱动/CUDA/内存/CPU）：信息性输出，不作为安装判定
echo
echo "== maya --check (information) =="
"$BIN/maya" --check --ds4-quant maya-xs || echo "(maya --check 返回非 0；见上方输出，通常是提示而非安装损坏)"

echo
echo "OK: install verified ($BACKEND backend, GPU detected)"
