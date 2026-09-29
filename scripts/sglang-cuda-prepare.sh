#!/bin/bash
# 将 pip nvidia-*-cu13 包（site-packages/nvidia/cu13/）整理为标准
# CUDA toolkit 目录结构（$CONDA_PREFIX/sglang-cuda/），供 flashinfer
# JIT 按 CUDA_HOME 查找 nvcc、头文件与库。
# 幂等：symlink 覆盖式重建。
# 所需环境变量（由 pixi 注入）: CONDA_PREFIX
set -eu

SP="$CONDA_PREFIX/lib/python3.12/site-packages/nvidia"
ROOT="$CONDA_PREFIX/sglang-cuda"

if [ ! -d "$SP/cu13/bin" ]; then
    echo "FATAL: 未找到 $SP/cu13（pip 的 nvidia-cuda-nvcc 包未安装？）" >&2
    exit 1
fi

# 计算相对路径：从目录 $1 到目标 $2，用作 symlink 目标
rel() { realpath -m --relative-to="$1" "$2"; }

mkdir -p "$ROOT"
# bin 是实体目录：工具链其余入口 symlink 自 pip 包，
# nvcc 替换为 wrapper 脚本。CCCL 头文件（nvidia-cuda-runtime 13.0）与
# nvcc（nvidia-cuda-nvcc 13.4）是 PyPI 上独立版本化的包，二者的
# 编译器/工具链一致性检查必然误报；wrapper 向每次编译注入官方关闭
# define（对不触发该检查的编译是 no-op）。
rm -rf "$ROOT/bin"
mkdir -p "$ROOT/bin"
REAL_NVCC="$SP/cu13/bin/nvcc"
# wrapper 运行时按自身位置解析真实 nvcc 的相对路径，
# 不依赖写死的绝对路径，项目目录移动后仍然有效
cat > "$ROOT/bin/nvcc" <<EOF
#!/bin/bash
# 注入 -DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK，转调真实 nvcc
self_dir=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)
exec "\$self_dir/$(rel "$ROOT/bin" "$REAL_NVCC")" -DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK "\$@"
EOF
chmod +x "$ROOT/bin/nvcc"
for tool in "$SP/cu13/bin"/*; do
    name=$(basename "$tool")
    [ "$name" = "nvcc" ] && continue
    ln -sfn "$(rel "$ROOT/bin" "$tool")" "$ROOT/bin/$name"
done
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
