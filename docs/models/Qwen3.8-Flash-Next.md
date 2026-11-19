# Qwen3.8-Flash-Next

|      |      |
| ---- | ---- |
| 状态 | 主力（规划）`qwen3.8-flash-next-fp4-1m`；实验中 `qwen3.8-flash-next-iq3-1m`（2026-11-13 上线，视觉 2026-11-15 启用）；4 条目已归档（2026-11-16） |
| 权重 | UD-IQ4_XS 3 分片 + mmproj-F16（llama.cpp）；NVFP4 124G（vLLM）/ 133G（SGLang）（nvidia ModelOpt 混合精度）；GSQ-RCO IQ3_XXS 71G + mmproj-BF16（strata）。下载记录见 `docs/models.md`「2. MoE, Qwen3.8 Flash Next」 |
| 平台 | PRO6000（8×96G）；单卡条目 GPU 6，1M 双卡条目 GPU 4,6 |
| 测试版本 | vLLM 0.33.0、SGLang 0.5.23、llama.cpp b12282、strata v0.2.4.2 / 引擎 0.1.49.2（pin 理由见 `strata-prefill-regression.md`） |
| 资源占用 | 见各条目「实测」 |

> 命令约定：`${PORT}` 由 llama-swap 加载时分配；`${env.HOME}` = `/home/shmilee`。
> 宏均已展开；活动条目的运行参数以 config 为准，此处为快照。

## 条目总览

| 条目 | 后端 | ctx | prefill | decode | MTP | 使用量（9-12 → 11-13） | 状态 |
| ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| qwen3.8-flash-next-fp4-1m | vLLM NVFP4 + YaRN（TP2） | 1M | 12230 t/s（708K 冷） | 114~118 t/s | 关 | 27 次（10-15） | 主力（规划） |
| qwen3.8-flash-next-iq3-1m | strata flash_next | 1M | 4349 t/s（1M） | 161.5 t/s | — | 0 次（11-13 上线） | 实验中 |
| Qwen3.8-Flash-Next | llama.cpp UD-IQ4_XS | 256k | 1147~2499 t/s | ~90 t/s | 关 | 199 次（最后 10-23） | 已归档 2026-11-16 |
| Qwen3.8-Flash-Next-vllm | vLLM NVFP4 | 256k | 11464~13099 t/s | 118~181 t/s | 44.0% | 9 次（10-08） | 已归档 2026-11-16 |
| Qwen3.8-Flash-Next-1M | llama.cpp UD-IQ4_XS + YaRN（双卡） | 1M | 1232 t/s（82K 冷） | 48~51 t/s | 关 | 8 次（10-15） | 已归档 2026-11-16 |
| Qwen3.8-Flash-Next-sglang | SGLang NVFP4 | 256k | 未实测 | 未实测 | — | 0 次 | 已归档 2026-11-16（未使用） |

使用量来源：`activity-PRO6000.sqlite`（2026-11-13 备份）。

## qwen3.8-flash-next-fp4-1m（主力，规划）

### cmd（当前快照 2026-11-17；运行以 `config/llama-swap-config-PRO6000.yaml` 为准）

```
numactl --cpunodebind=1 pixi run -m ${env.HOME}/local-llama -e vllm-cuda vllm serve \
  /data/huggingface-downloads/Qwen3.8-Flash-Next-NVFP4 \
  --host 127.0.0.1 --port ${PORT} \
  --quantization modelopt \
  --tensor-parallel-size 2 \
  --mm-encoder-tp-mode data \
  --gpu-memory-utilization 0.95 \
  --max-model-len 1000000 \
  --hf-overrides '{"text_config":{"rope_parameters":{"mrope_interleaved":true,"mrope_section":[11,11,10],"rope_type":"yarn","rope_theta":10000000,"partial_rotary_factor":0.25,"factor":4.0,"original_max_position_embeddings":262144}}}' \
  --max-num-seqs 8 \
  --max-num-batched-tokens 16384 \
  --enable-prefix-caching \
  --moe-backend marlin \
  --attention-config.indexer_kv_dtype fp8 \
  --no-enable-flashinfer-autotune \
  --enable-per-request-metrics \
  --enable-prompt-tokens-details \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --reasoning-parser qwen3
# env: CUDA_VISIBLE_DEVICES=4,6, VLLM_PLE_CPU_OFFLOAD=1, VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
```

