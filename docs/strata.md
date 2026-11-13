# Strata（CUDA 环境）

`strata-cuda` 环境（环境定义与构建细节见 `docs/pixi-environments.md` 的
Strata 章节）。Strata 按模型形状分引擎：

| 模型 | 引擎二进制 | 构建 |
| ---- | --------- | ---- |
| Qwen3.8-Flash-Next（`flash_next` 形状，默认） | `strata-engine` | 默认 `strata-build` |
| DeepSeek-V4.1-Flash-1017 | `strata-dsv41` | `STRATA_BUILD_DSV41=1 strata-build`（独立构建目录） |

两者都是 **token 级引擎**：命令行吃 token id（`--tokens` / `--ids`），不吃
文本 prompt；聊天模板、OpenAI 兼容 API 在 Python 终端（`strata serve` 等）
那一层。本文的"引擎直跑"是冒烟/排障路径，日常服务走终端。

```
pixi install -e strata-cuda
pixi run -e strata-cuda strata-build                 # 约 10 分钟
pixi run -e strata-cuda strata-verify
STRATA_BUILD_DSV41=1 pixi run -e strata-cuda strata-build   # 需要 DeepSeek 引擎时
```

本机模型（只读使用）：`/data/huggingface-downloads/`。跑之前用
`nvidia-smi` 确认用**空闲卡**（生产 llama-swap 会随时占卡，别硬抢）。

---

## Qwen3.8-Flash-Next（实测：GSQ-RCO IQ3_XXS 71GB，单卡 PRO6000）

### 1. 准备 pack（约 1 分钟，产物 1.5G）

IQ3_XXS 这类 i-quant 走 **native pack**：专家权重不复制，运行时直接读
GGUF（所以不加 `--experts-bin`）。

```
# gguf-py 需单独取（setup.py pin 的 llama.cpp commit 的 gguf-py/ 目录）
export STRATA_GGUF_PY=/path/to/llama.cpp-3cf03257f219afbe7334045ff7c6a06ac68c627d/gguf-py
cd download/Strata-0.2.4.2          # 目录名 = $STRATA_VERSION（当前 pin v0.2.4.2）
python tools/iq_pack.py --gguf <绝对路径 shard1> --out <pack_dir>
```

### 2. 引擎直跑（冒烟命令）

**IQ/native pack 必须三件套**：`--native <shard1> --spec 2 --prefill auto`
（引擎会明确拒绝缺的）。另外两个容易漏的：

* `--ple-gguf`：含 `per_layer_token_embd.weight` 的分片（IQ3_XXS 是
  **shard 2**；用 `tools/gguf_reader.py` 列各分片 tensor 名确认）
* `--expert-profile`：decode 需要设备驻留表，给环境自带的
  `$CONDA_PREFIX/strata/data/expert-profile.bin`，**缺了 prefill 能跑、
  decode 直接拒启**

```
strata-engine --pack <pack_dir> \
  --native  <绝对路径 shard1> \
  --ple-gguf <绝对路径 shard2> \
  --spec 2 --prefill auto \
  --expert-profile $CONDA_PREFIX/strata/data/expert-profile.bin \
  --tokens "109266,6115,139054,110827,113552,111522,1710" \
  --gpu 0 --max-new 64 --max-context 4096 --greedy
```

prompt 的 token id 用仓库自带分词器生成（纯 python，round-trip 可靠）：

```
python -c "
import sys; sys.path.insert(0, 'tools')
from strata_tokenizer import Tokenizer
tk = Tokenizer.from_gguf('<shard1>')
print(','.join(map(str, tk.encode('你好！请用一句话介绍一下你自己。'))))"
```

### 3. 资源与实测

* **主机内存 ~115GB**：PLE 表 26.8GiB（mlock 进 RAM）+ 40GiB 专家 arena
  （首用时从 SSD 流式读入）——251GB 内存的机器没压力，小机器会走
  SSD 直读（慢）
* 冷缓存启动 ~10 分钟（200MB/s 盘）；热缓存 PLE 2 秒
* 实测（GPU 0 单卡）：prefill 17.2 tok/s（TTFT 2.2s），
  **decode 134.9 tok/s**，正常 EOS，退出后显存全释放
* 输出（decode 验证）：模型正常中文自我介绍

---

## DeepSeek-V4.1-Flash-1017（实测：ISTA-DAS IQ2_XXS 2.00bpw 233GB，6 卡）

### 1. 准备 pack（几分钟，产物几 MB）

`tools/dsv41/pack_gguf.py`。**`--shards`/`--engram`/`--engram-meta` 全部用
绝对路径**——`--engram` 传相对路径会按 CWD 解析失败，症状是静默报
`5 of the 6 shards are here` 然后 exit 1（不解释原因）。

