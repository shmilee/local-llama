# Qwen3.8-27B

|      |      |
| ---- | ---- |
| 状态 | 主力 `qwen3.8-27b-fp8-1m`（2026-10-14 起）；备用 `qwen3.8-27b-q8-256k`（llama.cpp）；3 条目已归档（2026-11-16） |
| 权重 | `Qwen3.8-27B-UD-Q8_K_XL.gguf` + `mmproj-BF16.gguf`（llama.cpp）；`Qwen3.8-27B-FP8` 30.9G（vLLM/SGLang）。下载记录见 `docs/models.md`「1. Dense, Qwen3.8」 |
| 平台 | PRO6000（8×96G），GPU 2 |
| 测试版本 | vLLM 0.33.0、SGLang 0.5.23、llama.cpp b12282（当前，pin 与构建见 `pixi-environments.md` / `llama.cpp.md`） |
| 资源占用 | 见各条目「实测」 |

> 命令约定：`${PORT}` 由 llama-swap 加载时分配；`${env.HOME}` = `/home/shmilee`。
> 宏（`default-llama` / `default-vllm` / `default-sglang` / `models_dir` / `ctx_*`）
> 均已展开；活动条目的运行参数以 config 为准，此处为快照。

## 条目总览

| 条目 | 后端 | ctx | prefill | decode | MTP 接受率 | 使用量（9-12 → 11-13） | 状态 |
| ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| qwen3.8-27b-fp8-1m | vLLM FP8 + YaRN | 1M | 2360 t/s（359K 冷） | 62~95 t/s | 56.9% | 45,915 次 | 主力 |
| qwen3.8-27b-q8-256k | llama.cpp Q8 | 256k | 739~2016 t/s | ~85 t/s | 67.8% | 14,564 次 | 备用 |
| Qwen3.8-27B-1M | llama.cpp Q8 + YaRN | 1M | 1318 t/s（227K 冷） | 33 t/s | 45.7% | 86 次（10-14 单日） | 已归档 2026-11-16 |
| Qwen3.8-27B-vllm | vLLM FP8 | 256k | 3336 t/s（224K） | 66 t/s | 43.6% | 6 次（10-08） | 已归档 2026-11-16 |
| Qwen3.8-27B-sglang | SGLang FP8 | 256k | 未上报 | 75~91 t/s | 54.9% | 135 次（10-08 → 09） | 已归档 2026-11-16 |

使用量来源：`activity-PRO6000.sqlite`（2026-11-13 备份）。

## qwen3.8-27b-fp8-1m（主力）

### cmd（当前快照 2026-11-17；运行以 `config/llama-swap-config-PRO6000.yaml` 为准）

```
pixi run -m ${env.HOME}/local-llama -e vllm-cuda vllm serve \
  --host 127.0.0.1 --port ${PORT} \
  --enable-per-request-metrics \
  --enable-prompt-tokens-details \
  --per-request-spec-decode-metrics summary \
  --max-num-seqs 8 \
  --tensor-parallel-size 1 \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --prefix-match-unit 64 \
  --sse-keep-alive-interval 15 \
  /data/huggingface-downloads/Qwen3.8-27B-FP8 \
  --max-model-len 1000000 \
  --hf-overrides '{"text_config":{"rope_parameters":{"mrope_interleaved":true,"mrope_section":[11,11,10],"rope_type":"yarn","rope_theta":10000000,"partial_rotary_factor":0.25,"factor":4.0,"original_max_position_embeddings":262144}}}' \
  --reasoning-parser qwen3 \
  --mm-encoder-tp-mode data \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_xml \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}'
# env: CUDA_VISIBLE_DEVICES=2, VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
```

### 实测（2026-10-14，数据见 `speed-report.md`「Qwen3.8-27B-vllm + YaRN 1M context」）

GPU Memory 91910MiB，CPU 3.7G。单卡 96G 接近打满。
summary：prefill 898.96 t/s（359,808 冷 prompt 单行 2360.36 t/s）、
decode 68.46 t/s（行内 62~95）、MTP 接受率 56.9%。
YaRN factor 4 静态生效（短 prompt 同样受影响）。

### 优缺点

* 1M 上下文 + MTP 56.9% + decode 62~95 t/s，长上下文主力。
* 短板：YaRN 静态生效、官方警告波及短文本质量；单卡 96G 接近打满，
  大并发无余量。

## qwen3.8-27b-q8-256k（备用，llama.cpp）