（无 `--speculative-config` / `--per-request-spec-decode-metrics`：TP2 下
MTP 三种组合均失败，关 MTP 定档，详见 `vllm.md`「长上下文（YaRN 1M，双卡 TP2）」。）

### 实测（2026-10-15，数据见 `speed-report.md`「Qwen3.8-Flash-Next-vllm + YaRN 1M context, dual-GPU」）

GPU Memory 95084MiB + 94932MiB，CPU 36G + 36G（PLE 表 ETP 切分，每 rank ~36G）。
实测 KV 池 3,819,165 tokens（1M 请求可并发 3.82×）。
summary：prefill 2372.27 t/s（708,215 冷 prompt 单行 12229.88 t/s）、
decode 116.90 t/s（行内 114~118）。

### 优缺点

* prefill 峰值 12.2K t/s + decode 117 t/s + TP2 下 1M 并发 3.82×，
  家族 1M 路线主力。
* 短板：MTP 必须关（TP2 无投机解码加速）；占 4,6 双卡、每卡 ~95G，
  与 DeepSeek-V4.1-Flash / IQ3 条目同组 group2（共占 4,6 卡系），自动互斥切换。

## qwen3.8-flash-next-iq3-1m（实验中）

### cmd（当前快照 2026-11-17；运行以 config 为准）

```
env -C ${env.HOME}/local-llama \
  pixi run -m ${env.HOME}/local-llama -e strata-cuda strata serve \
  --config config/strata-qwen.json \
  --port ${PORT}
```

运行参数（GPU、上下文、vision 段、PLE mlock）在 run config
`config/strata-qwen.json`，构建与 pack 说明见 `strata.md`
「Qwen3.8-Flash-Next」节。

### 实测（2026-11-12 / 11-14 / 11-15，见 `strata.md`）

1M prefill 4349 tok/s（~4min）、decode @1M 161.5 tok/s、显存 72G/96G；
RAM 驻留 ~74G（PLE 表 26.8GiB mlock + 专家 arena）。
视觉（2026-11-15 启用）：768×512 → 461 image+text tokens，
prompt 883 tok/s、decode 155 tok/s。

### 优缺点

* 1M decode 161.5 t/s 为家族最快，显存 72G/96G 有余量，视觉已启用。
* 短板：`tools: false`（不支持函数调用）；1M prefill 4349 t/s 低于
  vllm-1M；与 vllm-1M / DS4.1 共用 4,6 卡系。

## Qwen3.8-Flash-Next（已归档 2026-11-16，冻结，llama.cpp 256k）

### cmd（归档时点最终配置）

```
pixi run -m ${env.HOME}/local-llama -e llamacpp-cuda llama-server \
  --model /data/huggingface-downloads/Qwen3.8-Flash-Next/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
  --mmproj /data/huggingface-downloads/Qwen3.8-Flash-Next/mmproj-F16.gguf \
  --port ${PORT} \
  --n-gpu-layers all --device CUDA0 \
  --n-cpu-moe 0 \
  --mmproj-offload \
  --load-mode mmap+mlock --flash-attn on --fit off \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --kv-unified \
  --ubatch-size 256 \
  --cache-ram 12288 \
  --ctx-size 262144 \
  --jinja --chat-template-file /data/huggingface-downloads/Qwen-chat-templates/froggeric-v22.5.jinja \
  --reasoning on --reasoning-format deepseek
# env: CUDA_VISIBLE_DEVICES=6, GGML_CUDA_CUBLAS_COMPUTE_TYPE=fp32
# MTP 草稿模型（mtp-Qwen3.8-Flash-Next-Q8_0.gguf）待 llama.cpp PR #28243，
# 未启用
```

### 首批测试 cmd（2026-09-12，冻结；无 jinja 模板 / reasoning 参数）

