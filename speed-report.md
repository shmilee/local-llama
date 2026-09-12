# PRO6000

## cmd

```
"default-llama": >
    ${env.HOME}/local-llama/bin/llama-server
    --port ${PORT}
    --n-gpu-layers all --device CUDA0
    --mmproj-offload
    --load-mode auto --flash-attn on --fit off
    --cache-type-k f16 --cache-type-v f16
    --kv-unified
    --ubatch-size 4096

${default-llama}
    --model ${models_dir}/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf
    --mmproj ${models_dir}/Qwen3.6-35B-A3B/mmproj-BF16.gguf
    --ctx-size ${ctx_256k}
    --cache-ram 12288
    --spec-type draft-mtp --spec-draft-n-max 3
```

```
${default-llama}
    --model ${models_dir}/Qwen3.8-27B/Qwen3.8-27B-UD-Q8_K_XL.gguf
    --mmproj ${models_dir}/Qwen3.8-27B/mmproj-BF16.gguf
    --ctx-size ${ctx_256k}
    --cache-ram 12288
    --spec-type draft-mtp --spec-draft-n-max 3
```

```
${env.HOME}/local-llama/bin/llama-server
    --model ${models_dir}/Qwen3.8-Flash-Next/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf
    --mmproj ${models_dir}/Qwen3.8-Flash-Next/mmproj-F16.gguf
    --port ${PORT}
    --n-gpu-layers all --device CUDA0
    --n-cpu-moe 0
    --mmproj-offload
    --load-mode mmap+mlock --flash-attn on --fit off
    --cache-type-k q8_0 --cache-type-v q8_0
    --kv-unified
    --ubatch-size 4096
    --cache-ram 12288
    --ctx-size ${ctx_256k}
```


## Memory

| model | GPU Memory | MemB |
| ----- | ---------- | ---- |
| Qwen3.6-35B-A3B | 47804MiB | 3.4G |
| Qwen3.8-27B     | 53092MiB | 4.1G |
| Qwen3.8-Flash-Next | 74434MiB | 31G |


## Qwen3.6-35B-A3B

| Summary | |
| --- | --- |
| Cached | 308 |
| Prompt | 1,702 (1607.66 t/s) |
| Generated | 6,498 (219.16 t/s) |
| Drafted | 63.8% 4269/6696 |

| ID | Time | Source/Caller | Status | Cached | Prompt | Generated | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | 2026-09-12 22:56:59 | ip:127.0.0.1 | 200 | 263 | 1,427 | 1,841 | 3876.40 t/s | 212.25 t/s | 9.37s |
| 3 | 2026-09-12 22:54:22 | ip:127.0.0.1 | 200 | 38 | 229 | 3,099 | 923.58 t/s | 222.75 t/s | 14.37s |
| 2 | 2026-09-12 22:53:34 | ip:127.0.0.1 | 200 | 7 | 35 | 767 | 148.18 t/s | 213.99 t/s | 3.93s |
| 1 | 2026-09-12 22:53:21 | ip:127.0.0.1 | 200 | - | 11 | 791 | 53.29 t/s | 227.38 t/s | 3.69s |


## Qwen3.8-27B

| Summary | |
| --- | --- |
| Cached | 641 |
| Prompt | 2,074 (738.69 t/s) |
| Generated | 8,033 (85.11 t/s) |
| Drafted | 67.8% 5387/7941 |

| ID | Time | Source/Caller | Status | Cached | Prompt | Generated | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 9 | 2026-09-12 23:07:33 | ip:127.0.0.1 | 200 | 266 | 1,792 | 250 | 2016.07 t/s | 75.41 t/s | 5.48s |
| 8 | 2026-09-12 23:05:36 | ip:127.0.0.1 | 200 | 248 | 22 | 3,443 | 48.31 t/s | 92.30 t/s | 39.24s |
| 7 | 2026-09-12 23:04:15 | ip:127.0.0.1 | 200 | 78 | 174 | 4,096 | 346.32 t/s | 80.59 t/s | 51.99s |
| 6 | 2026-09-12 23:03:19 | ip:127.0.0.1 | 200 | 49 | 33 | 195 | 76.07 t/s | 86.00 t/s | 2.70s |
| 5 | 2026-09-12 23:03:09 | ip:127.0.0.1 | 200 | - | 53 | 49 | 100.54 t/s | 73.16 t/s | 1.19s |


