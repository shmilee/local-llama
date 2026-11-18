# Strata dsv41 长上下文 prefill 性能缺陷记录

> 状态：issue 已提交 → **#5894**（2026-11-13，shmilee 账号，正文 = §9
> 草稿）。本机环境已 pin 回 v0.2.4.2（`STRATA_VERSION`，见 pixi.toml
> 注释）作为上游修复前的绕行方案。
> 日期：2026-11-12/13 · 引擎 0.1.59.1（v0.2.13，commit fb57f74）· 本机 8× RTX PRO 6000
> Blackwell (sm_120) + 2× Xeon Gold 6530 (128T) + 251GB DDR5 + 18.2T HDD

## 1. 症状（本机实测，DeepSeek-V4.1-Flash-1017 IQ2_XXS 2.00bpw，2 卡层切分 19/21）

| 上下文 | prefill | decode | 备注 |
| --- | --- | --- | --- |
| 131k（热） | **224.8 tok/s** | 160 tok/s | GPU SM 仅 54% |
| 256k（首跑，行半冷） | 116.3 tok/s | 67.3 tok/s | 低速率是**冷行缓存**，非上下文效应 |
| 512k（首跑，行半冷 / 二跑全热） | 96.2 / **216.91 tok/s** | 70.4 / 149.2 tok/s | 全热后与 131k 持平 → **warm prefill 是 ~220 tok/s 平直硬顶** |
| 1M | VRAM 无压力（KV fp4 ~1.1GB） | 未测（512k: 70-149） | fresh prefill 外推 ~40min（warm）~2.5h（cold 行），不实用 |

对照（同一对 PRO6000，issue #4042，引擎 **0.1.49.2**，Threadripper PRO 9965WX +
NVMe，2 卡 19/21，`--serve --tp 2 --cpu-threads 24`）：

| 上下文 | prefill（4042） | prefill（本机 0.1.59.1） | 差距 |
| --- | --- | --- | --- |
| 131k | **2457 tok/s** | 224.8 tok/s | **~11×** |
| 256k | 2431 tok/s | 116.3 tok/s | ~21× |
| 324k | 2405 tok/s | — | — |

decode 无差距（本机 131k@160 甚至更高）——**缺陷只影响 prefill**。

## 2. 已排除的因素（逐项 A/B，均无效）

| 变量 | 测试 | 结果 |
| --- | --- | --- |
| CPU governor | powersave(800MHz 地板) → performance | 223.5 → 138.8（performance 反而更慢：HWP 拉 2.7GHz 触发 270W 包功耗帽振荡） |
| HWP 地板 | min_perf_pct 20 → 50 | 224.8 → 224.7（**无变化**） |
| NUMA/socket | numactl cpunodebind+membind、taskset 锁 GPU 同侧 socket 64 线程 | 221.9 / 224.8（无变化） |
| Engram reader 线程 | DS4_ENGRAM_THREADS 16 → 64 | 223.5（无变化） |
| prefill chunk | --prefill-chunk 8192 → 32768 | 223.5（无变化） |
| GPU 健康 | nvidia-smi：291W/600W 预算、SM 2415MHz 满频、mclk 12.5GHz、pviol/tviol 全 0 | GPU 无 throttle，SM 利用率只有 54%（**GPU 在等主机**） |
| 专家 offload | 2 卡零 CPU lane 专家（15360/15360 在 VRAM） | 与 #5520 的"staging 串行"形态不同（见 §4） |
| 卡数 | 单卡 199.1 vs 双卡 224.8 tok/s | **双卡只快 13%**——层切分流水线没有真正并行 |

## 3. 关键定位证据

1. **prefill 是单线程的**：60s 线程级 utime 采样（512k prefill 期间），30+ 线程里
   只有 **1 个线程**在工作（+1.56s CPU / 60s），其余全部 +0.01-0.02s。
   该线程（prefill 期间诞生）挂在 **core 0（NUMA node 0）**，而 GPU 6,7 在
   **node 1**——每次 Engram 行 gather / staging / GPU 握手都跨 UPI。
2. **warm prefill 是 ~220 tok/s 平直硬顶**（131k=224.8，512k 全热=216.9）；
   首跑的"随上下文变慢"（256k=116、512k=96）是**冷 Engram 行缓存**的
   叠加，非上下文效应。4042（0.1.49.2）在本机 2220 tok/s、在其 TR 平台
   2457 tok/s——旧引擎平台稳健，新引擎在两个平台都掉到 ~220 档。
