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
