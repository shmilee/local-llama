# vLLM 要点

环境：pixi `vllm-cuda`（PyPI vLLM + torch cu130，工具链自包含）。
安装与验证见 `docs/pixi-environments.md`。
recipe 参考: <https://recipes.vllm.ai/Qwen/Qwen3.8-27B?hardware=rtx_pro_6000>

## 版本 pin（vLLM 0.30.0）

* 严格 pin `torch==2.13.0 / torchaudio==2.11.0 / torchvision==0.28.0 / torchcodec>=0.14`
  （cu130 构建，`+cu130` 本地版本号）。
* torch wheel 依赖的 `nvidia-*-cu13` pip 包自带 CUDA 运行时/头文件/nvcc，
  环境内不依赖系统 `/usr/local/cuda`，唯一系统依赖是 NVIDIA 驱动（`libcuda.so.1`）。

## 启动参数（Qwen3.8-27B-FP8，单卡 96G TP1）

```
vllm serve <model> \
  --tensor-parallel-size 1 \
  --max-model-len 262144 \
  --kv-cache-dtype fp8 \
  --reasoning-parser qwen3
```

* `--reasoning-parser qwen3` 实际不可选：chat template 每个 assistant 轮以
  `<think>` 开头，不加它整个思考块会落在 `message.content` 里。
* MTP 投机解码：
  ```
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}' --max-num-seqs 1016
  ```
  **`--max-num-seqs 1016` 必须同时给**：Qwen3.8-27B 是混合注意力模型
  （16 层全注意力 + 48 层 GDN 线性注意力），MTP 状态占显存后 Mamba cache
  blocks 只剩 1016，低于默认 max_num_seqs 1024 时 CUDA graph 捕获直接失败。
  MTP 接受率从 /metrics 的 `vllm:spec_decode_num_{draft,accepted}_tokens_total`
  读，吞吐本身区分不出 drafter 是否真的在工作。
* 思考强度：`chat_template_kwargs` 按请求或 `--default-chat-template-kwargs`
  全局，`{"enable_thinking": false}` 关闭思考，`{"reasoning_effort": "low"}`
  自适应思考（默认 xhigh）。
* 集群单卡实测（96G）：权重 ~28.5G，KV 池 ~170 万 tokens，
  262k 上下文可并发 6.5x。

## 前缀缓存（Mamba 混合模型的行为边界）

Qwen3.8-27B 是混合注意力模型（16 层全注意力 + 48 层 GDN 线性注意力）。
启用 prefix caching 时 vLLM 自动置 `mamba_cache_mode=align`，并把块大小抬到
1600 tokens（"attention page size >= mamba page size"，由 mamba 状态字节数
决定的内存最优值；不能用 `--mamba-block-size` 调小——attention 页会被
padding 到 mamba 页大小，浪费显存）。

* `--prefix-match-unit 64`：只控制前缀缓存键的**匹配粒度**（每 64 tokens 算
  一个 hash 键，允许在物理块内部命中），不控制 mamba 状态的存储频率。
  不设置时默认取 KV cache 各组块大小的 GCD（本模型 = 1600）。
  集群单卡实测同一 3828-token 长前缀的重复请求：默认命中 1600 tokens（42%），
  设 64 命中 3712（97%）——多轮对话场景每次请求少重算约 2100 tokens。
  开销仅为 hash 元数据（262k 序列约 4096 条），不影响显存与计算；
  取值须整除各组块大小（1600 % 64 = 0），否则启动时报错。
* mamba 状态检查点只在 prefill 分块边界与 prompt 末尾注册，且 vLLM 不缓存
  prompt 的最后一段（防截断污染）。因此：
  **短 prompt（不足 2 个完整 64-token 单元，约 <128 tokens）的重复请求
  无法命中前缀缓存**——`cached_tokens=0`、日志 hit rate 恒 0%，属预期行为；
  长共享前缀（多轮对话历史、共享 system prompt、RAG 上下文）命中正常。
* 集群单卡实测：3828-token 共享前缀的重复请求第二次命中 3712 tokens（97%）；
  81-token 短 prompt 重复请求命中 0。
* `--enable-mamba-fine-grained-prefix-cache`：在**当前请求**已命中的共享前缀
  交界处额外注册 mamba 检查点（需 MTP 投机解码 + prefix-match-unit 小于
  mamba 块大小）。对短 prompt 的重复请求不产生检查点（首次请求没有命中，
  交界处为 0），长前缀命中与不加时相同——不默认启用。

## Qwen3.8-Flash-Next 单卡（NVFP4，96G）

模型：176B 参数 = 125B 主体（512 experts，每 token 激活 10 个）+ 51B N-gram
嵌入表（PLE），每 token 激活 6B。GDN + QSA（Qwen Sparse Attention）混合注意力，
Qwen4 架构的早期预览（`Qwen4ExpForConditionalGeneration`）。

Checkpoint：nvidia ModelOpt 混合精度导出（NVFP4 routed experts + FP8 PLE +
FP8 MTP），磁盘 124GB，其中 50GB 是 PLE 表。`modules_to_not_convert` 只含
routed experts——注意力、GDN、共享专家、lm_head、视觉编码器保持高精度。

核心机制——PLE 走 CPU、其余上 GPU：

* `VLLM_PLE_CPU_OFFLOAD=1`（vLLM 0.30 默认开启）：PLE 表驻留 pinned host
  内存，GPU 经 UVA 异步预取行（架构上 N-gram 层就放在 layer 2，取数与
  layer 1 计算重叠）。host 内存需 51GB 余量。