3. 源码（v0.2.13 `src/dsv41/ds4_model.cu`）：
   - L1081 `bool prompt_par`（"the prompt path's chunks, **a thread a GPU**"）
   - L2723-2727：`prompt_par = par || o.tp > 1 || ...` 之后 **0.1.59 新增**
     `if (DS4_NO_CHUNKS == nullptr) prompt_par = true;`（无条件强开 chunked 路径）
   - L3784：`if (par || chunk > 0)` 才生成 prompt 线程；L7962：Engram 预取
     helper "a chunk ahead"
   - `kChunkedPromptDefault = true` 两个版本都有（设计目标 "8K prompt 6x"）
   - 0.1.49→0.1.59 的 dsv41 源码总量 18.7k → 27.5k 行，ds4_model.cu diff
     6903 行——**prefill 路径大改过**
4. 我们的 run 没传 `--tp`/`--cpu-threads`（4042 传了 `--tp 2 --cpu-threads 24`）；
   日志显示 tp 默认 2、回退 1（"tensor parallel 2 -> 1"），4042 同样回退。

## 4. 上游 issue 关联（2026-11-13 检索）

| issue | 相关性 |
| --- | --- |
| **#5520** "Prefill regression 0.1.5x vs 0.1.42 on 2x3090 layer split - grows with context" | **同形态**（已 bisect：0.1.42 干净，0.1.44.1 引入；探针定位 "expert host staging 68ms→2.7-3.3s/chunk + chunk 边界 ~10s stall"；相关 #5414/#5462/#5480/#5440） |
| #5520 评论（q8atnight） | 全 VRAM 驻留（零 staging）下 0.1.55→0.1.58 仍有 ~5% 恒定损失 → **两个独立回归**：staging 串行化 + per-token 成本 |
| #5799（0.1.58→0.1.59） | 0.1.59 的打包/安装问题（重装修复），与 prefill 路径无关 |
| #4683 / #3976 / #3821 | prefill chunk 选择、layer-major 路径的相关 issue |

**差异点**：#5520 是 Qwen flash_next 引擎（prefill.cpp）+ 专家 host streaming
场景；我们是 **dsv41 引擎（ds4_model.cu）+ 专家全 VRAM 驻留**，却复现出更大的
差距（11× vs 他们 0.1.42→0.1.58 的 ~2×）。dsv41 的 prefill 路径是否被同一批
0.1.43-0.1.44 / 0.1.56-0.1.58 的改动波及，上游尚无报告。

## 5. 决定性 A/B —— **版本回归确认：10×**

用 **0.1.49.2（v0.2.4.2，4042 同款引擎）** 在本机源码构建（FETCHCONTENT
指向 llama.cpp@3cf03257），同机、同热缓存、同 2 卡层切分 19/21、131k 热
prefill 对比：

| 引擎 / flag（本机，131k 热 prefill） | prefill | decode | 日志形态 |
| --- | --- | --- | --- |
| **0.1.49.2** + 4042 原配方（`--tp 2 --cpu-threads 24`） | **2220.57 tok/s** | 149.1 | `windows of 131072`（整段 prompt 一条流） |
| **0.1.59.1** + 默认 flag | **224.8 tok/s** | 160.0 | `windows of 16`（8192 chunk flow 路径） |
| **0.1.59.1** + 4042 原配方（公平性复查） | **224.77 tok/s** | 164.9 | 同上（flag 变量排除） |

**结论：10× 版本回归确认，回归窗口 0.1.50-0.1.59，任何 flag 组合无法规避。**

- 0.1.49.2 在本机达到 4042（TR 平台）2457 tok/s 的 **94%** → 旧引擎跨平台
  稳健；0.1.59.1 在本机与（推断）4042 平台都是 ~220 档 → 回归是**代码**
  而非平台
- #5520 的 Qwen 引擎 staging 回归 bisect 在 0.1.43-0.1.44.1；dsv41 的
  0.1.49.2 晚于它却仍快 → dsv41 是**另一个独立回归**
