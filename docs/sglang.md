# SGLang 要点

环境：pixi `sglang-cuda`（PyPI SGLang + torch cu130，工具链自包含）。
安装与验证见 `docs/pixi-environments.md`。
recipe 参考: <https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8>

## 版本 pin（SGLang 0.5.20）

* 核心 pin：`torch==2.13.0 / torchaudio==2.11.0 / torchcodec==0.15.0 /
  transformers==5.12.1`、`sglang-kernel==0.4.7`（abi3 单 wheel，不分 CUDA
  版本，依赖仅 `torch==2.13.0`）、`flashinfer_python[cu13]==0.6.18`
  （cu13 extra 直接拉 CUDA 13 构建）、`cuda-tile==1.6.0rc5`（预发布版，
  需 feature 级 `prerelease-mode = "allow"`）。
* **sglang 与 vllm 的 transformers/torchcodec pin 冲突**，必须各自独立
  solve-group，不能合并成一个环境。
* 入口：官方推荐 `sglang serve --model-path ...`（`python -m sglang.launch_server`
  已弃用但兼容）。压测：`python -m sglang.benchmark.serving`
  （`sglang.bench_serving` 已弃用）。

## 启动参数（Qwen3.8-27B-FP8，单卡 96G）

```
sglang serve --model-path <model> \
  --host 127.0.0.1 --port <port> \
  --reasoning-parser qwen3
```

* `--reasoning-parser qwen3`：把 `<think>...</think>` 块分离到
  `reasoning_content`，`content` 只留答案。思考深度按请求用
  `reasoning_effort`（xhigh 默认 / medium / low）调节。
* 工具调用：`--tool-call-parser qwen3_coder`（结构化 `message.tool_calls`）。
* 多卡：`--tp-size N`。
* 上下文：默认取模型上限（262144），显式 `--context-length` 可降。
* MTP：checkpoint 自带 MTP 权重时，sglang 有 NEXTN 投机预设（无需 draft
  模型）；注意投机解码场景下 `--max-running-requests` 会被投机钩子钳到
  48，需要更高并发时显式指定。
  官方 cookbook（Qwen3.8-27B 页）推荐组合：
  `--speculative-algorithm NEXTN --speculative-num-steps 3
  --speculative-eagle-topk 1 --speculative-num-draft-tokens 4`
  （NEXTN 是 EAGLE 的别名，同一算法；MTP 与 FlashInfer 搭配要求
  flashinfer 比 0.6.15.post1 新）。Qwen3.8-27B-FP8 单卡 96G 实测：
  解码 56 → ~190 t/s（接受率 79%，平均接受长度 3.37 token/轮，
  接受率随内容波动）。`--mamba-track-interval`（默认 256）须 ≥
  speculative-num-draft-tokens，默认值满足。

## 逐请求统计（llama-swap 集成）

* `--enable-cache-report`（在 `default-sglang` 宏里）：在 OpenAI 响应返回
  `usage.prompt_tokens_details.cached_tokens`，llama-swap 的 Cached 列
  依赖该字段；不加则 `prompt_tokens_details` 为 null，统计显示 "-"。
* radix cache 对短 prompt 也能命中（如 81-token prompt 命中 64），
  与 vLLM 的 mamba 1600-token 块限制不同（见 docs/vllm.md）。
* SGLang 的 OpenAI 响应**不含逐请求时延字段**（无 ttft/itl/throughput；
  llama.cpp 有 `timings` 对象、vLLM 有 `metrics` 对象，SGLang 两者皆无），
  投机解码统计在 `sglext.spec_tokens_details`（请求级
  `return_spec_tokens_details` 开启）。llama-swap（v260，上游 main 亦同）
  只解析后两种格式，故 SGLang 后端的 Prefill/Decode 速率与 Drafted 列
  无数据来源，llama-swap 侧显示 unknown / "-"。

## 混合注意力（GDN）模型的关键点

Qwen3.8 系列是混合注意力：全注意力 + Gated DeltaNet（线性注意力，SSM +
CausalConv1d）。

* GDN 层的递归状态住在**独立内存池**（mamba state），不是 KV。
  并发上限通常由它而非 KV 决定。相关参数：
  `--mamba-full-memory-ratio`（状态池占显存比例，默认 0.9）、
  `--max-mamba-cache-size`（状态槽数，须与 caching 策略的每请求槽数匹配：
  `extra_buffer` 默认 5 槽 / `no_buffer` 3 槽 / `--disable-radix-cache` 1 槽，
  不匹配会静默钳制 `max_running_requests`）。
* 线性注意力 kernel 后端按 GPU 代际不同：SM120（Blackwell 消费/工作站卡）
  默认 triton；SM100 上 flashinfer GDN decode 依赖
  `--mamba-ssm-dtype bfloat16`。
* `--attention-backend trtllm_mha` 仅 SM100；Blackwell 上留空由模型钩子
  自动选择（并配套 `--page-size 64`）。

## 环境内工具链的关键点

1. **sglang 自带 JIT**（`sgl_kernel_jit_*`，如 FP8 blockwise GEMM on SM120）
   运行时用 nvcc 编译，工具链取自 `CUDA_HOME`（`sglang-cuda-prepare`
   生成的 `$CONDA_PREFIX/sglang-cuda/` 布局）与 `CXX`。
2. **CCCL 版本一致性检查**：sglang 的 JIT **不读取** flashinfer 的
   `FLASHINFER_EXTRA_CUDAFLAGS`，nvcc (13.4) 与 CCCL 头文件 (13.0) 的
   检查误报会直接编译失败。解法：`sglang-cuda-prepare` 把布局里的 `nvcc`
   替换为 wrapper 脚本，向每次编译注入
   `-DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK`（官方关闭 define，
   对不触发该检查的编译是 no-op）。
3. `FLASHINFER_CUDA_ARCH_LIST="12.0a"`：flashinfer 对 SM12.x 默认要求
   CUDA ≥ 12.9（`compute_120f`），显式给 12.0a 匹配 SM120 硬件。
4. flashinfer JIT 缓存在 `~/.cache/flashinfer/`，sglang JIT 缓存在
   `~/.cache/sglang/`；链接失败后需清对应缓存重编译。

## 已知无害警告

* import 多模态音频模块时打印 `Could not load libtorchcodec` /
  `libavutil.so.*: cannot open`：torchcodec 需要系统 FFmpeg 动态库，
  纯文本推理不受影响（sglang 直接忽略该 import 错误）。
* `Failed to get device capability: SM 12.x requires CUDA >= 12.9`：
  探测逻辑问题，实际 torch cu130 构建满足，不影响功能。

## 集群注意事项

* 共享集群：启动前 `nvidia-smi` 挑空闲卡（`CUDA_VISIBLE_DEVICES`）、查端口。
* 首次启动慢：sglang JIT（CUTLASS kernel）+ flashinfer autotune +
  CUDA graph 捕获，几分钟量级。
* 偶发：CUDA graph 捕获期 CUTLASS 报 "Error Internal"
  （fp8_blockwise sm120 kernel）导致启动失败，重启即可恢复。