### cmd（当前快照 2026-11-17；运行以 config 为准）

```
pixi run -m ${env.HOME}/local-llama -e llamacpp-cuda llama-server \
  --port ${PORT} \
  --n-gpu-layers all --device CUDA0 \
  --mmproj-offload \
  --load-mode auto --flash-attn on --fit off \
  --cache-type-k f16 --cache-type-v f16 \
  --kv-unified \
  --ubatch-size 4096 \
  --model /data/huggingface-downloads/Qwen3.8-27B/Qwen3.8-27B-UD-Q8_K_XL.gguf \
  --mmproj /data/huggingface-downloads/Qwen3.8-27B/mmproj-BF16.gguf \
  --ctx-size 262144 \
  --cache-ram 12288 \
  --jinja --chat-template-file /data/huggingface-downloads/Qwen-chat-templates/peculiar-ragdoll-v22.5.0.jinja \
  --reasoning on --reasoning-format deepseek \
  --spec-type draft-mtp --spec-draft-n-max 3
# env: CUDA_VISIBLE_DEVICES=2
```

### 首批测试 cmd（2026-09-12，冻结；无 jinja 模板 / reasoning 参数）

```
${env.HOME}/local-llama/bin/llama-server \
  --port ${PORT} \
  --n-gpu-layers all --device CUDA0 \
  --mmproj-offload \
  --load-mode auto --flash-attn on --fit off \
  --cache-type-k f16 --cache-type-v f16 \
  --kv-unified \
  --ubatch-size 4096 \
  --model /data/huggingface-downloads/Qwen3.8-27B/Qwen3.8-27B-UD-Q8_K_XL.gguf \
  --mmproj /data/huggingface-downloads/Qwen3.8-27B/mmproj-BF16.gguf \
  --ctx-size 262144 \
  --cache-ram 12288 \
  --spec-type draft-mtp --spec-draft-n-max 3
```

### 实测（2026-09-12 首批，数据见 `speed-report.md`「PRO6000 w/ llama.cpp → Qwen3.8-27B」）

GPU Memory 53092MiB，MemB 4.1G。
summary：prefill 738.69 t/s（行内最高 2016）、decode 85.11 t/s（行内 73~92）、
MTP 接受率 67.8%（全家族最高）。

### 优缺点

* MTP 接受率 67.8% 最高，单卡负载轻（53G + MemB 4.1G），主力故障时的回退。
* 短板：256k 上限，decode ~85 t/s 低于 vllm-1M 的上限水平。

## Qwen3.8-27B-1M（已归档 2026-11-16，冻结）

### cmd（归档时点最终配置）

```
pixi run -m ${env.HOME}/local-llama -e llamacpp-cuda llama-server \
  --port ${PORT} \
  --n-gpu-layers all --device CUDA0 \
  --model /data/huggingface-downloads/Qwen3.8-27B/Qwen3.8-27B-UD-Q8_K_XL.gguf \
  --mmproj /data/huggingface-downloads/Qwen3.8-27B/mmproj-BF16.gguf \
  --mmproj-offload \
  --load-mode auto --flash-attn on --fit off \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --kv-unified \
  --ubatch-size 4096 \
  --ctx-size 1000000 \
  --rope-scaling yarn --rope-scale 4 --yarn-orig-ctx 262144 \
  --override-kv qwen35.context_length=int:1000000 \
  --cache-ram 12288 \
  --jinja --chat-template-file /data/huggingface-downloads/Qwen-chat-templates/peculiar-ragdoll-v22.5.0.jinja \
  --reasoning on --reasoning-format deepseek \
  --spec-type draft-mtp --spec-draft-n-max 3
# env: CUDA_VISIBLE_DEVICES=2
```

YaRN / override-kv 两个动作缺一不可、q8_0 KV 的显存依据见 `llama.cpp.md`
「长上下文（YaRN 1M）」。

### 实测（2026-10-14，冻结）

GPU Memory 82598MiB，CPU Memory 49G（cache-ram 12G + 模型 mmap）。

| Summary | |
| --- | --- |
| Cached | 1,161,297 |
| Prompt | 231,260 (1227.25 t/s) |
| Generated | 6,243 (32.81 t/s) |
| Drafted | 45.7% 3613/7899 |

