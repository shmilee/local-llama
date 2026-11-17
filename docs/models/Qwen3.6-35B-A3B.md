# Qwen3.6-35B-A3B

|      |      |
| ---- | ---- |
| 状态 | 已被 Qwen3.8-27B 取代（PRO6000，最后使用 2026-09-23）；T14p 仍在用 |
| 权重 | PRO6000：UD-Q8_K_XL + mmproj-BF16；T14p：Huihui-Qwen3.6-35B-A3B-Claude-4.7-Opus-abliterated.i1-IQ4_XS。下载记录见 `docs/models.md`「11. MoE, Qwen3.6」 |
| 平台 | PRO6000（llama.cpp）；T14p（llama.cpp CPU/Vulkan/SYCL） |
| 测试版本 | llama.cpp 首批为 bin 直跑（早于 pixi 编译版），后续 b12282 |
| 资源占用 | PRO6000：GPU 47804MiB + MemB 3.4G |

> 命令约定：`${PORT}` 由 llama-swap 加载时分配；`${env.HOME}` = `/home/shmilee`。

## 条目总览

| 条目 | 后端 | ctx | prefill | decode | MTP | 使用量（9-12 → 11-13） | 状态 |
| ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| Qwen3.6-35B-A3B | llama.cpp Q8 | 256k | 1608 t/s（summary） | ~219 t/s | 63.8% | 19 次（09-12 → 09-23） | 已取代（两版 PRO6000 config 均无此条目） |

## Qwen3.6-35B-A3B（历史，冻结）

### cmd（2026-09-12 首批部署，冻结；该条目未经历过归档流程，
命令取自首批测试记录）

```
${env.HOME}/local-llama/bin/llama-server \
  --port ${PORT} \
  --n-gpu-layers all --device CUDA0 \
  --mmproj-offload \
  --load-mode auto --flash-attn on --fit off \
  --cache-type-k f16 --cache-type-v f16 \
  --kv-unified \
  --ubatch-size 4096 \
  --model /data/huggingface-downloads/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf \
  --mmproj /data/huggingface-downloads/Qwen3.6-35B-A3B/mmproj-BF16.gguf \
  --ctx-size 262144 \
  --cache-ram 12288 \
  --spec-type draft-mtp --spec-draft-n-max 3
```

### 实测（2026-09-12，冻结）

| Summary | |
| --- | --- |
| Cached | 308 |
| Prompt | 1,702 (1607.66 t/s) |
| Generated | 6,498 (219.16 t/s) |
| Drafted | 63.8% 4269/6696 |

| ID | Time | Source/Caller | Status | Cached | Prompt | Generated | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | 2026-09-12 22:56:59 | ip:127.0.0.1 | 200 | 263 | 1,427 | 1,841 | 3876.40 t/s | 212.25 t/s | 9.37s |
| 3 | 2026-09-12 22:54:22 | ip:127.0.0.1 | 200 | 38 | 229 | 3,099 | 923.58 t/s | 222.75 t/s | 14.37s |
| 2 | 2026-09-12 22:53:34 | ip:127.0.0.1 | 200 | 7 | 35 | 767 | 148.18 t/s | 213.99 t/s | 3.93s |
| 1 | 2026-09-12 22:53:21 | ip:127.0.0.1 | 200 | - | 11 | 791 | 53.29 t/s | 227.38 t/s | 3.69s |

### 优缺点

* MoE 35B/3B 激活，decode ~219 t/s（PRO6000 llama.cpp）速度快、负载轻
  （47.8G + MemB 3.4G）。
* 被 27B dense 取代：代码能力与长任务表现不及 Qwen3.8-27B（候选池理由见
  `docs/models.md`「1. Dense, Qwen3.8」）。

## 决策记录

* 2026-09-12 PRO6000 首批部署时的条目之一（初始主力）。
* 2026-09 被 Qwen3.8-27B 取代（config 重命名迁移，opencode 历史统计保留
  旧 ID；PRO6000 最后使用 2026-09-23）。
* 2026-11-16 建本历史文档；T14p 仍在使用，其模型文档按本结构后续补建。

## 相关

* T14p 实测（Huihui abliterated IQ4_XS 最快）：`docs/speed-report.md`
  「T14p → IQ3 or IQ4 for CPU → Qwen3.6 35B-A3B」
* T14p 配置：`config/llama-swap-config-T14p.yaml` → `Qwen3.6-35B-A3B`
* 候选池：`docs/models.md`「11. MoE, Qwen3.6」
