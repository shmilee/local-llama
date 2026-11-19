# DeepSeek-V4.1-Flash

|      |      |
| ---- | ---- |
| 状态 | 实验中（strata dsv41，2026-11-13 上线；2026-11-16 起默认 build） |
| 权重 | ISTA-DAS IQ2_XXS 2.00bpw ~131G + Engram IQ4_NL 103G + DSpark drafter Q8 7.5G。下载记录见 `docs/models.md`「3. MoE, DeepSeek-V4.1-Flash-1017」 |
| 平台 | PRO6000（8×96G），GPU 4,6（双卡层切分，`DS4_SPLIT=19,21`） |
| 测试版本 | strata v0.2.4.2 / 引擎 0.1.49.2（**pin**：新版存在 10× prefill 回归，见 `strata-prefill-regression.md`） |
| 资源占用 | 显存零压力（KV 0.27G/卡）；Engram 表需热缓存 |

> 命令约定：`${PORT}` 由 llama-swap 加载时分配；`${env.HOME}` = `/home/shmilee`。

## 条目总览

| 条目 | 后端 | ctx | prefill | decode | MTP | 使用量（9-12 → 11-13） | 状态 |
| ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| deepseek-v4.1-flash-iq2-512k | strata dsv41（DSpark drafter） | 512k | ~2048 tok/s（fresh 一次性 ~4.5min） | ~147 tok/s（Engram 热）/ 11~15（冷行） | DSpark | 0 次（11-13 上线，统计备份同日） | 实验中 |

## deepseek-v4.1-flash-iq2-512k（实验中）

### cmd（当前快照 2026-11-17；运行以 `config/llama-swap-config-PRO6000.yaml` 为准）

```
env -C ${env.HOME}/local-llama \
  pixi run -m ${env.HOME}/local-llama -e strata-cuda strata serve \
  --config config/strata-ds41.json \
  --port ${PORT}
```

运行参数（GPU 4,6、512k、`--ssd-cache 0`、`DS4_SPLIT=19,21`）在 run config
`config/strata-ds41.json`，pack 构建见 `strata.md`「DeepSeek-V4.1-Flash-1017」。

### 实测（2026-11-12，见 `strata.md`）

* 512k 为实测档：显存零压力（KV 0.27G/卡）；fresh prefill 一次性 ~4.5min
  （2048 tok/s）；decode ~147 tok/s。
* decode 依赖 Engram 热缓存（冷行仅 ~11-15 tok/s），重启后 `cat` Engram
  表热化一次。
* 卡数扩展（6 卡等）与长上下文实测见 `strata.md`「长上下文实测」；
  prefill 版本回归定位（10×）见 `strata-prefill-regression.md`
  （含复现命令与上游 issue 草稿）。

### 优缺点

* **优点**：512k 长上下文 + decode ~147 tok/s（Engram 热）；显存余量大；
  DSpark 草稿模型加速。
* **短板**：decode 依赖 Engram 热缓存（冷行 ~11-15 tok/s，重启须热化）；
  视觉暂不支持（0.1.49.2，需 v0.2.13 / 引擎 0.1.59，见 `strata.md`
  「图像（视觉）」）；与 QFN 系同占 GPU 4,6 卡；三条目同在 group2，
  切换即卸载，无需手动干预。

## 决策记录

* 2026-11-13 strata 后端条目上线（1228dc6）；引擎 pin v0.2.4.2
  （0.1.49.2，新版 prefill 10× 回归）。
* 2026-11-16 f4f9442：dsv41 改为默认 build，QFN strata 视觉启用。

## 相关

* 配置：`config/llama-swap-config-PRO6000.yaml` → `deepseek-v4.1-flash-iq2-512k`（group2）
* run config：`config/strata-ds41.json`；pack：`strata-packs/dsv41-iq2xxs`
* 后端文档：`strata.md`、`strata-prefill-regression.md`
* 同卡模型：Qwen3.8-Flash-Next（同组 group2，自动互斥切换）