- 嫌疑对象：0.1.50+ 新增的 "flow" 路径（`pick_flow_min` / "chunked pass from
  96 tokens" / L2727 `if (DS4_NO_CHUNKS==nullptr) prompt_par=true`；0.1.49.2
  中不存在该机制，整个 dsv41 目录 18.7k→27.5k 行）。行为差异：旧版
  `--tp 2` 把 131k prompt 当整段一条流（`windows of 131072`）；新版拆成
  8192-chunk flow（`windows of 16`），且 2 卡只比 1 卡快 13%（跨 chunk
  pipeline 未生效），prefill 期间仅 1 个工作线程活跃（跨 NUMA 驻留 node 0，
  GPU 在 node 1）
- 附：`DS4_NO_CHUNKS`（回退 windows-of-16 路径）与 `--prefill-chunk` 在
  0.1.59.1 上均未恢复旧速度（8192→32768 chunk 无差）

## 6. 给维护者的排查建议（issue 正文素材）

1. `prompt_par=true` 强开后（L2727），layer-split 配置下**实际活跃的 prompt
   线程数**——本机观测只有 1 个（应为 "a thread a GPU" = 2 个？）。检查 L3784
   的线程生成条件与 per-GPU flow 分配（`G.mem` groups，19/21 切分时是否两个
   group 各起一个线程，还是只有一个 flow 串行走两卡）。
2. chunk 间 pipeline：2 卡只比 1 卡快 13% → chunk N+1 在卡 A 的计算没有与
   chunk N 在卡 B 的重叠（或重叠被 host 单线程串行化）。
3. per-chunk 主机工作随 context 增长（224→116→96 tok/s）：找出 O(chunk×KV)
   的 host 循环（KV 索引/attention 元数据/Engram helper）。
4. 线程落核：工作线程长期驻留 node 0 而 GPU 在 node 1（跨 UPI）——线程生成时
   是否按 GPU 所在 NUMA 做亲和。
5. 已知 workaround 线索：#5520 的 `STRATA_PREFILL_LAYER_MAJOR=1`、
   `--resident-experts`、`DS4_NO_CHUNKS`（回退 windows-of-16 路径，长 prompt 慢
   但可作对照）。

## 7. 复现命令（本机）

```
# 环境（docs/strata.md 有完整说明）
pixi install -e strata-cuda && STRATA_BUILD_DSV41=1 pixi run -e strata-cuda strata-build
# pack（ISTA-DAS IQ2_XXS 六分片布局）
python tools/dsv41/pack_gguf.py --model <dir> --shards <5 个绝对路径> \
  --engram <绝对路径> --engram-meta <00001 分片绝对路径> \
  [--dspark-gguf <drafter>] --out <pack>
# 测试
DS4_SPLIT=19,21 strata-dsv41 --pack <pack> --ids @<prompt_ids> \
  --n 128 --max-context 131072 --dspark auto --dspark-conf 0.65 --window 16 \
  --gpus 6,7 --ssd-cache 0
```

prompt ids 生成：`tools/strata_tokenizer.py` 的 Tokenizer（确定性语料，
4042 的 records 风格）。

## 8. 数据文件

- 本机全部 A/B 日志：远端 `~/local-llama-test-202611` `/tmp/opencode/*.log`
- 线程级 utime 采样脚本：`/tmp/opencode/thread_cpu.sh`
- 0.1.49.2 构建：远端 `/tmp/opencode/Strata-0.2.4.2/build-dsv41-old/strata-dsv41`

## 9. issue 草稿（确认后提交；英文，CONTRIBUTING 格式）

