#!/bin/bash
# 将 pip nvidia-*-cu13 包（site-packages/nvidia/cu13/）整理为标准
# CUDA toolkit 目录结构（$CONDA_PREFIX/vllm-cuda/），供 flashinfer
# JIT 与 torch inductor 按 CUDA_HOME 查找 nvcc、头文件与库。
# 幂等：symlink 覆盖式重建。
# 所需环境变量（由 pixi 注入）: CONDA_PREFIX
set -eu

SP="$CONDA_PREFIX/lib/python3.12/site-packages/nvidia"
ROOT="$CONDA_PREFIX/vllm-cuda"

if [ ! -d "$SP/cu13/bin" ]; then
    echo "FATAL: 未找到 $SP/cu13（pip 的 nvidia-cuda-nvcc 包未安装？）" >&2
    exit 1
fi

# 计算相对路径：从目录 $1 到目标 $2，用作 symlink 目标
rel() { realpath -m --relative-to="$1" "$2"; }

mkdir -p "$ROOT"
ln -sfn "$(rel "$ROOT" "$SP/cu13/bin")" "$ROOT/bin"
ln -sfn "$(rel "$ROOT" "$SP/cu13/include")" "$ROOT/include"
ln -sfn "$(rel "$ROOT" "$SP/cu13/lib")" "$ROOT/lib"
# flashinfer 链接用 $CUDA_HOME/lib64（标准 CUDA 布局）
ln -sfn "$(rel "$ROOT" "$ROOT/lib")" "$ROOT/lib64"
# PyPI 包只有版本化 .so.13，补开发符号链接供 -lcudart 使用
if [ -f "$SP/cu13/lib/libcudart.so.13" ]; then
    ln -sfn "libcudart.so.13" "$SP/cu13/lib/libcudart.so"
fi
# conda ld 搜索路径不含系统库目录，补 stubs/libcuda.so 供 -lcuda 链接
# （stub 仅链接时使用，运行时 ld.so 按 SONAME 找真实驱动）
# 这里是唯一使用绝对路径的链接：目标在 pixi 项目目录之外
mkdir -p "$ROOT/lib64/stubs"
DRIVER_LIB=""
for cand in \
    /usr/lib/x86_64-linux-gnu/libcuda.so.1 \
    /usr/lib64/libcuda.so.1 \
    /usr/lib/libcuda.so.1; do
    if [ -e "$cand" ]; then
        DRIVER_LIB="$cand"
        break
    fi
done
if [ -n "$DRIVER_LIB" ]; then
    ln -sf "$DRIVER_LIB" "$ROOT/lib64/stubs/libcuda.so"
else
    echo "WARN: 未找到系统驱动库 libcuda.so.1（链接 -lcuda 会失败，运行时需确保驱动已装）"
fi

NVCC_VER=$("$ROOT/bin/nvcc" --version 2>/dev/null | grep -oP 'release \K[0-9.]+' | head -1)
echo "CUDA_HOME ready: $ROOT (nvcc ${NVCC_VER:-unknown})"

# 预拉取 flashinfer 预编译 kernel（vLLM >=0.33 的官方方式，幂等）：
#   flashinfer-cubin（~1.6GB，GitHub release）+ flashinfer-jit-cache。
# 不预拉时首次启动退化为 JIT 编译，多花几分钟（功能等价）。
# 依赖 pixi 任务环境提供的 vllm 可执行文件与 pip（vllm download-kernels
# 内部走 `python -m pip install`）。
# 失败不致命：GitHub release CDN 在部分网络（国内直连）下不可达，
# 此时回退 JIT 即可，故给 timeout 并以 WARN 结束。
if command -v vllm >/dev/null 2>&1; then
    if timeout 900 vllm download-kernels; then
        echo "flashinfer 预编译 kernel 已就绪（首启免 JIT 编译）"
    else
        echo "WARN: vllm download-kernels 失败/超时（flashinfer-cubin 来自 GitHub release，"
        echo "      网络不通时属预期）——首次启动回退 JIT 编译，功能不受影响"
    fi
else
    echo "WARN: vllm 不在 PATH，跳过 download-kernels（JIT 编译仍可用）"
fi
