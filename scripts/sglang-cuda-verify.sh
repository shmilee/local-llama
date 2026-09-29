#!/usr/bin/env bash
# 验证 SGLang 环境安装：版本 + CUDA 设备 + 工具链信息展示。
# 不加载大模型、不启动服务。需要 GPU。
# 所需环境变量（由 pixi 注入）: CONDA_PREFIX, CUDA_HOME, CUDACXX, CXX
set -euo pipefail

# 确保 CUDA toolkit 布局就绪
if [ ! -x "$CUDA_HOME/bin/nvcc" ]; then
    echo "CUDA_HOME 未就绪，先跑 sglang-cuda-prepare ..."
    bash "$PIXI_PROJECT_ROOT/scripts/sglang-cuda-prepare.sh"
fi

echo "== 1. 版本信息 =="
python - <<'EOF'
import sys
import torch
import sglang
import sgl_kernel
import flashinfer
print("python    :", sys.version.split()[0])
print("torch     :", torch.__version__, "| built with CUDA:", torch.version.cuda)
print("sglang    :", sglang.__version__)
print("sgl-kernel:", sgl_kernel.__version__)
print("flashinfer:", flashinfer.__version__)
EOF

echo
echo "== 2. CUDA 设备 =="
python - <<'EOF'
import torch
assert torch.cuda.is_available(), "FATAL: torch.cuda.is_available() is False"
n = torch.cuda.device_count()
print(f"cuda available: True | devices: {n}")
for i in range(n):
    props = torch.cuda.get_device_properties(i)
    mem_gb = props.total_memory / (1024**3)
    print(f"  [{i}] {props.name}  ({mem_gb:.1f} GiB)")
EOF

echo
echo "== 3. 工具链信息（CUDA_HOME=$CUDA_HOME）=="
NVCC_VER=$("$CUDA_HOME/bin/nvcc" --version 2>/dev/null | grep -oP 'release \K[0-9.]+' | head -1)
echo "nvcc: ${NVCC_VER:-unknown} ($CUDA_HOME/bin/nvcc)"
for hdr in cuda_runtime.h curand.h cublas_v2.h; do
    test -f "$CUDA_HOME/include/$hdr" || { echo "FATAL: $CUDA_HOME/include/$hdr 缺失"; exit 1; }
done
echo "headers: cuda_runtime.h, curand.h, cublas_v2.h OK"
CXX_VER=$($CXX --version 2>/dev/null | head -1)
echo "CXX : $CXX_VER"

echo
echo "OK: sglang environment verified (versions, CUDA devices, toolchain)"
