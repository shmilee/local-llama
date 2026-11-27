# Inkling-2-Mini

|      |      |
| ---- | ---- |
| 状态 | 在役（2026-11-27，vLLM nightly 独立环境）；llama.cpp b12776 路线已实测，留作后备 |
| 权重 | 主：NVFP4（modelopt）19.5G + mtp.safetensors 606M（`Inkling-2-Mini/`）。后备：GGUF UD-Q8_K_XL mainline layout 21.2G + mmproj-BF16 + dspark BF16（`Inkling-2-Mini-GGUF/`）。下载记录见 `docs/models.md`「5. MoE, Inkling-2-Mini」 |
| 平台 | PRO6000（8×96G），GPU 3（node 0，单卡，不共卡） |
| 测试版本 | 主：vLLM 0.34.1rc1.dev214+g62d538c61（nightly，2026-11-26 构建，含 vllm/models/inkling2 包）；torch 2.14.0+cu132。后备：llama.cpp b12801（2026-11-27 复测，#33063 FA indexed bias 生效） |
| 资源占用 | 实测 94.2G / 96G（NVFP4 权重 19.5G + KV 池自动扩满，256k=262,144 ctx） |

> 命令约定：`${PORT}` 由 llama-swap 加载时分配；宏已展开。

## 条目总览

| 条目 | 后端 | ctx | prefill | decode | dspark | 显存 | 状态 |
| ---- | ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| `inkling-2-mini-fp4-256k` | vLLM nightly（TP1） | 256k | @253k ~7.2K t/s（31k 前缀命中） | @30k 190 / @253k 127 t/s | 接受率 18-20%，mean 2.27-2.37 | 94.2G | 在役 |
| （未登记）llama.cpp b12801 Q8 | llama.cpp（单卡） | 256k f16 KV | @30k 2911 / @253k新token 910 t/s | @30k 74.9 / @253k 44.7 t/s | 接受率 21.5%/15.0%，mean 2.06/1.74 | 35.1G | 后备（仍慢于 vLLM 2.5-7.8×，Qwen 回归无损） |

## `inkling-2-mini-fp4-256k`（在役）

### cmd（2026-11-27 快照；活动条目以 config 为准）

```
pixi run -m ${env.LOCAL_LLAMA_HOME} -e vllm-nightly vllm serve
  /data/huggingface-downloads/Inkling-2-Mini
  --host 127.0.0.1 --port ${PORT}
  --tensor-parallel-size 1
  --max-model-len 262144
  --reasoning-parser inkling
  --enable-auto-tool-choice
  --tool-call-parser inkling
  --speculative-config '{"method":"dspark","num_speculative_tokens":7,"draft_sample_method":"probabilistic"}'
  --enable-per-request-metrics
  --enable-prompt-tokens-details
  --per-request-spec-decode-metrics summary
  --max-num-seqs 6
  --sse-keep-alive-interval 15
```

env：`CUDA_VISIBLE_DEVICES=3`；ttl 36000；routing group3（与 group1/2 并存）；
调度优先级 8。注意 vLLM 按启动路径注册模型名，客户端 model 字段须传
`/data/huggingface-downloads/Inkling-2-Mini`（llama-swap 的 useModelName 已处理）。

### 实测（2026-11-27；合成压测 prompt，GPU 3）

| 指标 | 30k prompt | 253k prompt |
| --- | --- | --- |
| prompt_tokens | 31,052 | 253,304（前缀缓存命中 31,040，新建 222,208） |
| TTFT / prefill | 20.6 s（1504 t/s，含首请求预热） | 31.4 s（新 token ~7.2K t/s） |
| decode（200 tok） | 190 t/s | 127 t/s |
| dspark | 接受率 19.6%，mean 2.37 | 接受率 18.2%，mean 2.27 |
| 总 wall（pre+200 dec） | 21.8 s | 33.3 s |

冒烟（2026-11-27 同日）：文本 / 工具调用 / 图片三项全过（与 llama.cpp 侧一致：
自报 Inkling/TML、function call 参数正确、红方块图识别正确）。

### 优缺点

* 官方 recipe 验证路径：FA 完整（长 prefill 线性）、NVFP4 权重省显存（19.5G）、
  DSpark 投机（7 draft）mean acceptance 2.3。同 prompt 对照 llama.cpp b12776：
  253k prefill 快 ~23×、decode 快 ~5×。
* vLLM 处于 nightly（0.35 未发布）：环境独立于在役 vllm-cuda 0.34（pixi 双环境，
  互不影响），但 nightly 每日滚动——vllm-nightly 环境的 pin 滚动失效时需改
  pixi.toml 重 lock（见 pixi.toml vllm-nightly 注释）。
* 1M 上下文单卡不可行（f16 KV 192G），双卡层切分方案 2026-11-26 按资源预算
  否决；256k（262,144）为 96-128G 档官方验证上限。
* 显存 94.2G/96G 偏紧（vLLM 默认 gmu 把 KV 池扩满）：GPU 3 专用（group3），
  无共卡风险；若未来 3 卡要跑别的，需显式加 `--gpu-memory-utilization`。

## llama.cpp 后备路线（2026-11-26/27 实测，未登记条目）

