# LLM models

## ref

* <https://gemma4-ai.com/zh/blog/best-local-ai-models-2026>
* <https://jimmysong.io/zh/book/ai-handbook/llm/model-selection/>
* <https://www.siliconflow.com/articles/zh-Hans/best-small-LLMs-under-10B-parameters>
* MTP <https://github.com/ggml-org/llama.cpp/pull/22673>

| 量化类型 | 性能特点 | 适用场景 |
| -------- | -------- | -------- |
| IQ4_XS   | 同等大小下，IQ 格式的智商显著高于 Q 格式 | 硬件受限时，简单的日常写作 |
| Q4_K_M   | 速度和精度兼顾, 资源占用适中 | 合日常对话、写作、通用任务 |
| UD-Q4_K_XL | 质量优先, Unsloth 动态量化技术, XL 比 M 多占一点内存 | 4-bit 追求高性能时的首选 |
| Q5_K / Q8_K | 更高精度，资源占用增加 | 高质量生成, 适合性能更好的服务器 |

* UD前缀 (Unsloth Dynamic) : 为模型的不同部分（如注意力层）选择合适的量化位宽，保持模型大小不变，将资源用在刀刃上
* K (K-quantization/grouped quantization)：表示采用分组量化和K-Means聚类的高级策略，这是llama.cpp的主流方式，能更好地保留模型表现
* XXS、XS (Extra Small)、S (Small)、M (Medium)、XL (Extra Large)：代表混合精度策略的程度
* IQ (Importance Matrix Quantization) : 重要性矩阵（imatrix）量化，第二代更聪明的量化。算法会测一遍模型，找出重要参数（不砍），不重要参数（可多砍）。

## hf account & token

* 说明:
  - <https://hf-mirror.com/docs/hub/rate-limits>
  - <https://hf-mirror.com/login>
* https://huggingface.co/settings/tokens
  - READ Token, download: `hf_xxxxx`
* 镜像 `export HF_ENDPOINT=https://hf-mirror.com`

```
pip install --upgrade huggingface_hub
hf auth login # need proxychains ?
hf auth list
hf download  # 下载模型
hf download --local-dir XXX  REPO_ID [FILENAMES]
```

* 国内 https://modelscope.cn/
```
pip install modelscope
ms download  # 代替 hf download
```


## pick models

1. Dense, Qwen3.8, Alibaba Cloud, Text, Image + Video
   - 擅长代码
   - <https://huggingface.co/unsloth/Qwen3.8-27B-GGUF>
     + `Qwen3.8-27B-UD-Q8_K_XL.gguf`, `mmproj-BF16.gguf`

2. MoE, Qwen3.8 Flash Next, Alibaba Cloud, qwen4 实验新架构
   - <https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF>
     + `Qwen3.8-Flash-Next-UD-IQ4_XS-0000{1,2,3}-of-00003.gguf`, `mmproj-F16.gguf`


3. MoE, Qwen3.6, Alibaba Cloud, Text + Image + Video
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

4. MoE, Gemma4, Google DeepMind, Text + Image
   - 听/视觉, 写作和语气
   - <https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF>
     + `gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf`, `mmproj-BF16.gguf`
     + `gemma-4-26B-A4B-it-UD-IQ3_XXS.gguf`, `gemma-4-26B-A4B-it-UD-IQ4_XS.gguf`
     + `mtp-gemma-4-26B-A4B-it.gguf`
   - <https://huggingface.co/mradermacher/gemma-4-26B-A4B-it-ultra-uncensored-heretic-i1-GGUF>
     + `gemma-4-26B-A4B-it-ultra-uncensored-heretic.i1-IQ3_XS.gguf`
     + `gemma-4-26B-A4B-it-ultra-uncensored-heretic.i1-IQ4_XS.gguf`


5. Toy, 小模型
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


6. Embedding model, 嵌入模型, RAG
   - Qwen3, VL, <https://huggingface.co/batiai/Qwen3-VL-Embedding-2B-GGUF>
   - `Qwen3-VL-Embedding-2B-Q8_0.gguf`
   - Gemma, <https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF>
   - `embeddinggemma-300M-Q8_0.gguf`


下载记录：

```
export HF_DEBUG=1
export HF_ENDPOINT=https://hf-mirror.com

# 服务器下载 Qwen3.8 稠密模型 Q8
hf download --local-dir ./Qwen3.8-27B unsloth/Qwen3.8-27B-GGUF \
    Qwen3.8-27B-UD-Q8_K_XL.gguf mmproj-BF16.gguf

# 服务器下载测试 Qwen3.8-Flash-Next 177B
hf download --local-dir ./Qwen3.8-Flash-Next unsloth/Qwen3.8-Flash-Next-GGUF \
    UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
    UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00002-of-00003.gguf \
    UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf \
    MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf \
    mmproj-F16.gguf

# 服务器下载 Qwen3.6 MoE模型 Q8
hf download --local-dir ./Qwen3.6-35B-A3B unsloth/Qwen3.6-35B-A3B-MTP-GGUF \
    Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf \
    mmproj-BF16.gguf
```

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


# llama.cpp

* 官网: <https://github.com/ggml-org/llama.cpp>
* 版本: latest

* 服务器: <https://aur.archlinux.org/packages/llama.cpp-cuda>
  - 编译 ./llama.cpp-cuda-sycl/PKGBUILD-cuda

* 笔记本: extra/llama-cpp 或 <https://aur.archlinux.org/packages/llama.cpp-vulkan-git> or <https://aur.archlinux.org/packages/llama.cpp-sycl>
  - CPU 版本最成熟 `pacman -S llama-cpp`
  - https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md
  - 编译 ./llama.cpp-cuda-sycl/PKGBUILD-sycl
  - note: sycl 依赖 intel oneapi, like
    + intel-oneapi-dpcpp-cpp, intel-compute-runtime
    + intel-oneapi-mkl-sycl, level-zero-headers, onednn
  - note: sycl 的 cmake options
    ```
        -DGGML_SYCL=ON \
        -DGGML_SYCL_F16=ON \
        -DCMAKE_C_COMPILER=icx \
        -DCMAKE_CXX_COMPILER=icpx \
    ```

* 运行测试: `llama-cli -m XX.gguf  --mmproj XX-mmproj-BF16.gguf`


# llama-swap

* 服务器
  - 配置文件: `llama-swap-config-PRO6000.yaml`
  - 服务器运行: `~/local-llama/llama-swap-start.sh -n PRO6000 -p 12435`
  - 本地端口映射: `ssh -Nv -L 127.0.0.1:12435:127.0.0.1:12435 hhf200.sans`

* 笔记本
  - 配置文件: `llama-swap-config-T14p.yaml`
  - systemd 服务: /etc/systemd/system/llama-swap.service.d/T14p.conf
    ```
    [Service]
    # 清空原始的 ExecStart 命令列表
    ExecStart=
    ExecStart=/usr/bin/llama-swap -config %E/llama-swap/llama-swap-config-T14p.yaml -watch-config -listen 0.0.0.0:12434
    ```
  - 或 `source /opt/intel/oneapi/setvars.sh` 后（后端是 SYCL 时），
    运行: `~/local-llama/llama-swap-start.sh -n T14p -p 12434`


# TTS

MOSS?
