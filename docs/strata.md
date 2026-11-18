# Strata（CUDA 环境）

`strata-cuda` 环境（环境定义与构建细节见 `docs/pixi-environments.md` 的
Strata 章节）。Strata 按模型形状分引擎：

| 模型 | 引擎二进制 | 构建 |
| ---- | --------- | ---- |
| Qwen3.8-Flash-Next（`flash_next` 形状，默认） | `strata-engine` | 默认 `strata-build` |
| DeepSeek-V4.1-Flash-1017 | `strata-dsv41` | 默认 `strata-build`（独立构建目录） |
| QFN 图片编码器（多模态） | `strata-vision` | 默认 `strata-build`（tools/vision） |

两者都是 **token 级引擎**：命令行吃 token id（`--tokens` / `--ids`），不吃
文本 prompt；聊天模板、OpenAI 兼容 API 在 Python 终端（`strata serve` 等）
那一层。本文的"引擎直跑"是冒烟/排障路径，日常服务走终端。

```
pixi install -e strata-cuda
pixi run -e strata-cuda strata-build   # 默认构建 engine + dsv41 + vision
                                       # （首次约 30 分钟，增量重跑很快）
pixi run -e strata-cuda strata-verify  # 校验三个二进制 + GPU
```

本机模型（只读使用）：`/data/huggingface-downloads/`。跑之前用
`nvidia-smi` 确认用**空闲卡**（生产 llama-swap 会随时占卡，别硬抢）。

---

## Qwen3.8-Flash-Next（实测：GSQ-RCO IQ3_XXS 71GB，单卡 PRO6000）

### 1. 准备 pack（约 1 分钟，产物 1.5G）

一键脚本（自动找 Strata 源码 / pinned gguf-py / 模型文件，校验产物完整性，
幂等）：

```
pixi run -e strata-cuda strata-pack        # qwen + ds41 都备
pixi run -e strata-cuda strata-pack qwen   # 只备 qwen
```

手工（等价，排障参考）：IQ3_XXS 这类 i-quant 走 **native pack**：专家权重
不复制，运行时直接读 GGUF（所以不加 `--experts-bin`）。

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

一键脚本：`pixi run -e strata-cuda strata-pack ds41`（自动定位模型目录，
of-00006 布局的 5 分片 + Engram + 可选 dspark 都按绝对路径传入；模型目录里
有 `dspark-*.gguf` 时自动带 `--dspark-gguf --dspark-noise-token 128799
--dspark-markov-rank 256`）。

手工（等价，排障参考）：`tools/dsv41/pack_gguf.py`。**`--shards`/`--engram`/
`--engram-meta` 全部用绝对路径**——`--engram` 传相对路径会按 CWD 解析失败，
症状是静默报 `5 of the 6 shards are here` 然后 exit 1（不解释原因）。

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

## llama-swap 集成（PRO6000 配置）

两个模型已加入 `config/llama-swap-config-PRO6000.yaml`（`strata serve`
终端 server 提供 OpenAI 兼容 API，run config JSON 在 `config/`）：

| 模型键 | 引擎 | 卡 | 上下文 | run config |
| --- | --- | --- | --- | --- |
| `DeepSeek-V4.1-Flash` | strata-dsv41（IQ2_XXS 233G + Engram + DSpark） | 4,6 | 524288 | `config/strata-ds41.json` |
| `Qwen3.8-Flash-Next-Strata` | strata-engine（IQ3_XXS 71G） | 3 | **1048576** | `config/strata-qwen.json` |

* 终端 server 任意 model name / API key 可用；llama-swap 按需拉起
  （`healthCheckTimeout` 给足：dsv41 冷加载 ~15min）。
* **run config JSON 无变量替换**（纯 `json.loads`），但所有路径可写相对：
  终端 server 以自身 cwd 解析 `--config`、`exe`、`tokenizer`、`log`，引擎
  进程以 config 的 `cwd`（此处 `"."`）解析 `--pack`/`--expert-profile` 等
  args。宏里 `env -C ${env.HOME}/local-llama` 把工作目录钉在仓库根
  （llama-swap 直接 exec 不走 shell，`cd X &&` 不能用），JSON 里因此
  没有任何机器相关绝对路径。
* **Qwen 必须 `--ple-io ram`**：PLE 表在 HDD 上，direct 随机读只有
  ~3MB/s（引擎自己的警告），ram = 26.8GiB mlock。
* Qwen 1M 实测（GPU 3 单卡）：prefill 4349 tok/s（~4min）、
  decode 161.5 tok/s @1M、显存 72.5G/96G（512k 时 212 tok/s）。
  DFlash2 投机解码在 server 下自动生效。