```
${env.HOME}/local-llama/bin/llama-server \
  --model /data/huggingface-downloads/Qwen3.8-Flash-Next/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
  --mmproj /data/huggingface-downloads/Qwen3.8-Flash-Next/mmproj-F16.gguf \
  --port ${PORT} \
  --n-gpu-layers all --device CUDA0 \
  --n-cpu-moe 0 \
  --mmproj-offload \
  --load-mode mmap+mlock --flash-attn on --fit off \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --kv-unified \
  --ubatch-size 4096 \
  --cache-ram 12288 \
  --ctx-size 262144
```

### 实测（2026-09-12，冻结）

GPU Memory 74434MiB，MemB 31G（N-gram 表 mmap+mlock 驻留 RAM）。

| Summary | |
| --- | --- |
| Cached | 2,810 |
| Prompt | 2,887 (1147.23 t/s) |
| Generated | 3,870 (91.62 t/s) |
| Drafted | - |

| ID | Time | Cached | Prompt | Generated | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 14 | 2026-09-12 23:20:34 | 2,685 | 59 | 1,048 | 184.74 t/s | 90.69 t/s | 11.89s |
| 13 | 2026-09-12 23:19:40 | - | 2,689 | 77 | 2499.27 t/s | 89.13 t/s | 2.66s |
| 12 | 2026-09-12 23:17:19 | 76 | 55 | 2,622 | 176.78 t/s | 92.17 t/s | 28.77s |
| 11 | 2026-09-12 23:16:47 | 49 | 31 | 74 | 97.92 t/s | 90.45 t/s | 1.13s |
| 10 | 2026-09-12 23:16:28 | - | 53 | 49 | 107.40 t/s | 88.14 t/s | 1.05s |

### 优缺点

* 单卡负载最轻的 QFN 条目（74G + RAM 31G）。decode ~90 t/s 低于 vLLM 系。
* 199 次使用、最后 10-23，opencode 配置中已 disabled——被 vllm-1M /
  Strata 路线取代后无保留必要。

## Qwen3.8-Flash-Next-1M（已归档 2026-11-16，冻结）

### cmd（归档时点最终配置）

```
numactl --cpunodebind=1 pixi run -m ${env.HOME}/local-llama -e llamacpp-cuda llama-server \
  --model /data/huggingface-downloads/Qwen3.8-Flash-Next/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
  --mmproj /data/huggingface-downloads/Qwen3.8-Flash-Next/mmproj-F16.gguf \
  --port ${PORT} \
  --n-gpu-layers all --device CUDA0,CUDA1 \
  --n-cpu-moe 0 \
  --mmproj-offload \
  --load-mode mmap+mlock --flash-attn on --fit off \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --kv-unified \
  --ubatch-size 256 \
  --cache-ram 12288 \
  --ctx-size 1000000 \
  --rope-scaling yarn --rope-scale 4 --yarn-orig-ctx 262144 \
  --override-kv qwen4exp.context_length=int:1000000 \
  --jinja --chat-template-file /data/huggingface-downloads/Qwen-chat-templates/froggeric-v22.5.jinja \
  --reasoning on --reasoning-format deepseek
# env: CUDA_VISIBLE_DEVICES=4,6, GGML_CUDA_CUBLAS_COMPUTE_TYPE=fp32
# 参数细节（arch 键名 qwen4exp、NUMA 绑定理由）见 llama.cpp.md
# 「Qwen3.8-Flash-Next 1M（双卡层切分）」与 llama-swap.md「NUMA / CPU 绑定」
```

### 实测（2026-10-15，冻结）

GPU Memory 46592MiB + 43784MiB，CPU Memory 34G。

| Summary | |
| --- | --- |
| Cached | 522,309 |
| Prompt | 87,181 (1173.13 t/s) |
| Generated | 8,139 (49.65 t/s) |
| Drafted | - |