## Qwen3.8-Flash-Next

| Summary | |
| --- | --- |
| Cached | 2,810 |
| Prompt | 2,887 (1147.23 t/s) |
| Generated | 3,870 (91.62 t/s) |
| Drafted | - |

| ID | Time | Source/Caller | Status | Cached | Prompt | Generated | Prefill | Decode | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 14 | 2026-09-12 23:20:34 | ip:127.0.0.1 | 200 | 2,685 | 59 | 1,048 | 184.74 t/s | 90.69 t/s | 11.89s |
| 13 | 2026-09-12 23:19:40 | ip:127.0.0.1 | 200 | - | 2,689 | 77 | 2499.27 t/s | 89.13 t/s | 2.66s |
| 12 | 2026-09-12 23:17:19 | ip:127.0.0.1 | 200 | 76 | 55 | 2,622 | 176.78 t/s | 92.17 t/s | 28.77s |
| 11 | 2026-09-12 23:16:47 | ip:127.0.0.1 | 200 | 49 | 31 | 74 | 97.92 t/s | 90.45 t/s | 1.13s |
| 10 | 2026-09-12 23:16:28 | ip:127.0.0.1 | 200 | - | 53 | 49 | 107.40 t/s | 88.14 t/s | 1.05s |


# T14p

## Vulkan vs SYCL

build: ebe8fba (9496) w/ **Vulkan**
device: Intel(R) Arc(tm) Graphics (MTL) (Intel open-source Mesa driver) | uma: 1 | fp16: 1 | bf16: 0 | warp size: 32 | shared memory: 49152 | int dot: 1 | matrix cores: none

| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | Vulkan     |   0 |           pp512 |       588.46 ± 11.97 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | Vulkan     |   0 |           tg128 |         12.72 ± 0.13 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | Vulkan     |  16 |           pp512 |        734.26 ± 0.91 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | Vulkan     |  16 |           tg128 |         16.45 ± 1.45 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | Vulkan     | 999 |           pp512 |        920.90 ± 7.50 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | Vulkan     | 999 |           tg128 |         37.45 ± 0.44 |
| qwen35 4B Q4_K - Medium        |   2.51 GiB |     4.21 B | Vulkan     | 999 |           pp512 |        247.96 ± 8.84 |
| qwen35 4B Q4_K - Medium        |   2.51 GiB |     4.21 B | Vulkan     | 999 |           tg128 |         16.97 ± 0.12 |
| gemma4 26B.A4B Q4_K - Medium   |  15.83 GiB |    25.23 B | Vulkan     |   8 |           pp512 |         82.62 ± 1.09 |
| gemma4 26B.A4B Q4_K - Medium   |  15.83 GiB |    25.23 B | Vulkan     |   8 |           tg128 |          2.72 ± 0.01 |
| gemma4 26B.A4B Q4_K - Medium   |  15.83 GiB |    25.23 B | Vulkan     | 999 |           pp512 |        135.99 ± 2.19 |
| gemma4 26B.A4B Q4_K - Medium   |  15.83 GiB |    25.23 B | Vulkan     | 999 |           tg128 |         12.66 ± 0.38 |

build: unknown (9934) w/ **SYCL**

| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | SYCL       |   0 |           pp512 |        599.20 ± 1.70 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | SYCL       |   0 |           tg128 |         42.06 ± 0.20 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | SYCL       |  16 |           pp512 |       638.48 ± 18.31 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | SYCL       |  16 |           tg128 |         32.42 ± 0.30 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | SYCL       | 999 |           pp512 |        747.86 ± 1.92 |
| qwen2 1.5B Q4_K - Medium       |   1.10 GiB |     1.78 B | SYCL       | 999 |           tg128 |         40.54 ± 0.07 |
| qwen35 4B Q4_K - Medium        |   2.51 GiB |     4.21 B | SYCL       | 999 |           pp512 |        340.53 ± 0.49 |
| qwen35 4B Q4_K - Medium        |   2.51 GiB |     4.21 B | SYCL       | 999 |           tg128 |         14.73 ± 0.11 |
| gemma4 26B.A4B Q4_K - Medium   |  15.83 GiB |    25.23 B | SYCL       |   8 |           pp512 |         65.21 ± 3.42 |
| gemma4 26B.A4B Q4_K - Medium   |  15.83 GiB |    25.23 B | SYCL       |   8 |           tg128 |         11.81 ± 0.03 |
| gemma4 26B.A4B Q4_K - Medium   |  15.83 GiB |    25.23 B | SYCL       | 999 |           pp512 |         97.72 ± 5.72 |
| gemma4 26B.A4B Q4_K - Medium   |  15.83 GiB |    25.23 B | SYCL       | 999 |           tg128 |         12.47 ± 0.38 |


## IQ3 or IQ4 for CPU

```
"latest-llama":
    taskset -c 0-7 /usr/bin/llama-server --threads 8 --port 10003 \
    --no-mmproj-offload --device none --mmap --flash-attn on --fit off \
    --cache-type-k q8_0 --cache-type-v q8_0 --kv-unified --ubatch-size 4096
```

### Qwen3.6 35B-A3B

```
${latest-llama}:
    ${latest-llama} --mmproj ./Qwen3.6-35B-A3B/mmproj-F16.gguf --model ${Qwen_35B_gf}\
    --ctx-size ${ctx_32k} --reasoning on --reasoning-budget 2048

  # unsloth
  # pp:  21.35  24.62  24.51 t/s
  # tg:  12.40  11.62  10.94 t/s
  #"Qwen_35B_gf": "Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf"
  #
  # pp:  20.35  23.09  25.33 t/s
  # tg:  11.62  10.56  11.29 t/s
  #"Qwen_35B_gf": "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"

  # mradermacher V11
  # pp:  14.5  16.08  14.81 t/s
  # tg:   9.9   9.96  10.56 t/s
  #"Qwen_35B_gf": "Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V11-dequantized.i1-IQ3_S.gguf"
  #
  # 续写时有问题, 可能模板太繁琐
  # pp:  27.13  24.56  31.96  21.94 t/s
  # tg:  13.43  14.65  13.77  13.05 t/s
  #"Qwen_35B_gf": "Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V11-dequantized.i1-IQ4_XS.gguf"

  # mradermacher
  # 续写时有问题
  # pp:  37.92  44.59  57.45  24.82 t/s
  # tg:  14.62  14.56  14.09  14.74 t/s
  #"Qwen_35B_gf": "Qwen3.6-35B-A3B-uncensored-heretic.i1-IQ4_XS.gguf"

  # HauhauCS
  # 速度略慢，格式偶尔出现混乱，也会停不下来
  # pp:  34.44  25.83  25.13  45.75 t/s
  # tg:  14.55  13.64  14.40  13.01 t/s
  #"Qwen_35B_gf": "Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-IQ4_XS.gguf"

  # mradermacher + Huihui
  # 思考简短, 但 IQ3 比 IQ4 慢，反常
  # pp:  45.76  24.72  51.81 t/s
  # tg:  10.64  10.84  10.79 t/s
  #"Qwen_35B_gf": "Huihui-Qwen3.6-35B-A3B-Claude-4.7-Opus-abliterated.i1-IQ3_XS.gguf"
  #
  # 思考简短，回答快速
  # pp:  41.04  55.56  56.13  55.44  31.42  57.18 t/s
  # tg:  14.60  14.40  14.08  14.14  14.83  13.16 t/s
  "Qwen_35B_gf": "Huihui-Qwen3.6-35B-A3B-Claude-4.7-Opus-abliterated.i1-IQ4_XS.gguf"
```