* DS4.1 512k 实测（GPU 4,6）：prefill 2048 tok/s（~4.5min）、
  decode 147 tok/s；1M 整窗超线性退化（257 tok/s）故定 512k。
* **DS4.1 prefill 随 prompt 长度的实测曲线**（生产实例，引擎 0.1.49.2
  build 5794599e1，Engram 热，2026-11-14）：41 tok **199 t/s**（~0.2s）、
  470 tok **744 t/s**、2,230 tok **1,170 t/s**、20,030 tok **1,794 t/s**、
  132,030 tok **2,169 t/s**。llama-swap 表格里短 prompt 的 "Prefill" 只有
  几百是每请求固定开销（~0.2s + 分块爬坡），不是退化；文档的 2048/2220
  是 131k/512k 长 prompt 的数字。**Engram 冷时短 prompt 再减半**
  （396 tok 373.9 t/s → 热后 ~740 t/s），所以热化是前提。
* **DS4.1 的 decode 速度取决于 Engram 热缓存**（最常踩的坑）：专家全在
  显存（2 卡 15744/15744），但每个 token 会随机读 Engram 表（110GB，在
  /data HDD 上）。冷行 ~140ms/token → decode 只有 **~11-15 tok/s**；整表
  进 page cache 后才有 ~147 tok/s。机器重启/大内存压力后热化一次
  （~8min，250MB/s）：
  `cat ${models_dir}/DeepSeek-V4.1-Flash/DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf > /dev/null`
  llama-swap 换模或 ttl 卸载模型**不会**丢 page cache，只有重启机器才会。
  run config 已配 `--ssd-cache 0`（引擎默认的 RAM store 白占内存、会挤掉
  Engram 页；专家全进显存时它 0 hits）和 `"env": {"DS4_SPLIT": "19,21"}`
  （均衡层分；auto 的 13/27 偏斜在 512k 长窗/长输出下更差，且引擎忽略
  `--layer-split` 参数，只认 DS4_SPLIT 环境变量）。
* llama-swap 子进程 PATH 无 pixi 时 cmd 要用 `~/.pixi/bin/pixi`
  绝对路径（生产 start 脚本环境有则可用裸 `pixi`）。
* 测试记录：独立 llama-swap 实例（:18435，独立 sqlite）验证两模型
  chat 全链路通过（2026-11-13）。

## QFN 补充实测（2026-11-14）

prefill 随 prompt 长度（生产实例，单卡 96G，`--ple-io ram`，全部专家驻留
显存）：

| prompt tokens | prefill | 说明 |
| --- | --- | --- |
| 60 | 229 tok/s | 固定开销 ~0.4s/请求主导 |
| 16,521 | 4,412 tok/s | 首个冷请求 3,085 |
| 131,811 | 5,540 tok/s | 其中 16,384 命中前缀 |

* llama-swap 统计里 143–768 tok/s 的 prefill 都是 63–793 token 的短 prompt
  （拟合 ≈ 0.4s + 0.8ms/token，渐近 ~1250 tok/s），不是退化；长 prompt
  5k 级与早前 1M 实测 4349 tok/s 一致。
* **内存构成**（引擎 RSS ~74GB）：PLE 表 26.8GB（`--ple-io ram` mlock，
  必需——HDD 上 direct 只有 3MB/s）+ 专家 arena 40GB（24576 专家已全部
  驻留显存，arena 只是填充/借用的主机侧副本，默认 **pinned**）+ 页缓存。
* `--ssd-cache` 是 dsv41 引擎专有参数，QFN（strata-engine）没有、也不需要。
* 想省掉那 40GB pinned 副本：`--mmap-experts`（改 mmap 模型文件，页变
  可回收的 page cache；`ps` 的 RSS 数字不变 ~73GB，但只有 28GB 是 locked，
  其余是 RssFile，可回收）。代价：16k prefill 4,412 → 3,523/3,717 tok/s
  （-15%），decode 不变（145.8 vs 146.2）。再加 `--resident-cpu-experts`
  多 ~3.5GB 常驻，prefill 无改善。**默认（快）推荐**；内存紧张时用
  `--mmap-experts`。

## DS4.1 引擎选择（2026-11-18：Strata 冻结版 / Maya / PolyStrata）

上游 0.2.14 移除 DeepSeek 后，能跑 DeepSeek-V4.1-Flash-1017 的引擎只剩三类，
**模型文件格式互不通用**：