| ID | Time | Cached | Prompt | Generated | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 16147 | 2026-10-15 16:02:21 | 91,404 | 1,230 | 2,086 | 771.75 t/s | 48.83 t/s | 44.72s |
| 16146 | 2026-10-15 16:01:35 | 89,891 | 1,707 | 337 | 838.77 t/s | 48.76 t/s | 9.31s |
| 16145 | 2026-10-15 16:01:26 | 87,372 | 755 | 1,765 | 685.12 t/s | 48.85 t/s | 37.55s |
| 16144 | 2026-10-15 15:56:23 | 86,286 | 313 | 774 | 439.33 t/s | 49.34 t/s | 16.72s |
| 16143 | 2026-10-15 15:51:52 | 84,661 | 278 | 1,348 | 444.83 t/s | 49.66 t/s | 28.13s |
| 16142 | 2026-10-15 15:48:29 | 82,695 | 280 | 1,687 | 423.36 t/s | 51.17 t/s | 33.98s |
| 16141 | 2026-10-15 15:46:00 | - | 82,607 | 89 | 1231.76 t/s | 51.48 t/s | 69.32s |
| 16140 | 2026-10-15 15:40:14 | - | 11 | 53 | 21.11 t/s | 83.46 t/s | 1.16s |

### 优缺点

* 1M decode 仅 ~50 t/s（无 MTP），全面不如 vllm-1M（117 t/s）。
* YaRN（qwen4exp arch）+ 双卡层切分 + NUMA 绑定的完整参数留档于本节。

## Qwen3.8-Flash-Next-vllm（已归档 2026-11-16，冻结）

### cmd（归档时点最终配置）

```
pixi run -m ${env.HOME}/local-llama -e vllm-cuda vllm serve \
  /data/huggingface-downloads/Qwen3.8-Flash-Next-NVFP4 \
  --host 127.0.0.1 --port ${PORT} \
  --quantization modelopt \
  --tensor-parallel-size 1 \
  --gpu-memory-utilization 0.95 \
  --max-model-len 262144 \
  --max-num-seqs 4 \
  --max-num-batched-tokens 8192 \
  --enable-prefix-caching \
  --moe-backend marlin \
  --attention-config.indexer_kv_dtype fp8 \
  --no-enable-flashinfer-autotune \
  --enable-per-request-metrics \
  --enable-prompt-tokens-details \
  --per-request-spec-decode-metrics summary \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --reasoning-parser qwen3
# env: CUDA_VISIBLE_DEVICES=6, VLLM_PLE_CPU_OFFLOAD=1
```

### 实测（2026-10-08，冻结）

GPU Memory 91706MiB，CPU Memory 67G（PLE 表 CPU offload）。

| Summary | |
| --- | --- |
| Cached | 318,400 |
| Prompt | 619,450 (11559.19 t/s) |
| Generated | 23,933 (131.24 t/s) |
| Drafted | 44.0% 13615/30972 |

| ID | Time | Cached | Prompt | Generated | Drafted | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 8577 | 2026-10-08 17:26:54 | 88,000 | 97,019 | 3,901 | 44.1% (2222/5043) | 11464.38 t/s | 130.95 t/s | 30.78s |
| 8576 | 2026-10-08 17:26:23 | 67,200 | 90,817 | 2,954 | 44.1% (1682/3813) | 12801.47 t/s | 131.38 t/s | 24.53s |
| 8575 | 2026-10-08 17:25:58 | 57,600 | 69,656 | 5,157 | 43.4% (2917/6720) | 12282.35 t/s | 130.49 t/s | 40.67s |
| 8574 | 2026-10-08 17:25:18 | 54,400 | 60,261 | 86 | 76.9% (60/78) | 11772.44 t/s | 181.55 t/s | 1.10s |
| 8573 | 2026-10-08 17:22:42 | - | 1,643 | 1,442 | 44.8% (827/1845) | 1077.26 t/s | 135.13 t/s | 12.21s |
| 8572 | 2026-10-08 17:22:03 | 51,200 | 57,363 | 2,855 | 38.8% (1537/3957) | 11593.74 t/s | 123.20 t/s | 23.88s |
| 8571 | 2026-10-08 17:19:33 | - | 53,563 | 3,761 | 36.4% (1963/5400) | 13099.48 t/s | 118.17 t/s | 36.08s |
| 8570 | 2026-10-08 17:18:57 | - | 189,128 | 3,777 | 58.5% (2407/4116) | 11338.23 t/s | 154.63 t/s | 41.58s |

### 优缺点