### gemma4 26B-A4B

```
${latest-llama}:
    ${latest-llama} --model ${models_dir}/Gemma4-26B-A4B/${gemma_26B_gf}
    --ctx-size ${ctx_32k} --reasoning on --reasoning-budget 2048

  # unsloth
  # pp:  22.76  24.82 23.98 t/s
  # tg:  12.79  10.82 11.10 t/s
  #"gemma_26B_gf": "gemma-4-26B-A4B-it-UD-IQ3_XXS.gguf"
  #
  # pp:  19.92  21.06  21.18 t/s
  # tg:  10.80   9.51  10.41 t/s
  #"gemma_26B_gf": "gemma-4-26B-A4B-it-UD-IQ4_XS.gguf"

  # mradermacher + llmfan46  
  # pp:  14.51  15.09  13.81 t/s
  # tg:  10.32   9.14  10.37 t/s
  #"gemma_26B_gf": "gemma-4-26B-A4B-it-ultra-uncensored-heretic.i1-IQ3_XS.gguf"
  #
  # 最快
  # pp:  25.82  28.96  30.12 t/s
  # tg:  15.65  13.27  14.28 t/s
  "gemma_26B_gf": "gemma-4-26B-A4B-it-ultra-uncensored-heretic.i1-IQ4_XS.gguf"
```

## Toy

### llama 3B

```
${latest-llama}:
      ${latest-llama} --model ${models_dir}/Toy/${toyA_gf}
      --ctx-size ${ctx_32k}

  # unsloth
  # pp:  60.07  57.94  45.65 t/s
  # tg:  22.62  22.25  19.82 t/s
  #"toyA_gf": "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
  #
  # pp:  32.69  32.24  31.43 t/s
  # tg:  22.58  22.29  21.62 t/s
  #"toyA_gf": "Llama-3.2-3B-Instruct-IQ4_XS.gguf"
  #
  # pp:  70.35  65.46  52.16 t/s
  # tg:  24.35  23.60  22.18 t/s
  #"toyA_gf": "Llama-3.2-3B-Instruct-IQ4_NL.gguf"

  # bartowski
  # pp:  45.23  47.37  45.70 t/s
  # tg:  20.93  21.78  20.52 t/s
  #"toyA_gf": "Llama-3.2-3B-Instruct-uncensored-Q4_K_M.gguf"

  # mradermacher
  # pp:  31.87  30.35  32.33 t/s
  # tg:  22.40  20.39  21.67 t/s
  #"toyA_gf": "Llama-3.2-3B-Uncensored.i1-IQ4_XS.gguf"
  #
  # pp:  67.28  64.58  60.15 t/s
  # tg:  22.63  20.91  20.76 t/s
  #"toy1_gf": "Llama-3.2-3B-Instruct-uncensored.IQ4_XS.gguf"
  #
  # 最快
  # pp:  76.61  58.21  55.96 t/s
  # tg:  22.37  22.49  22.58 t/s
  "toyA_gf": "Llama-3.2-3B-Uncensored.i1-IQ4_NL.gguf"
```

### MiniCPM5

```
  # GnLOLot
  # pp:  149.58  129.30  153.15  149.61 t/s
  # tg:   40.86   40.37   43.97   44.06 t/s
  "toyB_gf": "MiniCPM5-1B-Claude-Opus-Fable5-V2-Thinking-Q8_0.gguf"
```

### LiquidAI LFM2.5

```
  # LiquidAI
  # think 模板有问题，与回答输出混一起
  # pp:  39.63  45.10  43.78 t/s
  # tg:  17.63  17.55  16.72 t/s
  #"toyC_gf": "LFM2.5-2.6B-Q8_0.gguf"
  #
  # pp:  88.4  91.80  94.05 t/s
  # tg:  36.6  34.69  36.38 t/s
  #"toyC_gf": "LFM2.5-1.2B-Thinking-UD-Q8_K_XL.gguf"
```