| 方案 | 引擎 | 接受的模型文件 | 本机状态 |
| --- | --- | --- | --- |
| **Strata v0.2.4.2（现用）** | `strata-dsv41` 0.1.49.2（代码即 Maya 的 `maya-ds4` 移植版） | ISTA-DASLab **GSQ-RCO** GGUF：IQ2_XXS 核心 136GB + Engram IQ4_NL 110GB + DSpark 7.9GB | ✅ 已有文件；prefill 2048 tok/s @512k |
| Project Maya（`mw00/project-maya`） | `maya-ds4`（v1.1.67） | **Maya 自家** quant（Maya-S 340GB / Maya-XS 277GB，Engram 是 Q6_K）、**Unsloth UD-IQ1_M / UD-IQ3_S / UD-Q8_K_XL**（301/424/467GB）、EXL3 2.25/2.9/3.5bpw、abliterated GGUF；**不含 GSQ-RCO**（仓库内无任何 "GSQ" 引用） | ❌ 需重下 277-467GB |
| PolyStrata（`simplexai-labs/PolyStrata`） | 自研 `strata-poly` 引擎 | 只有 **DeepSeek V4 Flash（0731，91GB，Unsloth UD-IQ2_XXS）**——不是 V4.1-Flash-1017；QFN 仍用 Strata 原引擎 | ❌ 不是同一代模型 |

**决定：继续用 Strata v0.2.4.2 的 `strata-dsv41`。**

- 它就是 Maya 引擎的移植版（二进制 usage 里写着 `maya-ds4`），0.1.49.2
  恰好是长上下文 prefill 未回归的快照；
- 现有 GSQ-RCO 文件直接可用，零下载；Maya 要换整套 277-467GB 的文件，
  且其公开机测是单卡 96G + 61-92GB RAM 的配置（如 512K prefill 3810、
  1M decode 39.6），与本机双卡 + 251GB RAM 的配置不可直接比较，没有证据
  表明在本机会更快；
- PolyStrata 的 DeepSeek 是更早的 V4-Flash-0731，不适用；它的 QFN 用的
  仍是 Strata 引擎，也没有额外收益。
- 将来若要跟进新 DS4.1 特性（新 prompt 路径、新 drafter），迁移目标是
  **Maya**（同引擎血脉、flag 兼容 `--experts`/`--ssd-cache` 等），但需按
  它的 quant 列表重新下载模型。

## KV cache 量化（QFN 可调，DS4.1 不适用）

`strata-engine`（QFN）支持 `--kv fp16|int8|q4_0|k8v4`；`strata-dsv41`
（0.1.49.2）**没有 `--kv` 参数**——它的 KV 是压缩注意力（4 个
kv_source_layer + compress_ratios），512k 时仅 0.19-0.29GB/卡，没有
量化的必要（在它的 run config 里加 `kv` 键也不会传给引擎）。

实测（2026-11-15，QFN 单卡 96G，1M 上下文，GPU 3）：

| `--kv` | 显存 | 32k prefill | 32k decode* | 32k 事实检索 |
| --- | --- | --- | --- | --- |
| fp16（默认） | 72.4G | 5,236 tok/s | 143-178 t/s | ✅ "4815" |
| int8 | 60.5G | 6,199 tok/s | 132-169 t/s | ✅ "4815" |

\* decode 受 DSpark 草稿命中率影响大（同一 prompt 两次运行差 ±20%），
只能看趋势；int8 的 KV 读带宽减半，prefill 稳定 **+18%**，decode 在噪声内。
1M 上下文的 KV 在 fp16 下约 23.8G，int8 省 11.9G。

**质量**（Strata 自带 teacher-forced 基准 `bench/results/2026-09-27-kv-q4`，
fp16 为基准）：**int8 与 fp16 基本无法区分**（top-1 一致 92-98%、KL
0.009-0.114、困惑度在噪声内）；**q4_0 有可测损失**（top-1 88-96%、KL
0.028-0.297、文档困惑度 +8% @1K、+12% @8K，且随上下文变差）。社区量测
同向：q8/int8 近似无损；4-bit 里**K cache** 是敏感的一半（V 可以压到
4-bit），llama.cpp PR #7412 与多份 KV 量测帖都显示 q4_0 的 K 在长上下文
下明显掉分；还有预印本指出低比特 KV 会让困惑度看着正常但安全对齐/行为
退化。注意两个模型权重已量化到 IQ2_XXS / IQ3_XXS，KV 再压 4-bit 的损失
会叠加。

