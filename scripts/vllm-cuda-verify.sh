#!/usr/bin/env bash
# 验证 vLLM 环境安装。不加载大模型、不启动服务。需要 GPU。
# 检查项：import/CUDA、工具链（nvcc + 头文件 + CXX）、flashinfer JIT 探针。
# 所需环境变量（由 pixi 注入）: CONDA_PREFIX, CUDA_HOME, CUDACXX, CXX
set -euo pipefail

# 确保 CUDA toolkit 布局就绪
if [ ! -x "$CUDA_HOME/bin/nvcc" ]; then
    echo "CUDA_HOME 未就绪，先跑 vllm-cuda-prepare ..."
    bash "$PIXI_PROJECT_ROOT/scripts/vllm-cuda-prepare.sh"
fi

echo "== 1. python / torch / vllm 版本 + CUDA 检查 =="
python - <<'EOF'
import sys, torch, vllm
print("python:", sys.version.split()[0])
print("torch :", torch.__version__, "| built with CUDA:", torch.version.cuda)
print("vllm  :", vllm.__version__)
assert torch.cuda.is_available(), "FATAL: torch.cuda.is_available() is False"
n = torch.cuda.device_count()
print(f"cuda available: True | devices: {n}")
for i in range(n):
    props = torch.cuda.get_device_properties(i)
    mem_gb = props.total_memory / (1024**3)
    print(f"  [{i}] {props.name}  ({mem_gb:.1f} GiB)")
EOF

echo
echo "== 2. vllm --version =="
vllm --version

# 3. 工具链自检
echo
echo "== 3. 工具链自检（CUDA_HOME=$CUDA_HOME）=="
test -x "$CUDA_HOME/bin/nvcc" || { echo "FATAL: $CUDA_HOME/bin/nvcc 不存在或不可执行（先跑 vllm-cuda-prepare）"; exit 1; }
NVCC_VER=$("$CUDA_HOME/bin/nvcc" --version 2>/dev/null | grep -oP 'release \K[0-9.]+' | head -1)
echo "nvcc: ${NVCC_VER:-unknown} ($CUDA_HOME/bin/nvcc)"
for hdr in cuda_runtime.h curand.h cublas_v2.h; do
    test -f "$CUDA_HOME/include/$hdr" || { echo "FATAL: $CUDA_HOME/include/$hdr 缺失"; exit 1; }
done
echo "headers: cuda_runtime.h, curand.h, cublas_v2.h OK"
# CXX 可运行
CXX_VER=$($CXX --version 2>/dev/null | head -1)
echo "CXX : $CXX_VER"

# 4. flashinfer JIT 探针
echo
echo "== 4. flashinfer JIT 探针（nvcc 编译 + GPU 运行）=="
python - <<'EOF'
import torch, flashinfer
print("flashinfer:", flashinfer.__version__)
q = torch.randn(4, 8, 64, dtype=torch.bfloat16, device="cuda")
k = torch.randn(16, 8, 64, dtype=torch.bfloat16, device="cuda")
v = torch.randn(16, 8, 64, dtype=torch.bfloat16, device="cuda")
o = flashinfer.single_prefill_with_kv_cache(q, k, v, causal=True)
assert o.shape == (4, 8, 64), f"unexpected output shape {o.shape}"
print("JIT compile + GPU run OK, output shape:", tuple(o.shape))
EOF

echo
echo "OK: vllm environment verified (torch+vllm import, CUDA available, toolchain, flashinfer JIT)"