| ID | Time | Cached | Prompt | Generated | Drafted | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 14843 | 2026-10-14 17:17:28 | 234,896 | 234 | 150 | 59.9% (97/162) | 105.83 t/s | 36.33 t/s | 7.21s |
| 14842 | 2026-10-14 17:17:21 | 233,300 | 1,330 | 265 | 60.0% (171/285) | 408.06 t/s | 36.59 t/s | 11.35s |
| 14841 | 2026-10-14 17:17:09 | 233,029 | 173 | 99 | 79.3% (69/87) | 88.82 t/s | 44.38 t/s | 5.07s |
| 14840 | 2026-10-14 17:17:04 | 232,854 | 89 | 86 | 72.8% (59/81) | 46.29 t/s | 41.12 t/s | 4.87s |
| 14839 | 2026-10-14 17:16:59 | 227,218 | 2,046 | 3,591 | 43.4% (2030/4680) | 332.26 t/s | 31.45 t/s | 121.21s |
| 14838 | 2026-10-14 17:12:20 | - | 227,222 | 2,018 | 45.2% (1162/2571) | 1318.46 t/s | 33.68 t/s | 233.17s |
| 14837 | 2026-10-14 16:57:57 | - | 166 | 34 | 75.8% (25/33) | 276.57 t/s | 68.06 t/s | 1.11s |

### 优缺点

* llama.cpp 1M 路线的对照数据。decode 33 t/s（读满 1M KV）、MTP 45.7%
  均低于 vllm-1M（68 / 56.9%），无保留价值；YaRN 参数留档于本文档。

## Qwen3.8-27B-vllm（已归档 2026-11-16，冻结）

### cmd（归档时点最终配置）

```
pixi run -m ${env.HOME}/local-llama -e vllm-cuda vllm serve \
  --host 127.0.0.1 --port ${PORT} \
  --enable-per-request-metrics \
  --enable-prompt-tokens-details \
  --per-request-spec-decode-metrics summary \
  --max-num-seqs 8 \
  --tensor-parallel-size 1 \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --prefix-match-unit 64 \
  /data/huggingface-downloads/Qwen3.8-27B-FP8 \
  --max-model-len 262144 \
  --reasoning-parser qwen3 \
  --mm-encoder-tp-mode data \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_xml \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}'
# env: CUDA_VISIBLE_DEVICES=2
```

（测试日期 2026-10-08 早于 `--sse-keep-alive-interval 15` 加入宏，
该参数对此条目无影响。）

### 实测（2026-10-08，冻结）

GPU Memory 91414MiB，CPU Memory 3.0G。

| Summary | |
| --- | --- |
| Cached | 224,512 |
| Prompt | 455,287 (2171.60 t/s) |
| Generated | 9,742 (66.38 t/s) |
| Drafted | 43.6% 5521/12657 |

| ID | Time | Cached | Prompt | Generated | Drafted | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 8566 | 2026-10-08 17:09:03 | - | 1,316 | 432 | 52.9% (265/501) | 6377.80 t/s | 85.78 t/s | 5.25s |
| 8565 | 2026-10-08 17:07:58 | - | 68 | 1,379 | 46.4% (802/1728) | 35.30 t/s | 79.52 t/s | 19.28s |
| 8564 | 2026-10-08 17:06:05 | 224,512 | 229,290 | 3,293 | 39.7% (1790/4506) | 1635.63 t/s | 61.13 t/s | 57.21s |
| 8563 | 2026-10-08 17:02:36 | - | 224,613 | 4,638 | 45.0% (2664/5922) | 3335.59 t/s | 65.77 t/s | 138.79s |

### 优缺点

* 256k 版 vLLM 对照数据。decode 66 t/s / MTP 43.6%，均被 vllm-1M 覆盖
  （同权重同后端、上下文更大）。

## Qwen3.8-27B-sglang（已归档 2026-11-16，冻结）

### cmd（归档时点最终配置）

```
pixi run -m ${env.HOME}/local-llama -e sglang-cuda sglang serve \
  --host 127.0.0.1 --port ${PORT} \
  --enable-metrics \
  --enable-cache-report \
  --model-path /data/huggingface-downloads/Qwen3.8-27B-FP8 \
  --trust-remote-code \
  --attention-backend flashinfer \
  --chunked-prefill-size 2048 \
  --kv-cache-dtype fp8_e4m3 \
  --mem-fraction-static 0.85 \
  --mamba-full-memory-ratio 4.59 \
  --mamba-radix-cache-strategy extra_buffer \
  --mamba-ssm-dtype bfloat16 \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --speculative-algorithm NEXTN \
  --speculative-num-steps 3 \
  --speculative-eagle-topk 1 \
  --speculative-num-draft-tokens 4
# env: CUDA_VISIBLE_DEVICES=2
# 请求级参数（filters.setParams 注入）：return_spec_tokens_details: true，
# stream_options: {include_usage: true}
```

