# Inkling-2-Mini

|      |      |
| ---- | ---- |
| 状态 | 待上线（2026-11-26 模型已下载 + 条目已登记；vllm-cuda 环境为 0.34，需升级到 vLLM nightly ≥0.35 才能启动） |
| 权重 | NVFP4（modelopt）19.5G + `mtp.safetensors` 606M（DSpark 草稿）。混合精度：MoE 专家（~94% 参数）FP4，其余 BF16。下载记录见 `docs/models.md`「5. MoE, Inkling-2-Mini」 |
| 平台 | PRO6000（8×96G），GPU 3（node 0，不共卡） |
| 测试版本 | vLLM nightly（≥0.35，未发布；稳定版 0.34 不支持 `inkling2_loop` 架构） |
| 资源占用 | 权重 19.5G + mtp 0.6G + 262k KV ~48G（bf16）≈ 68G / 96G（预算；首跑实测待） |

> 命令约定：`${PORT}` 由 llama-swap 加载时分配；宏已展开。

## 条目总览

| 条目 | 后端 | ctx | prefill | decode | DSpark 接受率 | 使用量 | 状态 |
| ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| `inkling-2-mini-fp4-262k` | vLLM nightly（TP1） | 262k | 待首跑 | 待首跑 | 待首跑 | 0 | 待上线 |

## `inkling-2-mini-fp4-262k`（待上线）

### cmd（2026-11-26 登记快照；活动条目以 config 为准）

```
pixi run -m ${env.LOCAL_LLAMA_HOME} -e vllm-cuda vllm serve
  /data/huggingface-downloads/Inkling-2-Mini
  --host 127.0.0.1 --port ${PORT}
  --tensor-parallel-size 1
  --max-model-len 262144
  --reasoning-parser inkling
  --enable-auto-tool-choice
  --tool-call-parser inkling
  --speculative-config '{"method":"dspark","num_speculative_tokens":7,"draft_sample_method":"probabilistic"}'
  --enable-per-request-metrics
  --enable-prompt-tokens-details
  --per-request-spec-decode-metrics summary
  --max-num-seqs 6
  --sse-keep-alive-interval 15
```

env：`CUDA_VISIBLE_DEVICES=3`；ttl 36000；routing group3（与 group1/2 并存）；
调度优先级 8（介于 27B-fp8-1m 的 10 与 flash-next-fp4-1m 的 6 之间）。

### 实测

待首跑（vllm-cuda 环境升级 nightly 后补）。

### 优缺点

* 26B 总参 / 3.5B 激活 MoE，文本 + 图片输入，128 专家 top-8；checkpoint 捆绑
  DSpark 投机草稿（`num_speculative_tokens=7`），decode 速度预期较好。
* 循环架构：core 12 层 × 3 pass + prelude/coda 各 6 层 = 48 次层访问、48 个独立
  KV cache（~192KiB/tok @bf16，head_dim 128、8 kv heads），KV 是同时代模型
  两倍量级：1M 上下文仅 GB200 186G 单卡放得下，96-128G 档官方验证上限 262k。
* vLLM 支持处于 bleeding edge：nightly only（≥0.35，0.35 未发布）；升级
  vllm-cuda 环境会对在役的 27B-fp8 / flash-next-fp4 条目产生影响，需一并回归
  （见 `docs/vllm.md`）。

## 决策记录

* 2026-11-26 新增模型条目：ModelScope 镜像下载至
  `/data/huggingface-downloads/Inkling-2-Mini/`（20.2GB，20:09–20:43 约 34min，
  单连接均速 ~10MB/s；hf-mirror 对本仓库仅 ~0.3MB/s 弃用）；文件大小与
  HF API tree 逐一比对一致；登记 llama-swap 条目
  （GPU 3、group3）+ opencode HHF 模型列表；启动被 vllm nightly 依赖阻塞，
  状态置「待上线」。recipe 依据：
  <https://recipes.vllm.ai/thinkingmachines/Inkling-2-Mini>
  （`dgx_spark_gb10` 变体 `--max-model-len 262144` 即 96-128G 档验证值）。

## 相关

* 候选池与下载记录：`docs/models.md`「5. MoE, Inkling-2-Mini」
* vLLM 工具链与版本：`docs/vllm.md`
* 路由分组：`docs/llama-swap.md`「配置文件结构（PRO6000）」
