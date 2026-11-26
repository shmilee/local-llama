# 模型挑选与下载

## 参考

* <https://gemma4-ai.com/zh/blog/best-local-ai-models-2026>
* <https://jimmysong.io/zh/book/ai-handbook/llm/model-selection/>
* <https://www.siliconflow.com/articles/zh-Hans/best-small-LLMs-under-10B-parameters>
* MTP <https://github.com/ggml-org/llama.cpp/pull/22673>

## 量化类型

| 量化类型 | 性能特点 | 适用场景 |
| -------- | -------- | -------- |
| IQ4_XS   | 同等大小下，IQ 格式的智商显著高于 Q 格式 | 硬件受限时，简单的日常写作 |
| Q4_K_M   | 速度和精度兼顾, 资源占用适中 | 日常对话、写作、通用任务 |
| UD-Q4_K_XL | 质量优先, Unsloth 动态量化技术, XL 比 M 多占一点内存 | 4-bit 追求高性能时的首选 |
| Q5_K / Q8_K | 更高精度，资源占用增加 | 高质量生成, 适合性能更好的服务器 |

术语：

* UD前缀 (Unsloth Dynamic) : 为模型的不同部分（如注意力层）选择合适的量化位宽，保持模型大小不变，将资源用在刀刃上
* K (K-quantization/grouped quantization)：分组量化+K-Means聚类，llama.cpp 的主流方式，更好地保留模型表现
* XXS、XS、S、M、XL：混合精度策略的程度
* IQ (Importance Matrix Quantization) : 重要性矩阵（imatrix）量化，第二代更聪明的量化。算法会测一遍模型，找出重要参数（不砍），不重要参数（可多砍）。

## 候选模型

1. Dense, Qwen3.8, Alibaba Cloud, Text, Image + Video
   - 擅长代码
   - <https://huggingface.co/unsloth/Qwen3.8-27B-GGUF>
     + `Qwen3.8-27B-UD-Q8_K_XL.gguf`, `mmproj-BF16.gguf`
   - <https://huggingface.co/ukisai/Swift-Qwen3.8-27B-GGUF> 减少 token 使用量
     + ref: <https://www.reddit.com/r/LocalLLM/comments/1wgwgrf/comment/p9xkf6k/>
     + `Swift-Qwen3.8-27B-Q8_0.gguf`, `mmproj-Swift-Qwen3.8-27B-F16.gguf`
   - FP8 量化 <https://huggingface.co/Qwen/Qwen3.8-27B-FP8>（vLLM / SGLang 后端用）
     + 30.9G, `hf download Qwen/Qwen3.8-27B-FP8 --local-dir ./Qwen3.8-27B-FP8`
   - 长任务测试 <https://www.reddit.com/r/LocalLLM/comments/1wj1j9z/qwen_38_27b_running_for_63_hours_on_a_rtx_3090_to/>
     + Riemann hypothesis
     + 本地模型的长期记忆、工具调用、代码执行、上下文卸载/恢复

2. MoE, Qwen3.8 Flash Next, Alibaba Cloud, qwen4 实验新架构
   - <https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF>
     + `Qwen3.8-Flash-Next-UD-IQ4_XS-0000{1,2,3}-of-00003.gguf`, `mmproj-F16.gguf`
   - NVFP4 量化 <https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4>（vLLM / SGLang 后端用，133G 需多卡）
     + `hf download nvidia/Qwen3.8-Flash-Next-NVFP4 --local-dir ./Qwen3.8-Flash-Next-NVFP4`
   - <https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF>
     + ref: <https://www.reddit.com/r/LocalLLM/comments/1wiynyo/comment/pael83n/>
     + 75.8G, `IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-0000{1,2}-of-00002.gguf`
     + `mmproj-Qwen3.8-Flash-Next-BF16.gguf`