权重：`/data/huggingface-downloads/Inkling-2-Mini-GGUF/`（unsloth UD-Q8_K_XL 的
**mainline layout** 变体——根文件是 Unsloth layout，mainline 读不了；dspark 用
mainline 格式）。

**b12801 复测（2026-11-27，GPU 5，同口径 prompt）**：#33063
（Flash Attention with indexed bias，b12801 tag 即该 commit）+ #33060
（CUDA 融合）生效后：prefill @30k 2911 t/s / @253k 新 token 910 t/s
（b12776 为 1138/313，提升 2.6-2.9×）；decode @30k/253k ctx 74.9/44.7 t/s
（b12776 50.8/24.9，提升 1.5-1.8×）；显存 59.7G → 35.1G（KV 布局变化）。
长 prefill 仍有 ~3.2× 头尾衰减（FA 部分覆盖），与 vLLM 的差距从 5-23×
收窄到 2.5-7.8×。Qwen3.8-27B 回归无损（40k prefill 3943 t/s / decode 40.5 t/s）。

```
pixi run -m ${env.LOCAL_LLAMA_HOME} -e llamacpp-cuda llama-server
  --port ${PORT}
  --model /data/huggingface-downloads/Inkling-2-Mini-GGUF/Inkling-2-Mini-UD-Q8_K_XL.gguf
  --mmproj /data/huggingface-downloads/Inkling-2-Mini-GGUF/mmproj-BF16.gguf
  -md /data/huggingface-downloads/Inkling-2-Mini-GGUF/dspark-Inkling-2-Mini-BF16.gguf
  --spec-type draft-dspark --spec-draft-n-max 5 --n-gpu-layers-draft 99
  --n-gpu-layers all --device CUDA0
  --ctx-size 262144
  --flash-attn on
  --jinja
  --temp 1.0 --top-p 1.0 --top-k 0 --min-p 0.0
```

b12776 版本坑（实测）：

* `--ubatch-size 4096`（default-llama 宏参数）申请 ~100GiB 计算 buffer 直接 OOM
  （looped MoE 的专家激活随 ubatch 线性放大）——该条目**不能用宏**，ubatch 用默认 512。
* `--ngld` 短别名被参数解析器拒载（`--help` 列着但不可用），须写
  `--n-gpu-layers-draft`。
* NVML 头依赖：b12776 起 ggml-cuda.cu 编译期 `#include <nvml.h>`（运行时 dlsym），
  conda 拆分包不含 → pixi.toml llamacpp-cuda 加 `cuda-nvml-dev`（13.2.86）。
* **prefill 短板（b12776 时点）**：rel-bias 注意力（d_rel=16）在 b12776 CUDA
  后端无 FA kernel，长 prefill O(n²)（253k 冷灌 809s；同硬件同版本 Qwen3.8-27B
  有 FA，260k 仅 118s——排除构建问题）。b12801 起 #33063 补上 indexed-bias FA
  （+ #33060 融合、#33073 DFlash2），上述数字全面改善（见下节复测）。
  DFlash2 是 DSpark 的后续实现，本后备路线仍用 draft-dspark（与已下载草稿文件
  配套）。

## 决策记录

* 2026-11-26 上午：vLLM 路线首发——登记条目 `inkling-2-mini-fp4-256k`
  （NVFP4 权重 20.2G 已下载）；阻塞于 vLLM 0.35 未发布（稳定版 vllm-cuda 0.34
  不支持 inkling2_loop）。
* 2026-11-26 下午：尝试 llama.cpp 路线——b12500 缺全部三个 PR
  （#32694 11-20 / #32704 11-21 / #32218 11-24），升级 mainline b12776
  （最新带 UI release 资产的 tag）；Qwen3.8-27B 回归通过；Inkling 冒烟三项通过，
  但 prefill O(n²)（无 FA）。上下文矩阵：256k 实测 59.7G/313 t/s/24.9 t/s；
  512k q8_0 KV 显存可行但 prefill 外推 ~60min 弃测；1M 双卡方案按资源预算否决。
* 2026-11-26 晚：定路线——**vLLM nightly 独立环境**。建 pixi `vllm-nightly`
  （vllm dev214 + torch 2.14.0+cu132 栈 + gcc 15 pin）；flashinfer JIT 探针
  通过；实测 prefill/decode 全面优于 llama.cpp 5-23×（见上表）。
* 2026-11-27：条目转正（vllm-nightly cmd），在役；llama.cpp 路线降级后备。
  同日 llama.cpp 升级 b12801（#33063 FA indexed bias + #33060 融合，b12801 tag
  即 FA commit）复测：Inkling prefill 2.6-2.9×、decode 1.5-1.8×、显存 -24.6G，
  Qwen 回归无损——pin 保留 b12801。待办：0.35 稳定版发布后 vllm-nightly 迁回
  vllm-cuda 或升 pin 统一。

## 相关

* 候选池与下载记录：`docs/models.md`「5. MoE, Inkling-2-Mini」
* vLLM 环境/工具链：`docs/vllm.md`、`pixi.toml`（vllm-cuda / vllm-nightly）
* llama.cpp 构建/版本：`docs/llama.cpp.md`、`pixi.toml`（llamacpp-cuda）
* 路由分组：`docs/llama-swap.md`「配置文件结构（PRO6000）」