### 实测（2026-10-08 → 10-09，冻结）

GPU Memory 82422MiB，CPU Memory 4.3G。
Prefill 列 unknown（SGLang OpenAI 响应无逐请求计时字段，见 `sglang.md`
「逐请求统计」）。

| Summary | |
| --- | --- |
| Duration | 175.65s |
| Cached | 874,621 |
| Prompt | 1,020,652 (unknown) |
| Generated | 10,216 (77.16 t/s) |
| Drafted | 54.9% 6357/11574 |

| ID | Time | Cached | Prompt | Generated | Drafted | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 8712 | 2026-10-09 08:48:21 | 149,760 | 150,099 | 129 | 61.5% (83/135) | unknown | 80.52 t/s | 2.39s |
| 8711 | 2026-10-09 08:48:18 | 147,584 | 149,687 | 287 | 64.6% (190/294) | unknown | 82.31 t/s | 5.03s |
| 8710 | 2026-10-09 08:48:13 | 147,456 | 147,600 | 91 | 73.8% (62/84) | unknown | 91.46 t/s | 1.67s |
| 8709 | 2026-10-09 08:48:11 | 145,600 | 147,380 | 137 | 72.1% (93/129) | unknown | 89.66 t/s | 2.90s |
| 8708 | 2026-10-09 02:08:29 | 145,408 | 145,617 | 1,724 | 58.2% (1097/1884) | unknown | 77.20 t/s | 23.03s |
| 8707 | 2026-10-09 02:08:05 | - | 139,615 | 5,842 | 56.1% (3665/6531) | unknown | 75.84 t/s | 113.49s |
| 8706 | 2026-10-09 02:04:35 | 1,088 | 1,194 | 152 | 52.5% (93/177) | unknown | 85.83 t/s | 1.86s |
| 8705 | 2026-10-09 02:04:13 | - | 1,106 | 452 | 48.7% (269/552) | unknown | 82.33 t/s | 5.71s |
| 8704 | 2026-10-09 02:00:15 | - | 323 | 853 | 35.6% (440/1236) | unknown | unknown | 12.43s |
| 8703 | 2026-10-09 01:36:54 | 137,728 | 138,031 | 549 | 66.1% (365/552) | unknown | unknown | 7.14s |

### 优缺点

* decode 77 t/s 略高于 vllm-1M summary，但 Prefill 无数据、MTP 54.9%
  低于 vllm；单次测试后未再使用。mamba 系参数（`--mamba-full-memory-ratio`
  等）是 27B 混合架构在 SGLang 上的调优参考。

## 决策记录

* 2026-09-12 PRO6000 首批部署，llama.cpp Q8 条目为主力（累计 14,564 请求）。
* 2026-10-08 vLLM / SGLang 后端条目单日测试（各 6 / 135 请求）。
* 2026-10-14 新增 1M 条目（llama.cpp + vLLM）；**vllm-1M 升为主力**：
  opencode 长上下文压缩需 1M 上下文（见
  `issue-opencode-long-context-timeout.md`），且 vLLM 1M 的 decode（68 t/s
  summary）与 MTP 接受率（56.9%）均优于 llama.cpp 1M（33 t/s / 45.7%）。
  此后使用量向 vllm-1M 迁移，27B llama.cpp 降为备用。
* 2026-11-16 归档 3 条目：`Qwen3.8-27B-1M`（仅 86 次、单日，被 vllm-1M
  全面超越）、`Qwen3.8-27B-vllm`（6 次，无 1M）、`Qwen3.8-27B-sglang`
  （135 次，单次测试）。cmd 与实测冻结于本文档，条目块机械备份于
  config 归档文件（不作文档引用来源）。

## 相关

* 配置：`config/llama-swap-config-PRO6000.yaml` → `qwen3.8-27b-q8-256k`、`qwen3.8-27b-fp8-1m`
* 后端文档：`vllm.md`「启动参数（Qwen3.8-27B-FP8…）」+「长上下文（YaRN 1M）」；
  `sglang.md`「启动参数（Qwen3.8-27B-FP8…）」；`llama.cpp.md`「长上下文（YaRN 1M）」
* issue：`issue-opencode-long-context-timeout.md`
* 候选池：`docs/models.md`「1. Dense, Qwen3.8」