**结论（hhf200：8×96G + 251G RAM）**：显存不是瓶颈 → 两个模型都用默认
**fp16**。QFN 1M 时 fp16 占 72.4G、余 23.5G，int8 省下的 12G 没有用途
（24576 专家已全驻留 VRAM）。只有这些场景才用 `--kv int8`：想一张卡跑
两个模型、想开更大上下文、或用 `--kv-grow` 把显存让给专家缓存——质量
安全、prefill 更快、decode 不退化。**`q4_0` 不建议**用于推理/长文场景
（要省就用 `k8v4`：int8 K + q4_0 V，816B/cell，社区数据显示 K8V4 安全）。

## 图像（视觉）

两个模型的图片支持差异很大：

### QFN（strata-engine）—— **已启用**（2026-11-15，生产 config）

* 需单独编译图片编码器（llama.cpp mtmd，`tools/vision`）：
  `cmake -S tools/vision -B build-vision -DLLAMA_DIR=<llama.cpp checkout>
  -DSTRATA_VISION_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 -DSTRATA_PORTABLE=OFF`，
  产物装到 `$CONDA_PREFIX/bin/strata-vision`。**`strata-build` 已默认
  构建并安装它**（见文首），重建环境时跑一次 `strata-build` 即可。
* `config/strata-qwen.json` 已含 vision 段（相对路径按 cwd 解析），args
  里显式加 `--vision --vram-reserve-mib 700`（编码器与引擎同卡，预留
  700MiB，编码器实际占 ~1.7GB）：
  ```json
  "vision": {"exe": ".pixi/envs/strata-cuda/bin/strata-vision",
             "mmproj": "/data/huggingface-downloads/Qwen3.8-Flash-Next/mmproj-Qwen3.8-Flash-Next-BF16.gguf",
             "model": "<IQ3_XXS shard 1>", "gpu": true, "max_tokens": 1024}
  ```
  `model` 只用于读 vocab。用 pinned 的 BF16 mmproj（907,543,008 B；目录里
  的 `mmproj-F16.gguf` 904,004,000 B 不是 pinned 版本）。可选用
  `"cuda_device": N` 把编码器钉到别的卡（省引擎卡的 ~1.7GB，但那张卡
  被占满时模型会起不来，故生产默认同卡）。
* 实测（2026-11-15 生产实例，GPU 6）：768×512 PNG → 461 image+text
  tokens；编码器 warm-up 0.3s（1024 image tokens）、prompt **883 tok/s**、
  decode **154.7 tok/s**；答案正确（读出 "7391" 与左右布局）。llama-swap
  条目 `capabilities.in` 已加 `image`。

### DS4.1（dsv41）—— 0.1.49.2 不支持，需 v0.2.13 / 引擎 0.1.59

* `docs/DEEPSEEK41.md`（v0.2.4.2）："Not in this version: … pictures
  (`--vision` is ignored with a warning)"。mmproj + `strata-vision` 的路
  也走不通：llama.cpp 3cf03257 不认识 `deepseek41` 架构（b12282 认识，但
  用 b12282 的编码器会因该模型的 tiled 预处理得到非矩形 token 网格，
  `strata-vision` 拒绝——引擎 GENI 只接受单矩形网格）。
* v0.2.13（0.1.59）**内置视觉塔**（不需要 strata-vision/mmproj 段）：
  - pack 必须用 0.2.13 的 `pack_gguf.py --mmproj <mmproj.gguf>` 重建；
    pack 里会有 `vision.*` 与 `image_token_id`（本模型 129264，32 层，
    patch 14，max 1024 image tokens）。
  - 服务端需要 Pillow，自动把图缩到「边长 42 的倍数、≤1024 image tokens」。
  - 实测：768×512 → 284 prompt tokens，视觉塔读图 241ms（缓存后 0ms），
    答案正确；0.1.59 速度：prefill 70.9 tok/s（284 tok 4.0s）、decode
    81 t/s（Engram 热）。
* **决定（2026-11-14）：以性能为先，DS4.1 图片暂缓。** 保持 v0.2.4.2
  （0.1.49.2，长上下文 prefill 2.2k tok/s）；等上游修复 0.1.59 的 10×
  prefill 回退（见 `docs/strata-prefill-regression.md`、#5894）且新版
  仍带内置视觉塔时，再升级并测试图片。当前不做 v0.2.13 的并行条目
  （装两份引擎、两套 pack 的维护成本不值）。

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
8. **清理**：pack 目录（仓库根 `strata-packs/`，qwen 1.5G / dsv41 几 MB，
   已入 .gitignore）用完可删，重生成很快（`pixi run -e strata-cuda strata-pack`）；
   模型文件永远只读。