> **Title**: `[Engine] dsv41 chunked-prefill (flow) path: 10x prefill regression 0.1.49.2 -> 0.1.59.1 on a 2x PRO 6000 Blackwell layer split (2220 -> 225 tok/s at 131K), unaffected by flags`
>
> **Problem**
> strata-dsv41 prompt throughput dropped ~10x between engine 0.1.49.2 and
> 0.1.59.1 (v0.2.13) on a 2x GPU layer split. Decode is unaffected (equal or
> better on 0.1.59.1). No flag combination restores 0.1.49.2 prefill speed.
>
> **Measured (same box, same warm page cache, same 19/21 layer split, 2x RTX PRO 6000 Blackwell; 131K and 512K prompts)**
>
> | engine (release) / flags | prefill tok/s | decode tok/s |
> | --- | ---: | ---: |
> | 0.1.49.2 (v0.2.4.2), `--tp 2 --cpu-threads 24`, 131K prompt | **2220.6** | 149.1 |
> | 0.1.59.1 (v0.2.13), default flags, 131K prompt | **224.8** | 160.0 |
> | 0.1.59.1 (v0.2.13), `--tp 2 --cpu-threads 24`, 131K prompt | **224.8** | 164.9 |
> | 0.1.49.2 (v0.2.4.2), `--tp 2 --cpu-threads 24`, 512K prompt | **2048.0** | 146.8 |
> | 0.1.59.1 (v0.2.13), default flags, 512K prompt (warm) | **216.9** | 149.2 |
> | 0.1.49.2 (v0.2.4.2), 1M prompt (`windows of 1048576`, one pass) | **257.0** | 70.9 |
>
> Box: 2x Xeon Gold 6530 (128 threads), 251 GB DDR5, model files on an 18.2 T
> HDD (engram rows warm in page cache for all runs; 512K warm run read
> 4,226,048 rows at 83.2% row-cache hit, identical to the 0.1.59.1 512K run).
> The 0.1.49.2 131K number is 94% of #4042's 2457 tok/s measured on a
> Threadripper box, so the old engine was platform-robust; the new engine
> sits at ~220 here at both 131K and 512K.
>
> **Approach / what I checked**
> - The 0.1.59.1 chunked "flow" prompt path (ds4_model.cu: `pick_flow_min`,
>   "chunked pass from 96 tokens", `prompt_par = true` forced at ~L2727 unless
>   `DS4_NO_CHUNKS`) did not exist in 0.1.49.2. Log shape differs: 0.1.49.2
>   runs the 131K prompt as one pass (`windows of 131072`); 0.1.59.1 runs
>   8192-token chunks (`windows of 16`).
> - 2-GPU prefill is only 13% faster than 1-GPU (224.8 vs 199.1 tok/s) - the
>   cross-chunk pipeline across the layer split does not overlap.
> - Per-thread utime sampling during a 512K prefill: one worker thread active
>   (1.56 s CPU per 60 s), all other 30+ threads idle. That thread sits on
>   core 0 (NUMA node 0) while the GPUs are on node 1.
> - Ruled out by A/B on 0.1.59.1 (all ~224-225 tok/s): CPU governor / HWP
>   min_perf_pct 20->50, numactl cpu+mem bind to the GPUs' node, taskset to
>   that node, `DS4_ENGRAM_THREADS=64` (default 16), `--prefill-chunk 32768`
>   (default 8192), `DS4_NO_CHUNKS` not faster either. GPU is healthy and
>   starved: SM ~54%, full clocks (2415 MHz), 291 W of 600 W, no power/thermal
>   violations.
> - Related upstream: #5520 (Qwen flash_next prefill regression, bisected to
>   0.1.43-0.1.44.1, expert staging; plus a flat ~5% per-token cost found in
>   0.1.55-0.1.58 with all experts VRAM-resident). This report is the dsv41
>   engine, all 15,360 experts VRAM-resident (zero CPU lane), and the 0.1.49.2
>   -> 0.1.59.1 window - a distinct regression from both #5520 findings.
>
> **Validation**
> Same-box A/B runs above (identical pack, prompt ids, 19/21 split, warm
> engram row cache in page cache; 131K/512K/1M prompts). 0.1.49.2 built
> from v0.2.4.2 with `-DSTRATA_BUILD_DSV41=ON`, sm_120, CUDA 13.2.
>
> NUMA/taskset/`--cpu-threads` A/B on 0.1.49.2 (512K, pinned to the GPUs'
> socket, 2 threads): 2048.0 -> 2049.4 tok/s - cross-NUMA placement of the
> worker thread is measurable only as noise at the fast engine's operating
> point.
>
> **Limits**
> - Single box, dual-socket Xeon; the ~220 ceiling might interact with
>   platform host latency, but the 10x delta vs 0.1.49.2 on the same box is
>   not platform-explained (0.1.49.2 reaches 94% of #4042's TR number here).
> - The 0.1.49.2 engine itself degrades super-linearly at 1M: its one-pass
>   `windows of 1048576` prefill measured 257 tok/s (68 min) vs 2048 tok/s
>   at 512K - so at 1M the two engines land within 2x of each other (257 vs
>   ~217). This is reported for completeness; the 10x regression claim
>   stands at 131K/512K where both engines are in their designed regime.
> - Prefill measured on a 131K prompt (warm engram rows); cold rows add an
>   HDD-bound component on this box (55-96 tok/s), separate from this issue.
> - I did not bisect 0.1.50-0.1.59 (each build ~10 min); happy to run
>   bisect steps or provide full logs / timing probes if pointed at the right
>   code.

## 10. 状态

- [x] 本机 A/B 确认 10× 回归（0.1.49.2 vs 0.1.59.1，flag 变量已排除）
- [x] 上游 issue 关联（#5520 等）
- [x] issue 草稿（§9）
- [x] 脱敏检查：§9 草稿仅含硬件规格（双路 Xeon 6530 / 2× PRO 6000 /
  251GB / 18.2T HDD），无主机名/用户名/IP/私有路径；仓库内部章节
  （§7/§8）的远端路径仅存在于本机文档，不随 issue 外发
- [x] **已提交 #5894**（2026-11-13，gh CLI，shmilee 凭据）
- [ ] 上游修复后：本机升级到新版复测（131k/512k prefill ≥ 2000 tok/s
  为通过线），改回 `STRATA_VERSION`
- [ ] （可选）bisect 0.1.50-0.1.59 定位具体 commit（每版 ~10 分钟构建，
  6-7 个版本 ≈ 1.5h）

### 2026-11-18 复检：Strata 0.2.15（源码构建引擎 0.1.61）

- **QFN（flash_next）长上下文 prefill 没有回归，反而更快**。同一 token
  文件、同一张卡（GPU 6）、引擎直跑 131k 上下文：
  - 0.1.49.2（v0.2.4.2）：5,068 tok/s（16 chunk × 8k，25.9s）
  - 0.1.61（v0.2.15 源码构建）：**5,960 tok/s**（4 chunk × 32k，22.0s）
  - 即 **+17.6%**；0.2.14 起"prompt 走 Strata 自有 MMQ 内核"的新路径
    在 QFN 上没有性能退化（官方打包引擎 0.1.60，源码构建为 0.1.61）。
- **dsv41（DeepSeek-V4.1）未修复**：v0.2.15 源码中已无 dsv41 引擎
  （无 `src/dsv41`、无 `STRATA_BUILD_DSV41`），官方 DeepSeek 引擎包
  仍停在 **0.1.59**（v0.2.13 的同一个二进制，即 10× 回归本体）。
  复检时上游 #5894 仍 open（无回复，最后更新 2026-11-13）；2026-11-18
  已按 `not planned` 关闭，见下一节。
- **结论：继续 pin v0.2.4.2**。QFN 侧的 +17% prefill 不值得为此做
  「主引擎 0.2.15 + dsv41 0.2.4.2」的双版本混合（终端/引擎协议未验证）；
  等上游发布带新 prompt 路径的 dsv41 引擎后一次性整体升级并复测
  （131k/512k prefill ≥ 2000 tok/s 通过线）。

### 2026-11-18 上游政策：DeepSeek 引擎被移除（#6072 / #6048）

- 0.2.14 起 Strata **移除 DeepSeek 支持**（提交 `ac306afb`）：dsv41 引擎
  原本是从 Project Maya 移植的（`third_party/project-maya`，MIT）；围绕
  多 MoE 架构支持的分歧（上游 #310）+ 移植代码的维护成本，最终停用。
  app/Control 层把 DeepSeek 模型标成 "no longer supported"，且该状态记在
  Control 的 `active.json` 里，所以只回退引擎（0.1.59）也恢复不了。
- **对本仓库无影响**：这里是源码构建的 v0.2.4.2（不经过 app/Control/feed），
  `strata-dsv41` 二进制照常工作。但也意味着 **0.1.59 的 dsv41 prefill
  回归不会由上游修复**（引擎已退役）。
- **#5894 已关闭**（2026-11-18，理由 `not planned`，附说明评论：引擎在
  0.2.14/0.2.15 被移除、无上游引擎可修，若将来恢复 DeepSeek 支持可重开）。
- 后续选项（若要兼得 QFN 新内核与 DS4.1）：
  a) 继续 pin v0.2.4.2（当前最优 DS4.1：2048 tok/s @512k）；
  b) 双版本混合：主引擎用 0.2.15（QFN +17% prefill）+ dsv41 用 0.2.4.2
     二进制（源码构建天然可行，终端/引擎协议需先验证）；
  c) 换生态：Project Maya（`mw00/project-maya`）、PolyStrata
     （`simplexai-labs/PolyStrata`）、`fragtion/strata-dsv41`。它们的内核
     基座更旧（PolyStrata 是 0.1.45 系），QFN 侧会退回旧性能，不建议。