3. MoE, DeepSeek-V4.1-Flash-1017, Text + Image
   - <https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF>
     + 138G, `DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-0000{1,2,3,4,5}-of-00006.gguf`
     + 111G, `DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf`
     + `mmproj-DeepSeek-V4.1-Flash-1017-BF16.gguf`
   - <https://huggingface.co/unsloth/DeepSeek-V4.1-Flash-1017-GGUF>
     + 只下载草稿 `dspark-DeepSeek-V4.1-Flash-1017-Q8_0.gguf`

4. MoE, GLM-5.3-Flash (321B, 18B active), Text + Image, Project Maya 引擎
   - <https://huggingface.co/unsloth/GLM-5.3-Flash-GGUF>（ModelScope 有镜像，国内快）
     + **UD-Q3_K_XL（147.5GB，本次选）** / UD-IQ3_XXS（120.4GB）/ UD-IQ2_XXS（101.8GB）
     + UD-Q4_K_XL 199.7GB 起对 2×96G 偏大（只适合 3 卡或更大显存）
   - <https://huggingface.co/peasantsmith/GLM-5.3-Flash-Maya-GGUF>（Maya 自家）
     + Maya-M（116GB，IQ2_S/IQ3_XXS，Q6_K attention，带 MTP 草稿块）
     + Maya-S 96.5GB / Maya-S24 94.7GB / Maya-XS 73.4GB；视觉 1.14GB
   - 社区 GGUF（glm5-next 架构）属 Maya 实验路径：`--gguf-dir` + `tools/iq_pack.py`；
     只给 Maya 引擎用（`--glm-pack`），llama.cpp / vLLM / Strata 读不了这个 pack。


5. MoE, Inkling-2-Mini (26B 总参 / 3.5B 激活), Thinking Machines, Text + Image,
   循环架构 + DSpark（2026-11 新模型，当前热点）
    - looped MoE：prelude 6 层 + core 12 层 × 3 pass + coda 6 层 = 48 次层访问、
      48 个独立 KV cache（~192KiB/tok @bf16）；128 专家 top-8；
      checkpoint 原生 1M，GB200 单卡验证 1M，96-128G 档验证上限 262k
    - <https://huggingface.co/thinkingmachines/Inkling-2-Mini>
      + NVFP4（modelopt，官方唯一量化）：`model-00001-of-00001.safetensors` 19.5G、
        `mtp.safetensors`（DSpark 投机草稿）606M，apache-2.0
        - 混合精度：~94% 参数（24 层 MoE 专家 w13/w2）为 NVFP4（U8 打包 E2M1
          + F8_E4M3 scale，block 16），注意力/embeddings/norms 保持 BF16；
          safetensors 里 BF16 张量多不代表非 FP4 量化
    - vLLM 需要 nightly（>=0.35，0.35 未发布；inkling2_loop 架构稳定版不支持）
    - recipe: <https://recipes.vllm.ai/thinkingmachines/Inkling-2-Mini>
      + `--reasoning-parser inkling --enable-auto-tool-choice --tool-call-parser inkling`
      + `--speculative-config '{"method":"dspark","num_speculative_tokens":7,"draft_sample_method":"probabilistic"}'`
    - ModelScope 镜像 <https://modelscope.cn/models/thinkingmachines/Inkling-2-Mini>
      （本次实测比 hf-mirror 快 ~35×，见下载记录）

11. MoE, Qwen3.6, Alibaba Cloud, Text + Image + Video
   - 基础工作, 速度优势
   - <https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF> 或 <https://modelscope.cn/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF>
     + `Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf`, `mmproj-BF16.gguf`
     + `Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf`, `Qwen3.6-35B-A3B-UD-IQ4_XS.gguf`, `mmproj-F16.gguf`
   - <https://huggingface.co/mradermacher/Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V11-dequantized-i1-GGUF>
     + `Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V11-dequantized.i1-IQ3_S.gguf`
     + `Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V11-dequantized.i1-IQ4_XS.gguf`
   - <https://huggingface.co/mradermacher/Qwen3.6-35B-A3B-uncensored-heretic-i1-GGUF>
     + `Qwen3.6-35B-A3B-uncensored-heretic.i1-IQ4_XS.gguf`
   - <https://huggingface.co/HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive>
     + `Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-IQ4_XS.gguf`
   - <https://huggingface.co/mradermacher/Huihui-Qwen3.6-35B-A3B-Claude-4.7-Opus-abliterated-i1-GGUF>
     + `Huihui-Qwen3.6-35B-A3B-Claude-4.7-Opus-abliterated.i1-IQ3_XS.gguf`
     + `Huihui-Qwen3.6-35B-A3B-Claude-4.7-Opus-abliterated.i1-IQ4_XS.gguf`

