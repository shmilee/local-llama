# 模型文档（docs/models/）

按**模型家族**组织：状态、实测快照、优缺点、决策记录（为何主力、为何归档）。
当前范围：**PRO6000**。T14p 的模型后续按同样结构补充（平台是文档内字段，不是文件维度）。

## 分工（三层，不重复）

| 层 | 文件 | 回答什么 |
| ---- | ---- | ---- |
| 模型资产文档 | `docs/models/<模型>.md` | 这个模型现在什么状态、多快、为何这样决策 |
| 后端技术文档 | `docs/vllm.md` / `sglang.md` / `strata.md` / `llama.cpp.md` / `pixi-environments.md` | 参数为何这么选、版本 pin 理由、已知坑（模型文档只链接、不复制） |
| 候选池文档 | `docs/models.md` | 挑选参考、量化说明、下载记录、chat templates |

规则：

* **模型内容集中存放**：模型文档内嵌每个条目的完整命令（宏已展开、快照注明日期）
  + 实测 + 优缺点，是该模型一切查阅的落点；`speed-report.md` 只放实测数据
  （Memory + report 表），不放 cmd。
* **cmd 是快照，不是运行源的副本**：活动条目运行参数以 config 为准
  （参数调改不要求同步文档，下次生命周期事件刷新快照）；归档条目的 cmd
  以文档为准，是唯查阅处。
* **版本不重复**：模型文档只记「以哪个版本测的」+ 链接到对应后端文档 / `pixi-environments.md`。
* **实测数据分流**：活跃期间留在 `speed-report.md`（日常 append）；条目**归档时把该模型
  整段（Memory + report 表）搬进模型文档并冻结**。
* **config 归档文件（config/archive/）仅作机械备份**（原样恢复配置用），
  不是文档的内容来源，不在文档中引用。

## 命名与索引

一个模型家族一个文件：`docs/models/<家族名>.md`。config 条目是文档里的表格行，不是文件。

| 模型 | 现状（2026-11-26） | 涉及条目 | 文档 |
| ---- | ---- | ---- | ---- |
| Qwen3.8-27B | 主力 `qwen3.8-27b-fp8-1m`；备用 `qwen3.8-27b-q8-256k`；3 条目已归档 | `qwen3.8-27b-q8-256k`, `qwen3.8-27b-fp8-1m`（+ 归档 3） | [Qwen3.8-27B.md](Qwen3.8-27B.md) |
| Qwen3.8-Flash-Next | 主力（规划）`qwen3.8-flash-next-fp4-1m`；实验中 `qwen3.8-flash-next-iq3-1m`；4 条目已归档 | `qwen3.8-flash-next-fp4-1m`, `qwen3.8-flash-next-iq3-1m`（+ 归档 4） | [Qwen3.8-Flash-Next.md](Qwen3.8-Flash-Next.md) |
| DeepSeek-V4.1-Flash | 实验中（strata，group2） | `deepseek-v4.1-flash-iq2-512k` | [DeepSeek-V4.1-Flash.md](DeepSeek-V4.1-Flash.md) |
| Qwen3.6-35B-A3B | 已被 27B 取代（PRO6000 历史；T14p 仍在用） | Qwen3.6-35B-A3B | [Qwen3.6-35B-A3B.md](Qwen3.6-35B-A3B.md) |
| Inkling-2-Mini | 在役（vLLM nightly 独立环境，2026-11-27）；llama.cpp b12776 后备（无 FA，prefill O(n²)） | `inkling-2-mini-fp4-262k` | [Inkling-2-Mini.md](Inkling-2-Mini.md) |

条目 ID 命名规则：`<家族>-<量化>-<上下文>`，全小写；量化映射 `q8`=Q8_K_XL、
`fp8`=FP8、`fp4`=NVFP4、`iq2`=IQ2_XXS、`iq3`=IQ3_XXS；上下文 `256k`/`512k`/`1m`；
后端由量化隐含（写在 description）。旧 ID 保留为 aliases
（`includeAliasesInList: false`，不进客户端列表）。

> 本索引是 PRO6000 模型清单的单一来源；`llama-swap.md`「模型清单（PRO6000）」一节迁移时改为指向这里。

