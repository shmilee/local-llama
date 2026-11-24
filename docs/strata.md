# Strata（CUDA 环境）

`strata-cuda` 环境（环境定义与构建细节见 `docs/pixi-environments.md` 的
Strata 章节）。当前版本 **v0.2.20（引擎 0.1.66）**，只包含主引擎
（`flash_next` 形状，Qwen3.8-Flash-Next 用）+ 图片编码器 + Python 终端：

| 产物 | 用途 |
| --- | --- |
| `strata-engine` | 主引擎（`flash_next` 形状；token 级，吃 token id） |
| `strata-vision` | 图片编码器（0.2.16+ 是 Strata 自有 Qwen 视觉塔，不依赖 llama.cpp） |
| `strata-device` | GPU 诊断/自检 |
| `strata` | Python 终端（OpenAI/Anthropic 兼容 API、CLI） |

> 上游 0.2.14 起移除了 DeepSeek（dsv41）引擎（#6072/#6048），本环境不再
> 构建/配置 dsv41；DeepSeek-V4.1 改用独立的 Project Maya 环境
> （`maya-*` 任务，见 pixi.toml）。

引擎是 **token 级**：命令行吃 token id（`--tokens` / `--tokens-file`），
不吃文本 prompt；聊天模板、OpenAI 兼容 API 在终端（`strata serve`）那一层。
本文的"引擎直跑"是冒烟/排障路径，日常服务走终端。

```
pixi install -e strata-cuda
pixi run -e strata-cuda strata-build   # 引擎 + 视觉塔 + 终端（首次约 15 分钟）
pixi run -e strata-cuda strata-verify  # 二进制 + GPU + Python 依赖
pixi run -e strata-cuda strata-pack    # 备 QFN run pack（幂等）
```

本机模型（只读使用）：`/data/huggingface-downloads/`。跑之前用
`nvidia-smi` 确认用**空闲卡**（生产 llama-swap 会随时占卡，别硬抢）。

---

## Qwen3.8-Flash-Next（实测：GSQ-RCO IQ3_XXS 71GB，单卡 PRO6000）

### 1. 准备 pack（约 1 分钟，产物 1.5G）

```
pixi run -e strata-cuda strata-pack         # 从 config/strata-qwen.json 的
                                            # --native/--ple-gguf 推导模型路径
```

手工（等价，排障参考）：IQ3_XXS 这类 i-quant 走 **native pack**：专家权重
不复制，运行时直接读 GGUF（所以不加 `--experts-bin`）。

```
cd download/Strata-0.2.20                   # 目录名 = $STRATA_VERSION
python terminal/tools/iq_pack.py --gguf <绝对路径 shard1> --out strata-packs/qwen38fn-iq3xxs
```

### 2. 引擎直跑（冒烟命令）

**IQ/native pack 必须三件套**：`--native <shard1> --spec 2 --prefill auto`
（引擎会明确拒绝缺的）。另外两个容易漏的：

* `--ple-gguf`：含 `per_layer_token_embd.weight` 的分片（IQ3_XXS 是
  **shard 2**；用 `terminal/tools/gguf_reader.py` 列各分片 tensor 名确认）
* `--expert-profile`：decode 需要设备驻留表，给环境自带的
  `$CONDA_PREFIX/strata/data/expert-profile.bin`，**缺了 prefill 能跑、
  decode 直接拒启**

```
strata-engine --pack strata-packs/qwen38fn-iq3xxs \
  --native  <绝对路径 shard1> \
  --ple-gguf <绝对路径 shard2> \
  --spec 2 --prefill auto --ple-io ram \
  --expert-profile $CONDA_PREFIX/strata/data/expert-profile.bin \
  --tokens "109266,6115,139054,110827,113552,111522,1710" \
  --gpu 0 --max-new 64 --max-context 4096 --greedy
```

prompt 的 token id 用仓库自带分词器生成（纯 python，round-trip 可靠）：