12. MoE, Gemma4, Google DeepMind, Text + Image
   - 听/视觉, 写作和语气
   - <https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF>
     + `gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf`, `mmproj-BF16.gguf`
     + `gemma-4-26B-A4B-it-UD-IQ3_XXS.gguf`, `gemma-4-26B-A4B-it-UD-IQ4_XS.gguf`
     + `mtp-gemma-4-26B-A4B-it.gguf`
   - <https://huggingface.co/mradermacher/gemma-4-26B-A4B-it-ultra-uncensored-heretic-i1-GGUF>
     + `gemma-4-26B-A4B-it-ultra-uncensored-heretic.i1-IQ3_XS.gguf`
     + `gemma-4-26B-A4B-it-ultra-uncensored-heretic.i1-IQ4_XS.gguf`

13. Toy, 小模型
   - Llama3.2, Text
     + <https://huggingface.co/unsloth/Llama-3.2-3B-Instruct-GGUF>: `Llama-3.2-3B-Instruct-Q4_K_M.gguf`, `Llama-3.2-3B-Instruct-IQ4_NL.gguf`, `Llama-3.2-3B-Instruct-IQ4_XS.gguf`
     + <https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-uncensored-GGUF>: `Llama-3.2-3B-Instruct-uncensored-Q4_K_M.gguf`
     + <https://huggingface.co/mradermacher/Llama-3.2-3B-Uncensored-i1-GGUF>: `Llama-3.2-3B-Uncensored.i1-IQ4_NL.gguf`
     + <https://huggingface.co/mradermacher/Llama-3.2-3B-Instruct-uncensored-GGUF>: `Llama-3.2-3B-Instruct-uncensored.IQ4_XS.gguf`
   - MiniCPM5
     + <https://huggingface.co/GnLOLot/MiniCPM5-1B-Claude-Opus-Fable5-V2-Thinking-GGUF>: `MiniCPM5-1B-Claude-Opus-Fable5-V2-Thinking-Q8_0.gguf`
   - LFM2.5
     + <https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF>: `LFM2.5-2.6B-Q8_0.gguf`
     + <https://huggingface.co/unsloth/LFM2.5-1.2B-Instruct-GGU>: `LFM2.5-1.2B-Instruct-UD-Q8_K_XL.gguf`
   - DeepSeek-R1-Distill, Text
     + <https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF>: `DeepSeek-R1-Distill-Qwen-1.5B-UD-Q4_K_XL.gguf`
     + <https://huggingface.co/mradermacher/DeepSeek-R1-Distill-Qwen-1.5B-uncensored-GGUF>: `DeepSeek-R1-Distill-Qwen-1.5B-uncensored.Q4_K_M.gguf`
   - Qwen3.5, Text, Image
     + <https://huggingface.co/Smoffyy/Qwen3.5-4B-Instruct-Revised-GGUF>: `Qwen3.5-4B-Revised-q4_k_m.gguf`, `mmproj-f16.gguf`
     + <https://huggingface.co/mradermacher/Qwen3.5-4B-Claude-4.6-OS-Auto-Variable-HERETIC-UNCENSORED-THINKING-GGUF>:
       `Qwen3.5-4B-Claude-4.6-OS-Auto-Variable-HERETIC-UNCENSORED-THINKING.Q4_K_M.gguf`,
       `Qwen3.5-4B-Claude-4.6-OS-Auto-Variable-HERETIC-UNCENSORED-THINKING.mmproj-Q8_0.gguf`。
       来源 DavidAU，修复 Jinja template issues with repeats, long thinking, loops 以及 tool handling。

