# DeepSeek-V4.1-Flash

> **2026-11-24：Strata 上游 0.2.14 起移除了 DeepSeek（dsv41）引擎**
> （#6072/#6048），`strata-ds41.json` 与 llama-swap 的 strata 条目已删除。
> DeepSeek-V4.1 改用 **Project Maya**（`maya-ds4`，见 `docs/maya.md`）；
> 本文以下内容是 strata 时代的历史记录（模型文件保留在
> `/data/huggingface-downloads/DeepSeek-V4.1-Flash/`）。

|      |      |
| ---- | ---- |
| 状态 | 历史条目（strata dsv41，2026-11-13 上线，2026-11-24 随上游移除）；现用 Project Maya |
| 权重 | ISTA-DAS IQ2_XXS 2.00bpw ~131G + Engram IQ4_NL 103G + DSpark drafter Q8 7.5G。下载记录见 `docs/models.md`「3. MoE, DeepSeek-V4.1-Flash-1017」（Maya 需要它支持的量化，见 `docs/maya.md`） |
| 平台 | PRO6000（8×96G），GPU 4,6（双卡层切分，`DS4_SPLIT=19,21`） |
| 测试版本 | strata v0.2.4.2 / 引擎 0.1.49.2（历史；该引擎已移除，上游 issue #5894 已按 not planned 关闭） |
| 资源占用 | 显存零压力（KV 0.27G/卡）；Engram 表需热缓存 |

> 命令约定：`${PORT}` 由 llama-swap 加载时分配；`${env.HOME}` = `/home/shmilee`。

## 条目总览

| 条目 | 后端 | ctx | prefill | decode | MTP | 使用量（9-12 → 11-13） | 状态 |
| ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| deepseek-v4.1-flash-iq2-512k（**已移除**） | strata dsv41（DSpark drafter） | 512k | ~2048 tok/s（fresh 一次性 ~4.5min） | ~147 tok/s（Engram 热）/ 11~15（冷行） | DSpark | 0 次（11-13 上线，统计备份同日） | 实验中 |

## deepseek-v4.1-flash-iq2-512k（历史条目，已移除）

### cmd（历史快照 2026-11-17；`config/strata-ds41.json` 已于 2026-11-24 删除）

```
env -C ${env.HOME}/local-llama \
  pixi run -m ${env.HOME}/local-llama -e strata-cuda strata serve \
  --config config/strata-ds41.json \  # 已删除，仅作历史记录
  --port ${PORT}
```

运行参数（GPU 4,6、512k、`--ssd-cache 0`、`DS4_SPLIT=19,21`）在 run config
`config/strata-ds41.json`，pack 构建见 `strata.md`「DeepSeek-V4.1-Flash-1017」。

### 实测（2026-11-12，见 `strata.md`）

* 512k 为实测档：显存零压力（KV 0.27G/卡）；fresh prefill 一次性 ~4.5min
  （2048 tok/s）；decode ~147 tok/s。
* decode 依赖 Engram 热缓存（冷行仅 ~11-15 tok/s），重启后 `cat` Engram
  表热化一次。
* 卡数扩展（6 卡等）与长上下文实测见 `strata.md` 的历史版本；
  prefill 版本回归定位（10×）对应上游 issue #5894（已按 not planned 关闭，
  引擎随 0.2.14 移除）。

### 优缺点

* **优点**：512k 长上下文 + decode ~147 tok/s（Engram 热）；显存余量大；
  DSpark 草稿模型加速。
* **短板（历史）**：decode 依赖 Engram 热缓存（冷行 ~11-15 tok/s，重启须热化）；
  dsv41 的视觉在 0.1.49.2 不支持（需 0.1.59）；与 QFN 系同占 GPU 4,6 卡。

## 决策记录

* 2026-11-13 strata 后端条目上线（1228dc6）；引擎 pin v0.2.4.2
  （0.1.49.2，新版 prefill 10× 回归）。
* 2026-11-16 f4f9442：dsv41 改为默认 build，QFN strata 视觉启用。
* 2026-11-24：Strata 升到 v0.2.20（0.1.66），删除 strata 的 dsv41 引擎/
  run config/llama-swap 条目；DeepSeek-V4.1 转 Project Maya（docs/maya.md）。

## 相关

* 配置（历史）：`config/llama-swap-config-PRO6000.yaml` → `deepseek-v4.1-flash-iq2-512k`（已删除）
* 现状：`docs/maya.md`（Project Maya 环境与 DeepSeek 条目）
* run config：`config/strata-ds41.json`；pack：`strata-packs/dsv41-iq2xxs`
* 后端文档：`strata.md`、`strata-prefill-regression.md`
* 同卡模型：Qwen3.8-Flash-Next（同组 group2，自动互斥切换）