```
python -c "
import sys; sys.path.insert(0, 'terminal/tools')
from strata_tokenizer import Tokenizer
tk = Tokenizer.from_gguf('<shard1>')
print(','.join(map(str, tk.encode('你好！请用一句话介绍一下你自己。'))))"
```

### 3. 实测（v0.2.20 / 0.1.66，生产实例，单卡 96G，GPU 6）

| 场景 | 数值 | 对比（0.1.49.2 / v0.2.4.2） |
| --- | --- | --- |
| 短 prompt 65 tok | prefill **436 tok/s** | 229 tok/s |
| **131k prompt** | prefill **7,562 tok/s**（17.4s） | 5,068（0.1.61：5,960） |
| decode（200 tok） | **173 tok/s** | 151（同 prompt 量级） |
| 图片 768×512 | 461 image+text tokens，prompt **1,915 tok/s**，decode 177 tok/s | 883 / 155 |

* prompt 分块 `auto` 在 0.1.66 是 **32k**（0.1.49.2 是 8k），每请求固定
  开销更低；长 prompt 1.5–1.6 倍于旧版
* **主机内存 ~74GB**（RSS）：PLE 表 26.8GiB（`--ple-io ram` mlock，必需——
  HDD 上 direct 只有 3MB/s）+ 专家 arena ~40GiB（默认 pinned，见下）
* 1M 上下文（单卡 96G）显存 ~72G（fp16 KV）
* `--ssd-cache` 是 dsv41 时代参数，主引擎没有也不需要

## 内存：专家 arena 与 `--mmap-experts`

* 默认：专家 arena **~40GiB pinned**（全部 24576 专家已驻留显存，arena 只是
  填充/借用的主机侧副本）。机器 251GB 内存时无压力，与 DS4.1 并存时要注意。
* `--mmap-experts`：改为 mmap 模型文件，40GB 变成**可回收 page cache**
  （`ps` 的 RSS 数字不变 ~73GB，但 locked 只有 28GB）。代价（0.1.49.2 上
  实测）：16k prefill 4,412 → 3,523/3,717 tok/s（-15%），decode 不变；
  `--resident-cpu-experts` 再多 ~3.5GB 常驻且不改善 prefill。
* 建议：默认（快）；内存紧张时用 `--mmap-experts`。0.1.66 未复测该 A/B。

## KV cache 量化

`strata-engine` 支持 `--kv fp16|int8|q4_0|k8v4`（另有 `--kv-resident`/
`--kv-grow`）。实测（0.1.49.2，1M 上下文）：

| `--kv` | 显存 | 32k prefill | 32k decode* |
| --- | --- | --- | --- |
| fp16（默认） | 72.4G | 5,236 tok/s | 143-178 t/s |
| int8 | 60.5G（**-11.9G**） | 6,199 tok/s | 132-169 t/s |

\* decode 受 DSpark 草稿命中率影响大，只能看趋势；int8 的 KV 读带宽减半，
prefill 稳定 +18%。

**质量**（Strata 自带 teacher-forced 基准 `bench/results/2026-09-27-kv-q4`，
fp16 为基准）：**int8 与 fp16 基本无法区分**（top-1 一致 92-98%、KL
0.009-0.114、困惑度在噪声内）；**q4_0 有可测损失**（top-1 88-96%、KL
0.028-0.297、文档困惑度 +8% @1K、+12% @8K，且随上下文变差）。社区量测
同向：q8/int8 近似无损；4-bit 里 **K cache** 是敏感的一半。注意 QFN 权重
已经是 IQ3_XXS，KV 再压 4-bit 的损失会叠加。

**结论（hhf200：8×96G + 251G RAM）**：显存不是瓶颈 → 用默认 **fp16**。
int8 只在需要省显存时用（一张卡跑两个模型、更大上下文、`--kv-grow`）；
`q4_0` 不建议用于推理/长文场景（要省用 `k8v4`）。

## 图像（视觉）

QFN 已启用（`config/strata-qwen.json` 的 vision 段 + args 里的
`--vision --vram-reserve-mib 700`）：