六分片布局（`of-00006`，本机这套）：shard 1 是 5.6M 纯元数据（含全部
`deepseek41.ple.*` 参数，兼作 `--engram-meta`），shard 2-5 是模型，
shard 6（symlink）是 Engram。四分片布局则 `--engram-meta` 要另下 unsloth
的 5.8M 元数据分片。

```
python tools/dsv41/pack_gguf.py \
  --model <模型目录> \
  --shards <绝对路径 00001> <00002> <00003> <00004> <00005> \
  --engram <绝对路径 DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf> \
  --engram-meta <绝对路径 00001> \
  --out <pack_dir>
```

### 2. 跑（官方冒烟脚本）

```
python tools/dsv41/smoke.py --exe <build-dir>/strata-dsv41 \
  --pack <pack_dir> --gpus 0,1,3,4,5,7
```

它内置固定问题（法国首都）、16 token、输出有效性检查（必须是词且含
"Paris"）。引擎直跑等价命令（2 卡同 NUMA 域最优配置；pack 含 drafter
时 `--dspark auto` 自动启用草稿）：

```
DS4_SPLIT=19,21 strata-dsv41 --pack <pack_dir> --ids @<ids文件> --n 300 \
  --max-context 1024 --dspark auto --dspark-conf 0.65 --window 16 \
  --gpus 0,1 --ssd-cache 0
```

本机没有 DSpark drafter 文件（`dspark-*-Q8_0.gguf`）：`--dspark auto`
会自动不启用（n_mtp=0），可跑但 decode 会慢一些；要 drafter 就从 unsloth
的 repo 下 8GB 那个文件重 pack。

### 3. 卡数与速率实测（本机 8× PRO6000，2026-11-12，IQ2_XXS 2.00bpw）

| 配置 | 专家 offload | prefill | decode | 备注 |
| ---- | ---------- | ------- | ------ | ---- |
| 1 卡（GPU 0） | 4614 个进 RAM + 39GB 文件直读 | 12.8 tok/s | **10.5 tok/s** | Engram 随机读 HDD，~75ms/token 暴露等待 |
| **2 卡（0,1 同 NUMA 域）** | **0**（7296/8064 全 VRAM） | **176 tok/s** | **81.4 → 85.0 tok/s**（`--ssd-cache 0`） | 推荐配置 |
| 6 卡（0,1,3,4,5,7 跨域） | 0 | 13.2 tok/s | 11.8 tok/s | 跨 NUMA 域 + 层分偏斜（GPU7 独揽 27 层），几乎不比 1 卡快 |

* 输出均为 "The capital of France is Paris." + EOS（8 token 一句答完），
  正常退出、显存全释放。decode 每 token 构成（2 卡，Engram 行热）：
  layers 4.3ms + head wait 7.2ms + Engram 0.06ms。
* **Engram 行读走 page cache 是快慢的分水岭**：某 prompt 的行首跑冷
  （落 HDD，~4ms/行随机读，~140ms/token 读、暴露 ~75ms）→ 读过后
  驻留 cache（0.08ms/token）。注意"热"是按行/按会话累积的，不是整表：
  加载路径不读 Engram 数据。4042 的 116 tok/s 靠 NVMe（行冷读仅
  ~1ms/token），盘型是根本差距。
* 加载时间：默认 ~17 分钟，其中 RAM store 预读 99.8GB 是 **O_DIRECT
  绕过 page cache** 按盘速走（473-479s）且本配置 0 hits；
  **`--ssd-cache 0` 后 ~10 分钟**（纯专家→显存拷贝 + 热化）。
* 拓扑注意（`nvidia-smi topo -m`）：0-3 一个 NUMA 域、4-7 另一个，
  跨域是 PCIe+UPI（SYS）。多卡选同域相邻卡；**≤2 卡**即可零 offload
  （2×96G ≥ 132G 专家 + dense），加卡不增加吞吐只增加加载时间和
  跨域风险。
* 内存账本（2 卡）：专家 132.5GB 全在**显存**，内存主要被 Engram
  page cache（最多 110GB）+ 引擎/生产负载占。引擎默认还会自动开
  **RAM store**（"空闲内存−12GB"，O_DIRECT 预读最热专家副本
  ~100GB）——专家全在显存的配置里它 0 hits，纯浪费内存和 ~8 分钟
  加载。**`--ssd-cache 0` 关掉**：加载 17min→10min，decode 81.4→
  85.0 tok/s，且腾出的内存让 Engram cache 更稳。
* 层分配用 `DS4_SPLIT=19,21`（环境变量；`--layer-split` 参数被引擎忽略，
  issue 4042 同款配置）；auto 分出的 13/27 偏斜对本次 8 token 测速无
  影响（81.42 vs 81.44），长输出/大窗口下建议显式 19,21。