15. Embedding model, 嵌入模型, RAG
   - Qwen3, VL, <https://huggingface.co/batiai/Qwen3-VL-Embedding-2B-GGUF>
   - `Qwen3-VL-Embedding-2B-Q8_0.gguf`
   - Gemma, <https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF>
   - `embeddinggemma-300M-Q8_0.gguf`

22. Z-Image, 文生图
   - <https://huggingface.co/unsloth/Z-Image-Turbo-GGUF>, `z-image-turbo-Q4_K_M.gguf`
   - <https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF>, `Qwen3-4B-Instruct-2507-Q4_K_M.gguf`
   - <https://huggingface.co/black-forest-labs/FLUX.1-schnell>, `ae.safetensors`

## hf account & token

* 说明:
  - <https://hf-mirror.com/docs/hub/rate-limits>
  - <https://hf-mirror.com/login>
* <https://huggingface.co/settings/tokens>
  - READ Token, download: `hf_xxxxx`
* 镜像 `export HF_ENDPOINT=https://hf-mirror.com`

```
pip install --upgrade huggingface_hub
hf auth login # need proxychains ?
hf auth list
hf download  # 下载模型
hf download --local-dir XXX  REPO_ID [FILENAMES]
```

* 国内 <https://modelscope.cn/>
```
pip install modelscope
ms download  # 代替 hf download
```

## 下载记录

```
export HF_DEBUG=1
export HF_ENDPOINT=https://hf-mirror.com

# 服务器下载 Qwen3.8 稠密模型 Q8
hf download --local-dir ./Qwen3.8-27B unsloth/Qwen3.8-27B-GGUF \
    Qwen3.8-27B-UD-Q8_K_XL.gguf mmproj-BF16.gguf

# 服务器下载 Qwen3.8 FP8
hf download --local-dir ./Qwen3.8-27B-FP8 Qwen/Qwen3.8-27B-FP8

# 服务器下载测试 Qwen3.8-Flash-Next 177B
hf download --local-dir ./Qwen3.8-Flash-Next unsloth/Qwen3.8-Flash-Next-GGUF \
    UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
    UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00002-of-00003.gguf \
    UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf \
    MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf \
    mmproj-F16.gguf
hf download --local-dir ./Qwen3.8-Flash-Next ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF \
    IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-0000{1,2}-of-00002.gguf \
    mmproj-Qwen3.8-Flash-Next-BF16.gguf

# 服务器下载 Qwen3.8 Flash Next FP4
hf download --local-dir ./Qwen3.8-Flash-Next-NVFP4 nvidia/Qwen3.8-Flash-Next-NVFP4

# 服务器下载 DeepSeek 1017
hf download --local-dir ./DeepSeek-V4.1-Flash ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF \
    DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-0000{1,2,3,4,5}-of-00006.gguf \
    DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf \
    mmproj-DeepSeek-V4.1-Flash-1017-BF16.gguf
ln -sv DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf \
    ./DeepSeek-V4.1-Flash/DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-00006-of-00006.gguf
hf download --local-dir ./DeepSeek-V4.1-Flash unsloth/DeepSeek-V4.1-Flash-1017-GGUF \
    dspark-DeepSeek-V4.1-Flash-1017-Q8_0.gguf
```