* 单卡 256k 版：prefill 峰值 13K t/s、decode 131 t/s + MTP 44%。
  被 vllm-1M 覆盖（同权重同后端、上下文更大）。

## Qwen3.8-Flash-Next-sglang（已归档 2026-11-16，冻结，未使用）

### cmd（归档时点最终配置）

```
pixi run -m ${env.HOME}/local-llama -e sglang-cuda sglang serve \
  --host 127.0.0.1 --port ${PORT} \
  --enable-metrics \
  --enable-cache-report \
  --model-path /data/huggingface-downloads/Qwen3.8-Flash-Next-NVFP4 \
  --tp 1 \
  --fp4-gemm-backend flashinfer_cutlass \
  --moe-runner-backend flashinfer_cutlass \
  --page-size 64 \
  --mamba-track-interval 64 \
  --chunked-prefill-size 4096 \
  --context-length 262144 \
  --speculative-algorithm NEXTN \
  --speculative-num-steps 3 \
  --speculative-eagle-topk 1 \
  --speculative-num-draft-tokens 4 \
  --mamba-radix-cache-strategy extra_buffer_lazy \
  --max-running-requests 4 \
  --max-mamba-cache-size 12 \
  --mamba-ssm-dtype bfloat16 \
  --reasoning-parser qwen3 \
  --mem-fraction-static 0.96 \
  --ple-offload-embedding \
  --watchdog-timeout 3600
# env: CUDA_VISIBLE_DEVICES=6, SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK=1,
#      PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
# 请求级参数（filters.setParams 注入）：return_spec_tokens_details: true，
# stream_options: {include_usage: true}
```

### 实测

无（0 请求，未投入使用）。SGLang NVFP4 + PLE 的参数要点（flashinfer_cutlass、
watchdog、precompile）见 `sglang.md`「Flash-Next 单卡（NVFP4 + PLE）要点」。

### 优缺点

* 冷加载 ~40min 为三后端最慢（config `healthCheckTimeout` 注释实测）；
  上线后无使用，归档。

## 决策记录

* 2026-09-12 PRO6000 首批部署（llama.cpp UD-IQ4_XS，GPU 6）。
* 2026-10-02 vLLM 单卡测试；2026-10-08 vLLM + SGLang 单卡测试
  （各 9 / 0 请求）。
* 2026-10-15 新增 1M 条目（llama.cpp 双卡层切分 / vLLM TP2）；
  vLLM TP2 的 MTP 三种组合均失败，关 MTP 定档（详见 `vllm.md`）。
* 2026-11-13 strata 后端条目上线（dsv41 + flash_next）；2026-11-15
  QFN strata 视觉启用（f4f9442 同时改 dsv41 默认 build）。
* 2026-11-16 归档 4 条目：`Qwen3.8-Flash-Next`（199 次、最后 10-23，
  使用量低于 27B 家族且 opencode 配置中已 disabled）、`Qwen3.8-Flash-Next-1M`
  （8 次）、`Qwen3.8-Flash-Next-vllm`（9 次，被 vllm-1M 取代）、
  `Qwen3.8-Flash-Next-sglang`（0 次）。保留 `Qwen3.8-Flash-Next-vllm-1M`
  为家族主力条目、`Qwen3.8-Flash-Next-Strata` 实验中。cmd 与实测冻结于
  本文档，条目块机械备份于 config 归档文件（不作文档引用来源）。

## 相关

* 配置：`config/llama-swap-config-PRO6000.yaml` → `qwen3.8-flash-next-fp4-1m`、`qwen3.8-flash-next-iq3-1m`、`deepseek-v4.1-flash-iq2-512k`（同在 group2）
* 后端文档：`vllm.md`「Qwen3.8-Flash-Next 单卡（NVFP4，96G）」+「长上下文（YaRN 1M，双卡 TP2）」；
  `sglang.md`「Flash-Next 单卡（NVFP4 + PLE）要点」；
  `llama.cpp.md`「Qwen3.8-Flash-Next 1M（双卡层切分）」；
  `strata.md`「Qwen3.8-Flash-Next」+「图像（视觉）」
* 同卡模型：DeepSeek-V4.1-Flash（同组 group2，自动互斥切换）