* 编码器 `strata-vision` 由 `strata-build` 一起构建安装。0.2.16+ 是
  **Strata 自有 Qwen 视觉塔**（`terminal/tools/vision/own`，不编译
  llama.cpp/mtmd）；读的还是 pinned 的
  `mmproj-Qwen3.8-Flash-Next-BF16.gguf`（907,543,008 B）
* `vision.model` 只用于 vocab；`vision.gpu: true` 让视觉塔上卡（实测占
  **956MiB** 显存，比旧版 1.7GB 小）；`cuda_device` 可选，把编码器钉到别的
  卡（那张卡被占满时模型起不来，故生产默认同卡）
* 实测（0.1.66）：768×512 PNG → 461 image+text tokens，读图后 prompt
  **1,915 tok/s**、decode 177 tok/s；正确读出 "ACCESS CODE 7391" 与
  左右布局。视觉塔加载 0.9s、warm-up 0.5s
* **重建 pixi 环境后要跑一次 `strata-build`**（否则 QFN 启动会因编码器
  缺失失败）

## llama-swap 集成（PRO6000 配置）

`config/llama-swap-config-PRO6000.yaml` 里的条目
`qwen3.8-flash-next-iq3-1m`（别名 `Qwen3.8-Flash-Next-Strata`）：

```yaml
"default-strata": >
  env -C ${env.LOCAL_LLAMA_HOME}
  pixi run -m ${env.LOCAL_LLAMA_HOME} -e strata-cuda strata serve

"qwen3.8-flash-next-iq3-1m":
  cmd: |
    ${default-strata}
    --config config/strata-qwen.json
    --port ${PORT}
  ...
  capabilities: {in: [text, image], ...}
```

* **run config 的 `aliases` 必须包含 llama-swap 的模型键/别名**：
  0.2.20 终端会拒绝"看起来像 Strata 模型"但不在 `model_name`/`aliases`
  里的名字（`strata serve` 的 `check_model`）。`config/strata-qwen.json`
  已写 `"aliases": ["qwen3.8-flash-next-iq3-1m", "Qwen3.8-Flash-Next-Strata"]`
* llama-swap 直接 exec 命令不走 shell，宏里用 `env -C` 钉工作目录
  （run config 的相对路径以它为基准）
* 子进程 PATH 无 pixi 时 cmd 要用绝对路径（生产 start 脚本环境有 pixi）

## 注意点汇总

1. **先选空闲卡**。生产 llama-swap 会在 2/6 号卡之间换模型，跑之前
   `nvidia-smi` 看一遍；被抢占只会拖慢不会破坏。
2. **路径全用绝对路径**（`--native`/`--ple-gguf`/`--expert-profile`）。
   引擎吃 token id 不吃文本；ids 用 `terminal/tools/strata_tokenizer.py` 生成。
3. **启动慢是正常现象**：冷启动 ~5-10 分钟（PLE mlock + 专家 arena 流式读），
   日志在阶段结束才刷；看进度用 `ps` 的 RSS / `/proc/<pid>/io`。
4. **内存**：QFN native 路径 ~74GB RSS（PLE 26.8G mlock + arena 40G）；
   251GB 内存的机器没压力。
5. **版本**：环境 pin **v0.2.20（引擎 0.1.66）**；0.2.16+ 源码布局是
   `engine/` + `terminal/`（视觉塔在 `terminal/tools/vision`），ggml 用
   vendored `engine/third_party/strata-ggml`（无需下载 llama.cpp）。
   构建仍需显式 CUDA 架构号（`native` 会触发部分版本的 ptxas 问题）。
6. **日常服务走 Python 终端**（`strata serve` / run config 指向
   `$CONDA_PREFIX/bin/strata-engine`），`strata launch` 的组件流会从 feed
   下预编译引擎——本机 GitHub 不可达，用不了那条路，以本地源码构建为准。
7. **清理**：pack 目录（仓库根 `strata-packs/qwen38fn-iq3xxs`，~1.5G，
   已入 .gitignore）用完可删，重生成很快（`pixi run -e strata-cuda strata-pack`）；
   模型文件永远只读。