```
# 服务器下载 GLM-5.3-Flash Unsloth UD-Q3_K_XL（147.5GB；ModelScope；2026-11-24）
# 选型：Maya 自家的 Maya-M（116GB）在 HF 经 hf-mirror 只有 ~5MB/s，116GB 要 6h+；
#       ModelScope 的 unsloth 镜像单文件 16 连接实测 ~87-94MB/s，147.5GB ~30min。
# 兼容性：Maya 的 iq_pack 认 glm5-next / glm5next 架构（社区 GGUF 属实验性，未做质量实测），
#       run config 用 --glm-pack（pack 由 tools/iq_pack.py 生成）。
D=/data/huggingface-downloads/GLM-5.3-Flash-GGUF
mkdir -p "$D/UD-Q3_K_XL"
BASE=https://modelscope.cn/models/unsloth/GLM-5.3-Flash-GGUF/resolve/master/UD-Q3_K_XL

for i in 1 2 3 4; do
  n=$(printf '%05d' "$i")
  f=GLM-5.3-Flash-UD-Q3_K_XL-$n-of-00004.gguf
  aria2c -x16 -s16 -k4M --file-allocation=none --continue=true --max-tries=0 \
    -d "$D/UD-Q3_K_XL" -o "$f" "$BASE/$f" &
done
wait

# 校验：split.count=4，architecture=glm5-next；文件大小见下表（sha256 未在 ModelScope 列出，
# 用 pack + 首跑作为完整性校验；需要 sha 时可对 HF 同名文件（unsloth/GLM-5.3-Flash-GGUF）比对）
ls -l "$D/UD-Q3_K_XL"
# 实测：2026-11-24 15:59-16:30 下完（~69MB/s），147.5GB；
#       maya-pack glm 15 秒；首载 14.3 分钟；decode 58-65 tok/s，专家 100% 在 VRAM（2 卡）
```

| 文件 | 字节 | 说明 |
| --- | ---: | --- |
| `UD-Q3_K_XL/...-00001-of-00004.gguf` | 9,429,984 | 纯元数据 + tokenizer（shard 1） |
| `UD-Q3_K_XL/...-00002-of-00004.gguf` | 49,609,243,584 | shard 2 |
| `UD-Q3_K_XL/...-00003-of-00004.gguf` | 49,623,486,016 | shard 3 |
| `UD-Q3_K_XL/...-00004-of-00004.gguf` | 48,293,762,496 | shard 4 |

* 模型：`unsloth/GLM-5.3-Flash-GGUF` revision `master`（ModelScope 镜像；HF 原仓库同名）。
* 目录：`/data/huggingface-downloads/GLM-5.3-Flash-GGUF/`（pack 生成在 `UD-Q3_K_XL/pack/`，见 `docs/maya.md`）。
* 账本：147.5GB；2×PRO6000 96G（~205GB 可用）+ ≤100GB 内存，显存余量 ~57GB；无 Engram 表。
* 同仓库其它量化（ModelScope 实测大小）：UD-IQ2_XXS 101.8GB、UD-IQ3_XXS 120.4GB、
  **UD-Q3_K_XL 147.5GB（本次选）**、UD-Q4_K_XL 199.7GB（2 卡只剩 ~5GB 余量，不建议）、
  UD-Q5_K_XL 240.3GB / UD-Q6_K_XL 291.8GB / Q8_0 341.0GB（超 2 卡）。
* Maya 自家量化（peasantsmith）：Maya-S 96.5GB / Maya-M 116GB / Maya-L 156.3GB；
  HF 经 hf-mirror 太慢，本次放弃；turboderp EXL3（3.05/4.05bpw）在 ModelScope 只有
  cal_trace，量化文件不在镜像里（HF 才有，Maya 原生支持 `--model EXL3-3.05bpw`）。

```
# 服务器下载 Inkling-2-Mini NVFP4（2026-11-26，合计 ~20.2GB）
# 选型：NVFP4（modelopt）是官方仓库唯一发布量化：19.5G 单文件权重 + 606M DSpark
#       草稿，apache-2.0；需 vLLM >= 0.35（nightly，未发布），本次只下载并登记
#       条目，待 vllm-cuda 环境升级后首跑验证（docs/models/Inkling-2-Mini.md）。
# 速度：hf-mirror 对本仓库仅 ~0.3MB/s（20GB 要 18h+）；ModelScope 单连接
#       ~10.5MB/s（~31min），故选 ModelScope（lim 无 sudo 装不了 aria2c）。
D=/data/huggingface-downloads/Inkling-2-Mini
mkdir -p "$D"
python3 -c "from modelscope import snapshot_download; snapshot_download('thinkingmachines/Inkling-2-Mini', local_dir='$D')"

# 校验：文件大小与 HF API tree 逐一比对一致（见下表）；
#       完整性以 vllm nightly 就位后的加载 + 首跑验证
ls -l "$D"
```