## 文档模板

```markdown
# Qwen3.8-27B

|      |      |
| ---- | ---- |
| 状态 | 主力（2026-10-14 起）；… |
| 权重 | UD-Q8_K_XL / FP8 / …（下载记录见 models.md） |
| 平台 | PRO6000（8×96G），GPU 2 |
| 测试版本 | vLLM 0.33.0、llama.cpp b12282（pin 理由见对应后端文档） |
| 资源占用 | …（显存 / RAM / PLE 等） |

> 命令约定：`${PORT}` 由 llama-swap 加载时分配；`${env.HOME}` = /home/shmilee；
> 宏已展开。

## 条目总览

| 条目 | 后端 | ctx | prefill | decode | MTP 接受率 | 使用量 | 状态 |

## <条目>（状态标签）

### cmd（快照日期；活动条目注「运行以 config 为准」，归档条目注「归档时点最终配置」）

### 实测（日期；活动条目引 speed-report.md，归档条目内嵌表并冻结）

### 优缺点

（每个条目一节）

## 决策记录

* YYYY-MM-DD 事件：理由 + 数据依据（请求数 / 速率 / 资源）
* 生命周期每次变更都记：初上线、主力变更、降为备用、归档

## 相关

* 配置：文件名 + 条目 ID（活动条目）
* 后端文档章节：…
* issue / 其他文档：…
```

## 更新纪律

* 模型文档**只在生命周期事件**时更新：初上线、主力变更、条目归档、后端大版本升级。
* 日常实测数据照旧 append `speed-report.md`，归档时做一次搬移。
* 已归档模型的文档即冻结，不再维护。

## 归档迁移流程（每条目一套）

1. 配置条目块**连同全部注释**移入 `config/archive/llama-swap-config-PRO6000-YYYYMMDD.yaml`（机械备份，含宏、可原样恢复；文件头注明归档日期与各条目请求数）。
2. `speed-report.md` 该模型段落（Memory + report 表）搬入模型文档对应条目节并冻结；
   该条目 cmd（宏展开）写入模型文档。
3. 模型文档补决策记录（理由 + 数据依据）。
4. 更新本文件索引的状态列。
5. 清理活动 config：失去最后引用的宏删除（如 `default-sglang`）、group 成员收缩。
6. 全部完成后 `llama-swap.md`「模型清单」一节改为指向本索引。

## 执行记录（2026-11-16 讨论定稿，同日执行，未 commit）

* **保留（5）**：`Qwen3.8-27B-vllm-1M`、`Qwen3.8-27B`、`Qwen3.8-Flash-Next-vllm-1M`、`DeepSeek-V4.1-Flash`、`Qwen3.8-Flash-Next-Strata`
* **归档（7）**：`Qwen3.8-Flash-Next`、`Qwen3.8-Flash-Next-1M`、`Qwen3.8-Flash-Next-vllm`、`Qwen3.8-Flash-Next-sglang`、`Qwen3.8-27B-1M`、`Qwen3.8-27B-vllm`、`Qwen3.8-27B-sglang` → `config/archive/llama-swap-config-PRO6000-20261116.yaml`
* 使用量依据：`activity-PRO6000.sqlite`（2026-11-13 备份），2026-09-12 → 11-13
* 已做：4 份模型文档建立；speed-report.md 归档段搬移冻结；`default-sglang` 宏删除；
  group1/group2 收缩；matrix `q38fn` 与 scheduler 优先级指向存留条目；
  llama-swap.md / llama.cpp.md / sglang.md 交叉引用更新
* 2026-11-17 按「模型内容集中存放」修订：各条目 cmd（宏展开）内嵌模型文档，
  speed-report.md 改为纯数据台账；文档不再引用 config/archive/（仅作机械备份）
* 2026-11-19 模型 ID 统一为 `<家族>-<量化>-<上下文>`；旧 ID 保留为 aliases，
  `includeAliasesInList` 置 false；三个 4,6 卡系条目并入 group2
* 已定：2026-11-18 GPU 4,6 同卡冲突以并入 group2 解决（FP4 vLLM 1M + 两个 strata 条目互斥切换）
* T14p 模型后续按本结构补建
