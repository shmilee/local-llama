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

# --- flashinfer 预编译 kernel 包清理（vLLM >=0.33 / flashinfer 0.7.x 升级必需）---
# download-kernels 是 ad-hoc pip 安装（不在 pixi 管理内）。vllm/flashinfer
# 升级后，旧版本残留会破坏 flashinfer import：
#   * 旧版 flashinfer-jit-cache shim 无 __version__ 属性 → 0.7.3 直接
#     AttributeError（2026-11 实测）；
#   * 中断的 pip 安装会留下孤儿模块目录（dist-info 已无、目录还在），
#     同样被 import 命中。
# 故预拉前先：1) 卸载主版本与 flashinfer-python 不符的 kernel 包
# （flashinfer-cubin / flashinfer-jit-cache*，绝不动 flashinfer-python 本身）；
# 2) 若某类 kernel 包已全卸，删掉其孤儿模块目录。
FP_VER=$(python -m pip show flashinfer-python 2>/dev/null | awk '/^Version:/{print $2}')
if [ -n "$FP_VER" ]; then
    for dist in $(python -m pip list --format=freeze 2>/dev/null | cut -d= -f1 \
                 | grep -E '^flashinfer-(cubin|jit-cache)' || true); do
        dver=$(python -m pip show "$dist" 2>/dev/null | awk '/^Version:/{print $2}')
        case "$dver" in
            "" | "$FP_VER"*) : ;;  # 版本一致（含 +cuXXX 本地标签）
            *) echo "卸载过期 flashinfer kernel 包: $dist ($dver, 环境为 $FP_VER)"
               python -m pip uninstall -y "$dist" >/dev/null ;;
        esac
    done
    SP_DIR=$(python -c "import site; print(site.getsitepackages()[0])")
    if ! python -m pip list --format=freeze 2>/dev/null | cut -d= -f1 \
         | grep -qE '^flashinfer-jit-cache'; then
        for d in "$SP_DIR"/flashinfer_jit_cache "$SP_DIR"/flashinfer_jit_cache_sm*; do
            [ -e "$d" ] && { echo "清理孤儿模块目录: ${d##*/}"; rm -rf "$d"; }
        done
    fi
    if ! python -m pip list --format=freeze 2>/dev/null | cut -d= -f1 \
         | grep -qE '^flashinfer-cubin'; then
        [ -e "$SP_DIR/flashinfer_cubin" ] && { echo "清理孤儿模块目录: flashinfer_cubin"; rm -rf "$SP_DIR/flashinfer_cubin"; }
    fi
fi

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