| 文件 | 字节 | 说明 |
| --- | ---: | --- |
| `model-00001-of-00001.safetensors` | 19,526,019,168 | 权重（NVFP4，modelopt） |
| `mtp.safetensors` | 635,801,416 | DSpark 投机草稿 |
| `tokenizer.json` | 26,178,678 | 分词器（tiktoken，词表 200,058） |
| 其余 11 个文件 | ~140,000 | config / chat_template / 量化配置 / README 等 |

* 模型：`thinkingmachines/Inkling-2-Mini`（HF 原仓库；ModelScope 为等大小镜像，
  多一个 `configuration.json`）。
* 目录：`/data/huggingface-downloads/Inkling-2-Mini/`。
* 账本：合计 20,191,646,235 字节（~20.2GB）；单卡 96G PRO6000
  （条目 `inkling-2-mini-fp4-262k`，GPU 3）：权重 19.5G + mtp 0.6G +
  262k KV ~48G（bf16）≈ 68G。
* 实测：2026-11-26 20:09–20:43 完成（~34min，单连接均速 ~10MB/s）；16 个文件
  大小与 HF API tree 逐一比对一致（ModelScope 多 `configuration.json` 76B，
  `.gitattributes` 为镜像版 2075B vs HF 1570B）。

```
# PC Qwen3.6 MoE
hf download --local-dir ./Qwen3.6-35B-A3B-MTP unsloth/Qwen3.6-35B-A3B-MTP-GGUF \
    Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf mmproj-F16.gguf
hf download --local-dir ./Qwen3.6-35B-A3B unsloth/Qwen3.6-35B-A3B-GGUF \
    Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf Qwen3.6-35B-A3B-UD-IQ4_XS.gguf mmproj-F16.gguf

hf download --local-dir ./Qwen3.6-35B-A3B mradermacher/Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V11-dequantized-i1-GGUF \
    Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V11-dequantized.i1-IQ3_S.gguf \
    Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V11-dequantized.i1-IQ4_XS.gguf
hf download --local-dir ./Qwen3.6-35B-A3B mradermacher/Qwen3.6-35B-A3B-uncensored-heretic-i1-GGUF \
    Qwen3.6-35B-A3B-uncensored-heretic.i1-IQ4_XS.gguf
hf download --local-dir ./Qwen3.6-35B-A3B HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive \
    Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-IQ4_XS.gguf
hf download --local-dir ./Qwen3.6-35B-A3B mradermacher/Huihui-Qwen3.6-35B-A3B-Claude-4.7-Opus-abliterated-i1-GGUF \
    Huihui-Qwen3.6-35B-A3B-Claude-4.7-Opus-abliterated.i1-IQ3_XS.gguf \
    Huihui-Qwen3.6-35B-A3B-Claude-4.7-Opus-abliterated.i1-IQ4_XS.gguf
```

```
# PC Gemma4 MoE
hf download --local-dir ./Gemma4-26B-A4B unsloth/gemma-4-26B-A4B-it-GGUF \
    gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf mmproj-F16.gguf
hf download --local-dir ./Gemma4-26B-A4B unsloth/gemma-4-26B-A4B-it-GGUF \
    gemma-4-26B-A4B-it-UD-IQ3_XXS.gguf gemma-4-26B-A4B-it-UD-IQ4_XS.gguf
hf download --local-dir ./Gemma4-26B-A4B mradermacher/gemma-4-26B-A4B-it-ultra-uncensored-heretic-i1-GGUF \
    gemma-4-26B-A4B-it-ultra-uncensored-heretic.i1-IQ3_XS.gguf \
    gemma-4-26B-A4B-it-ultra-uncensored-heretic.i1-IQ4_XS.gguf
```