* GPU 放 ~74.75 GiB 权重，其余留给 KV/激活/CUDA graph。单卡 96G 实测
  （gmu 0.95、bf16 KV、max-num-seqs 4、MTP3）：KV 池 10.17 GiB ≈ 357k
  tokens，262k 上下文并发 1.36x。单用户足够（并发受上下文长度限制，
  不受 seqs 限制）。
* **QSA 要求 BF16 主 KV**：`--kv-cache-dtype fp8` 直接报
  `NotImplementedError: Qwen4Exp QSA requires a BF16 main KV cache`。
  这是该条目不复用 `default-vllm` 宏（宏带 fp8 KV）的原因之一。
* `--quantization modelopt` 必须（nvidia 导出的要求，见 HF 页）。
* MTP：`--speculative-config '{"method":"mtp","num_speculative_tokens":3}'`。
  vLLM 提示 num>1 会在同一 MTP 层多次前向（本模型 MTP 单层），接受率可能
  降低；实测真实问题接受率 77.5%、平均接受长度 3.33/4、解码 135.6 t/s
  （TTFT ~0.9s）。
* `--per-request-spec-decode-metrics summary` 要求启用 speculative-config
  （否则 pydantic 校验直接失败）——这也是不能复用宏的原因。
* GDN `linear_num_key_heads=16`，TP 必须整除 16：TP∈{1,2,4,8,16}（TP3
  无效）。稀疏 MoE 单 token 计算量小，无 NVLink 的机器上 TP1 单流比多卡
  快（kubesimplify 实测 2 卡单流比 4 卡快 26%）。
* 加载 ~18min（124GB NVMe 读 ~12min + MTP ~4min + graph 捕获）。
  llama-swap 的 `healthCheckTimeout` 已相应调到 1500。
* 已知问题（vLLM 0.30.0）：`--reasoning-parser qwen3` 正确剥离思考块并计数
  `reasoning_tokens`，但响应 `reasoning_content` 为空（答案本身正确），
  chat UI 看不到思考过程。
* 第三方 NVFP4 导出（RadixArk）有 TP1 "加载完成但 API 不起"（warmup 死锁）
  的报告；nvidia 导出实测未复现。

参考：

* 官方 recipe：<https://recipes.vllm.ai/Qwen/Qwen3.8-Flash-Next>
* nvidia 导出 HF 页（`--quantization modelopt` 要求的出处）：
  <https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4>
* 单卡 RTX PRO 6000 实测：
  <https://blog.kubesimplify.com/running-qwen3-8-flash-next-on-dgx-spark-and-rtx-pro-6000>

## 环境内工具链的关键点

1. **nvcc 必须在 PATH 里**：vLLM 的 `has_flashinfer()` 用
   `shutil.which("nvcc")` 判断 flashinfer 是否可用（JIT 编译 XQA 等 kernel
   需要 nvcc），找不到就报 `FlashInfer backend is not available`。
   `pixi.toml` 的 `activation.env` 已把 `$CONDA_PREFIX/vllm-cuda/bin` 放进 PATH。
2. **torch inductor 找 nvcc 的顺序**：`config.cuda.cuda_cxx → CUDACXX →
   CUDA_HOME → 裸名 "nvcc"`。`CUDACXX` 已显式指定，正常不走 PATH。
3. **flashinfer JIT 需要完整 CUDA 工具链**（运行时 ninja+nvcc 编译 kernel）：
   `vllm-cuda-prepare` 任务把 pip nvidia 包整理成标准 CUDA toolkit 布局
   （`$CONDA_PREFIX/vllm-cuda/{bin,include,lib,lib64}`），
   并补 `stubs/libcuda.so`（conda ld 搜索路径不含系统库目录，链接 `-lcuda` 需要）。
4. **flashinfer 对 SM12.x 要求 CUDA ≥ 12.9**（`compute_120f` 家族架构），
   显式 `FLASHINFER_CUDA_ARCH_LIST="12.0a"` 匹配 Blackwell (SM120) 硬件。
5. **CCCL 版本一致性检查**：PyPI 的 `nvidia-cuda-nvcc` (13.4) 与
   `nvidia-cuda-runtime` (13.0) 版本独立，CCCL 头文件的编译器/工具链
   minor 一致性检查会误报。用官方 define 关闭：
   `FLASHINFER_EXTRA_CUDAFLAGS="-DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK"`
   （13.4 编译 13.0 头文件无实际兼容问题）。

## 集群注意事项

* 登录 PATH 末尾有 `/usr/bin/python3`（**文件**，不是目录）：裸名命令的
  PATH 查找（posix_spawn）碰到非目录项会 `ENOTDIR`。nvcc 已进 PATH 前部，
  正常启动不受影响；若新增裸名依赖且未进 PATH，需在启动侧过滤 PATH 非目录项。
* 共享集群：启动前 `nvidia-smi` 挑空闲卡（`CUDA_VISIBLE_DEVICES`）、查端口占用。
* 首次启动慢：torch.compile（inductor）+ flashinfer JIT + CUDA graph 捕获，
  几分钟量级；JIT 缓存在 `~/.cache/flashinfer/` 与 `~/.cache/vllm/`。

## 已知坑（Rust frontend）

`VLLM_USE_RUST_FRONTEND=1`（vLLM 0.30 的 vllm-rs）：

* 基本可用：chat / reasoning-parser / MTP 均工作。
* **`--enable-auto-tool-choice` 被显式忽略**（structured_outputs_config 同样），
  工具调用 XML 会直接漏进 `message.content`（finish_reason=stop 而非
  tool_calls）。Python frontend 同 flag 正常返回 `tool_calls`。
  **需要工具调用功能时不要开 Rust frontend**。
* 启动日志里 "OpenAI server is ready to accept requests" 来自 Rust 的
  server/src/lib.rs（非 Uvicorn），可确认 Rust frontend 生效。