* **Engram 冷热机制**（HDD 盘，随机行读 ~4ms/行）：首跑某 prompt 的
  decode 行全冷（~140ms/token 读，暴露 ~75ms → 整体 ~11 tok/s），
  行读过后驻留 page cache，同会话/同 prompt 后续 0.08ms（→85 tok/s）。
  整表热化：`cat <Engram.gguf> > /dev/null`（110GB，~8min，须配
  `--ssd-cache 0`，否则 store 挤掉 Engram 页）。4042 的 116 tok/s
  靠 NVMe（随机行读 ~30µs，冷读仅 1ms/token）——盘型是冷会话的
  根本差距，本机要彻底解决需模型文件上 NVMe。

### 长上下文实测（2 卡 0,1 / 19,21 / `--ssd-cache 0` / DSpark）

| 上下文 | prefill（热 Engram） | decode | 备注 |
| --- | --- | --- | --- |
| 131k | 224.8 tok/s（9.7min） | **131.0→160 tok/s**（governor 提频后） | decode 超 4042 的 106.7@131k |
| 256k | 116.3 tok/s（37.5min） | **67.3 tok/s** | 注意力成本开始显现（layers 2.3→8.3ms/token） |
| 512k | 96.2（半热）/ **216.9 tok/s**（全热） | **149.2 tok/s** | warm prefill 是 ~220 平直硬顶；"随上下文退化"是冷行缓存假象 |
| 1M | 0.1.59.1 外推 ~220（80min）；**0.1.49.2 实测 257.0 tok/s（68min）** | **70.9 tok/s** | 1M KV 仅 0.54GB/卡（显存/内存零压力）；旧引擎整窗 `windows of 1048576` 在 1M 超线性退化（512k 2048 → 1M 257） |

* **prefill 天花板 ~225 tok/s 是主机侧硬顶**（GPU 仅 54%，SM 满频
  2415MHz、291W/600W、无 throttle——GPU 在等主机），且对以下全部
  **不敏感**（2026-11-12 逐项 A/B，131k 热）：
  - `DS4_ENGRAM_THREADS=64`（默认 16）→ 223.5
  - `--prefill-chunk 32768`（默认 8192）→ 223.5
  - numactl 绑 GPU 同 socket → 221.9 / taskset 锁 socket1 64 线程 → 224.8
  - governor powersave→performance → 138.8（**更慢**：HWP 拉 2.7GHz
    触发 270W 包功耗帽振荡）
  - `min_perf_pct=50`（地板 2GHz）→ 224.7（**与基线 223.5 无差**）
  - 单卡（vs 双卡 224.8）→ 199.1：层切分流水线没有真正并行
  **单线程定位（60s 线程级 utime 采样，2026-11-13）**：prefill 期间
  30+ 线程里只有 1 个工作线程在动（1.56s CPU / 60s），其余全闲；
  该线程挂在 **core 0（node 0）**，与 GPU（node 1）**跨 NUMA**
  ——每次 Engram 行 gather / staging / GPU 握手都走远端。
  **版本回归确认（2026-11-13，同机 A/B，131k/512k 热）**：0.1.49.2
  （v0.2.4.2，4042 同款引擎）= **2220 / 2048 tok/s**，0.1.59.1 =
  **224.8 / 216.9 tok/s**——**10× 回归，窗口 0.1.50-0.1.59，flag 无法
  规避**（详见 `docs/strata-prefill-regression.md`；上游关联 #5520）。
  行为差异：旧引擎整段 prompt 一条流（`windows of 131072/524288`），
  新引擎 8192-chunk flow（`windows of 16`），且 2 卡只比 1 卡快 13%
  （跨 chunk pipeline 未重叠）。GPU 侧全程健康（满频、291W/600W、
  无 throttle、SM 54% 等喂数据）。
* **频率机制本身正常**：HWP 在持续饱和负载（模型加载、64 线程满载）
  拉 2.7GHz；prefill 的乒乓负载（算 1-2ms→等 GPU）单核占空比不足，
  HWP 不触发拉频，核停在 min_perf 地板（powersave=20%=800MHz）。
  **推荐设置：`cpupower frequency-set -g performance` +
  `min_perf_pct=50`**（prefill 无损，decode +25%：131→160 tok/s；
  纯 performance 不设地板会让 prefill 掉到 138）。
* **NUMA/线程卫生**（0.1.49.2 上 A/B 零性能差：2048.0 → 2049.4
  tok/s）：跨 NUMA 惩罚在误差内；标准配方用
  `taskset -c <GPU 同 socket 物理核>`（GPU 0-3 → `0-31`；GPU 4-7 →
  `32-63`）+ `--cpu-threads 2`（CPU lane 专家为 0 时 24 个线程全闲）——
  收益是放置确定、不干扰其他负载。