```
# Toy
hf download --local-dir ./Toy unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF \
    DeepSeek-R1-Distill-Qwen-1.5B-UD-Q4_K_XL.gguf
hf download --local-dir ./Toy mradermacher/DeepSeek-R1-Distill-Qwen-1.5B-uncensored-GGUF \
    DeepSeek-R1-Distill-Qwen-1.5B-uncensored.Q4_K_M.gguf

hf download --local-dir ./Toy unsloth/Llama-3.2-3B-Instruct-GGUF \
    Llama-3.2-3B-Instruct-Q4_K_M.gguf Llama-3.2-3B-Instruct-IQ4_NL.gguf Llama-3.2-3B-Instruct-IQ4_XS.gguf
hf download --local-dir ./Toy bartowski/Llama-3.2-3B-Instruct-uncensored-GGUF \
    Llama-3.2-3B-Instruct-uncensored-Q4_K_M.gguf
hf download --local-dir ./Toy mradermacher/Llama-3.2-3B-Uncensored-i1-GGUF \
    Llama-3.2-3B-Uncensored.i1-IQ4_XS.gguf Llama-3.2-3B-Uncensored.i1-IQ4_NL.gguf
hf download --local-dir ./Toy mradermacher/Llama-3.2-3B-Instruct-uncensored-GGUF \
    Llama-3.2-3B-Instruct-uncensored.IQ4_XS.gguf

hf download --local-dir ./Toy Smoffyy/Qwen3.5-4B-Instruct-Revised-GGUF \
    Qwen3.5-4B-Revised-q4_k_m.gguf mmproj-f16.gguf
hf download --local-dir ./Toy mradermacher/Qwen3.5-4B-Claude-4.6-OS-Auto-Variable-HERETIC-UNCENSORED-THINKING-GGUF \
    Qwen3.5-4B-Claude-4.6-OS-Auto-Variable-HERETIC-UNCENSORED-THINKING.Q4_K_M.gguf \
    Qwen3.5-4B-Claude-4.6-OS-Auto-Variable-HERETIC-UNCENSORED-THINKING.mmproj-Q8_0.gguf

hf download --local-dir ./Toy GnLOLot/MiniCPM5-1B-Claude-Opus-Fable5-V2-Thinking-GGUF \
    MiniCPM5-1B-Claude-Opus-Fable5-V2-Thinking-Q8_0.gguf

hf download --local-dir ./Toy LiquidAI/LFM2.5-2.6B-GGUF LFM2.5-2.6B-Q8_0.gguf
hf download --local-dir ./Toy unsloth/LFM2.5-1.2B-Instruct-GGU LFM2.5-1.2B-Instruct-UD-Q8_K_XL.gguf
```

```
# Embedding
hf download --local-dir ./Embedding ggml-org/embeddinggemma-300m-GGUF \
    embeddinggemma-300M-Q8_0.gguf
hf download --local-dir ./Embedding batiai/Qwen3-VL-Embedding-2B-GGUF \
    Qwen3-VL-Embedding-2B-Q8_0.gguf
```

```
hf download --local-dir ./Z-Image-Turbo hf://unsloth/Z-Image-Turbo-GGUF/z-image-turbo-Q4_K_M.gguf
hf download --local-dir ./Z-Image-Turbo hf://unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
hf download --local-dir ./Z-Image-Turbo hf://black-forest-labs/FLUX.1-schnell/ae.safetensors
```


## Chat-Templates

注意：可能会影响 pp、tg 速度，或 MTP draft 接受率下降。

1. <https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates>
   + v22.5: `chat_template.jinja`
   + `--reasoning-format deepseek` matters.
   + [recommend temperature](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates/discussions/100)

2. <https://huggingface.co/peculiar-ragdoll/Qwen-Sharp-Chat-Templates>
   + based on `froggeric/Qwen-Fixed-Chat-Templates`
   + v22.5.0: `chat_template.jinja`

```
hf download --local-dir ./Qwen-chat-templates hf://froggeric/Qwen-Fixed-Chat-Templates/chat_template.jinja
mv ./Qwen-chat-templates/{chat_template.jinja,froggeric-v22.5.jinja}

hf download --local-dir ./Qwen-chat-templates hf://peculiar-ragdoll/Qwen-Sharp-Chat-Templates/chat_template.jinja
mv ./Qwen-chat-templates/{chat_template.jinja,,peculiar-ragdoll-v22.5.0.jinja}
```
