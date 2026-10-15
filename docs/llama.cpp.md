# llama.cpp

* 官网: <https://github.com/ggml-org/llama.cpp>

## 安装方式

### pixi 源码编译（本仓库）

`pixi.toml` 的 `llamacpp-cuda` / `llamacpp-vulkan` 环境，源码编译 + 安装：

```
pixi install -e llamacpp-cuda
pixi run   -e llamacpp-cuda llamacpp-build    # 下载源码并编译 + 安装
pixi run   -e llamacpp-cuda llamacpp-verify   # 验证安装（bin + --version + GPU 设备）
pixi run   -e llamacpp-cuda llamacpp-path     # 打印 llama-server 绝对路径
```

版本与构建细节见 `pixi.toml` 的 feature 注释（当前 `LLAMACPP_VERSION = "b10909"`，
b11224 decode 吞吐回退，待上游修复）。

### Arch Linux 包（备用）

* 服务器: <https://aur.archlinux.org/packages/llama.cpp-cuda>
* 笔记本: extra/llama-cpp 或 <https://aur.archlinux.org/packages/llama.cpp-vulkan-git> / <https://aur.archlinux.org/packages/llama.cpp-sycl>
  - CPU 版本最成熟 `pacman -S llama-cpp`
  - <https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md>
  - note: sycl 依赖 intel oneapi, like
    + intel-oneapi-dpcpp-cpp, intel-compute-runtime
    + intel-oneapi-mkl-sycl, level-zero-headers, onednn
  - note: sycl 的 cmake options
    ```
        -DGGML_SYCL=ON \
        -DGGML_SYCL_F16=ON \
        -DCMAKE_C_COMPILER=icx \
        -DCMAKE_CXX_COMPILER=icpx \
    ```

## 运行测试

```
llama-cli -m XX.gguf --mmproj XX-mmproj-BF16.gguf
```

## 长上下文（YaRN 1M）

Qwen3.8-27B 原生上限 262,144，模型卡称 YaRN 可扩至 1,000,000。
配置见 `config/llama-swap-config-PRO6000.yaml` 的 `Qwen3.8-27B-1M` 条目。

```
llama-server -m Qwen3.8-27B-UD-Q8_K_XL.gguf \
  -ngl 999 -c 1000000 -fa on --parallel 1 \
  --rope-scaling yarn --rope-scale 4 --yarn-orig-ctx 262144 \
  --override-kv qwen35.context_length=int:1000000 \
  --cache-type-k q8_0 --cache-type-v q8_0
```

* **两个动作缺一不可**：`--rope-scaling yarn …` 做 YaRN 频率缩放，
  `--override-kv qwen35.context_length=int:1000000` 抬高 GGUF 元数据里的
  `context_length`（原为 262144）。llama.cpp 有硬检查会拒绝超过元数据的
  `--ctx-size`；只给 `--rope-scaling/--rope-scale` 而不改元数据会被截回 262144。
* `--rope-scale 4` 即 YaRN factor 4（内部换算为 `rope_freq_scale=1/4`）；
  `--yarn-orig-ctx 262144` 为模型原生上下文。
* arch 键名 `qwen35.context_length` 来自同 checkpoint 的实测复现
  （llama.cpp issue #27090）。若加载时报「键不存在」，需核对 GGUF 实际 arch 前缀。
* `--override-kv` 只抬高长度上限，不训练模型；长文质量由 YaRN 决定，属损失性扩展。
* 已知问题：issue #27090 报 CUDA 下 ~520K prefill 静默崩溃（b10434 复现；
  本仓库当前 b10909 更新，未验证是否已修）。
* 1M 下 f16 KV 显存不可行（16 个全注意力层），故改用 `q8_0` KV（可再降 q4_0）。
* 代价：YaRN 静态生效、短 prompt 同样受影响（官方模型卡警告会波及短文本质量）。
  第三方评测报告与 262k 原生的 mean top-20 KLD ≈ 1e-2（出处见 `docs/vllm.md`
  长上下文节）。速度下降主要来自上下文变长（decode 要读满 KV）而非 YaRN；
  公开实测中 1M 与 512K 速度无本质差别。

### Qwen3.8-Flash-Next 1M（双卡层切分）

配置见 `Qwen3.8-Flash-Next-1M` 条目（与 `Qwen3.8-Flash-Next-vllm-1M` 同卡 5,6，
group2 内互斥切换，互为 vLLM/llama.cpp 对照）：

* arch 为 `qwen4exp`（b10909 `src/llama-arch.cpp` 核验），故
  `--override-kv qwen4exp.context_length=int:1000000`。
* mrope sections [11,11,10] 在 GGUF 元数据内（`LLM_KV_ROPE_DIMENSION_SECTIONS`），
  `--rope-scaling yarn` 与 qwen35 同路径（`llama-model.cpp` 的
  `llama_model_rope_type` 对 `LLM_ARCH_QWEN4EXP` 有专门 case，
  `qwen4exp.cpp` 经 `ggml_rope_multi` 传入 `rope_type/n_ctx_orig/freq_scale`）。
* 显存：单卡 256k 实测 74.4G（`docs/speed-report.md`），1M q8_0 KV ~+15G
  ≈ 90G 偏紧且贴近 #27090 风险区，故双卡层切分（`--device CUDA0,CUDA1`，
  每卡 ~45G）。无 NVLink 时层切分仅残差流跨卡，decode 损耗可忽略。
* 全参数与 256k 条目一致（`--ubatch-size 256`、`--n-cpu-moe 0`、
  `GGML_CUDA_CUBLAS_COMPUTE_TYPE=fp32` 等），仅上下文/YaRN/设备不同，
  保证对照口径。