* **实用结论（定案）：长上下文用 512k 档**（`--max-context 524288`）：
  prefill 一次性 ~40min（0.1.59.1 全热 216.9 tok/s；待上游修回归后
  ~4.5min，0.1.49.2 实测 2048 tok/s），decode 149 tok/s，KV 仅
  0.27GB/卡、内存无增长。1M = 一次性长任务档（prefill 68-80min，
  decode 70.9，不推荐日常）；交互/agent 档 128-256k（prefill
  10-40min，decode 67-160 tok/s）。真实 agent 场景前缀命中会话
  缓存，不重复付 prefill（4042 的 agent turn：14.8k prompt 仅读
  2605，TTFT 2.2s）。
* **DSpark drafter 实测**（`dspark-DeepSeek-V4.1-Flash-1017-Q8_0.gguf`
  7.5G，重 pack 时加 `--dspark-gguf <文件> --dspark-noise-token 128799
  --dspark-markov-rank 256`，跑加 `--dspark auto --dspark-conf 0.65`）：
  草稿机制正常（300 token 任务 141 offered / 123 accepted，位置命中
  85-92%），且热缓存下是正收益：

  | 2 卡 + DSpark（同 prompt 两轮） | prefill | decode |
  | --- | --- | --- |
  | Engram 冷（新会话） | 13.7 tok/s | 11.0 tok/s |
  | **Engram 热（后续）** | **237 tok/s** | **107.9 tok/s** |

  对比 4042（同 2× PRO6000，NVMe、热、IQ2_XS、短聊天低熵任务）chat
  中位 116.4 tok/s —— **本机达到 93%**，且任务更难（高熵技术内容+
  代码，接受率 1.7 token/轮 vs 短聊天的高接受率）。每 token GPU 成本
  两边持平（~8ms），差距在任务熵与盘型。无草稿热缓存 85 tok/s，
  DSpark +27%。冷会话的 11 tok/s 全是 HDD 行读（133ms/batch），与
  草稿无关——`cat` 热化 Engram 后新 prompt 首轮即 100+ 档。

---

## 注意点汇总

1. **先选空闲卡**。生产 llama-swap 在 2/6 号卡之间换模型，跑之前
   `nvidia-smi` 看一遍；被抢占只会拖慢不会破坏。
2. **路径全用绝对路径**（`--native`/`--ple-gguf`/`--shards`/`--engram`/
   `--engram-meta`/`--expert-profile`）。相对路径的两处静默失败：
   dsv41 pack 的 "5 of 6 shards"、引擎从自身目录 dlopen `libstrata_kq.so`
   （所以引擎和库必须同目录，环境里已装好）。
3. **引擎吃 token id 不吃文本**。生成 ids：qwen 用 `strata_tokenizer.py`
   的 `Tokenizer`（dsv41 用 pack 里导出的 `tokenizer/` 目录）。
4. **启动慢是正常现象**，且日志在阶段结束才刷：qwen 冷启动 ~10 分钟
   （PLE mlock + 专家 arena 流式读），dsv41 冷加载 ~15 分钟。看进度用
   `ps` 的 RSS/`/proc/<pid>/io`，别以为卡死。
5. **内存门槛**：qwen native 路径要 ~115GB 主机内存（机器 251GB 才舒服）；
   dsv41 按 VRAM 分层、内存压力小。
6. **版本绑定**：环境 pin Strata **v0.2.4.2**（引擎 0.1.49.x，4042 同款）、
   gguf-py pin llama.cpp `3cf03257`。**刻意不跟最新版**：v0.2.13（引擎
   0.1.59）的 dsv41 长上下文 prefill 有 10× 回归（#5894，见
   `docs/strata-prefill-regression.md`），上游修复并复测
   （131k/512k prefill ≥ 2000 tok/s）前不升级。注意 v0.2.4.2 与 v0.2.13
   的构建/参数差异：ggml 走 FetchContent（`strata-src.sh` 已自动预下载
   llama.cpp）、CMake 需显式架构号（`native` 会触发 w4a4 ptxas 失败）、
   dsv41 无 `--window` flag、pillow pin 12.3.0。
7. **日常服务走 Python 终端**（`strata serve` / run config 指向
   `$CONDA_PREFIX/bin/strata-engine` 或 `strata-dsv41`），`strata launch`
   的组件流会从 feed 下预编译引擎——本机 GitHub 不可达，用不了那条路，
   以本地源码构建为准。
8. **清理**：pack 目录（qwen 1.5G / dsv41 几 MB）用完可删，重生成很
   快；模型文件永远只读。
