# Project Maya（CUDA 环境）

## 测试纪律（2026-11-24）

* hhf200 的 `~/local-llama` 是**生产**：只读。不改它的 llama-swap config，也不 reload
  （reload 会停掉在跑的模型，包括 GPU 2 上的 27B vLLM 和 GPU 7 的 strata Qwen）。
* 测试用独立目录 `~/maya-test/` + 独立 llama-swap 实例（`127.0.0.1:18435`，
  `startPort: 16100`，独立 DB），只分配 **GPU 4,6**；绝不使用 GPU 2 / GPU 7。
* 不按全局名字 `pkill`（会误杀依赖它的 shell/生产进程）；按 PID 精确停。
* 生产 config 里暂时保留了 `glm-5.3-flash-q3-1m` 条目，但模型未加载；
  移除它需要一次 reload（会中断 27B），留到维护窗口做。

`maya-cuda` 环境：从源码构建 [Project Maya](https://github.com/mw00/project-maya)
的推理引擎与 Python 服务，跑 **GLM-5.3-Flash / DeepSeek-V4.1-Flash / MiniMax-M3.1-Flash /
Hy4-Flash**。上游从 v0.2.14 起不再支持 DeepSeek，Maya 是同一血脉的维护主线
（Strata 的 `strata-dsv41` 就是 Maya `maya-ds4` 的移植版，见 `docs/strata.md`）。

| 模型 | 引擎 | 模型格式 |
| ---- | ---- | -------- |
| GLM-5.3-Flash / GLM-5.3 / Qwen3.8-Flash-Next | `maya`（主引擎） | Maya GGUF / 社区 GGUF（glm5-next）/ EXL3（`--glm-pack` pack） |
| DeepSeek-V4.1-Flash-1017 | `maya-ds4` | Maya GGUF / Unsloth GGUF / EXL3（`--pack` pack） |
| MiniMax-M3.1-Flash | `maya-mm3`（本环境不构建） | Maya/EXL3 |
| Hy4-Flash | `maya-hy4`（本环境不构建） | Maya GGUF + n-gram 表（需 NVMe） |

**模型格式互不通用**：Strata 的 ISTA-DAS GSQ-RCO 文件 Maya 读不了；Maya 的 pack 也
只有 Maya 引擎能读。DeepSeek 要换 Maya 必须重新下载模型。

## 环境与构建

```
pixi install -e maya-cuda                 # conda 工具链 + CUDA 13.2 + Python 服务依赖
pixi run -e maya-cuda maya-build          # 下载源码 + 编译 + 安装（首次 ~20-30 分钟）
pixi run -e maya-cuda maya-verify         # 二进制/GPU/依赖/自检
pixi run -e maya-cuda maya-path           # -> $CONDA_PREFIX/bin/maya
```

* 版本 pin：`MAYA_VERSION=v1.1.76`（`pixi.toml` 的 `maya-base`）；引擎 `--version`
  显示 release + tag 的 commit（`BUILD_ID`，tarball 无 `.git`）。
* ggml 来自 llama.cpp pin `3cf03257f219afbe7334045ff7c6a06ac68c627d`
  （`maya-src.sh` 预取，`maya-build.sh` 用 `-DMAYA_GGML_DIR` 指过去；与 `strata-cuda`
  是同一个 commit，可共用 `download/llama.cpp-3cf03257f219`）。
* 只构建三个产物：`maya`（GLM 主引擎）、`maya-ds4`（DeepSeek）、`strata-device`（诊断）。
  MiniMax/Hy4 的引擎不构建。
* 安装布局（`$CONDA_PREFIX`）：
  ```
  maya/                       整棵源码树（maya.py / serve / tools / data / src / ...）
  maya/build/maya             GLM 主引擎
  maya/build/maya-ds4         DeepSeek 引擎
  maya/build/strata-device    GPU 诊断/自检
  bin/maya                    Python 服务启动器（环境 python3 + maya.py）
  bin/maya-engine -> ../maya/build/maya
  bin/maya-ds4    -> ../maya/build/maya-ds4
  bin/strata-device -> ../maya/build/strata-device
  ```
* 不写 `maya/build/MAYA-BUILD.json`：`maya.py` 启动时看到没有 stamp 就不触发重编译；
  升级走 `pixi`（改 `MAYA_VERSION` → 重跑 `maya-build`）。

### 环境变量（pixi 激活时设置）

| 变量 | 作用 |
| ---- | ---- |
| `MAYA_SH=1` | **必须**。conda python 的 `sys.prefix == sys.base_prefix`，`maya.py` 会 exec `maya.sh` 自建 `.venv` 并丢掉 pixi 的包；`MAYA_SH=1` 跳过这条分支 |
| `CPATH=$CONDA_PREFIX/lib/python3.12/site-packages/nvidia/cu13/include` | `nvtx3/nvToolsExt.h`（conda 的 `cuda-nvtx` 只有 `.so`，头文件来自 pypi `nvidia-nvtx==13.2.86`） |
| `MAYA_UPDATE_CHECK=0` | 版本由 pixi 管；本机 GitHub 不可达，关掉 dashboard 的更新检查 |
| `PYTHONPATH=$CONDA_PREFIX/maya` | `maya.py` / `serve` / `tools` 的导入根 |

## 模型下载与 pack

下载记录（仓库、文件、sha256）在 `docs/models.md`「下载记录」。模型目录统一在
`/data/huggingface-downloads/<repo>/`。

```
# GLM-5.3-Flash · Unsloth UD-Q3_K_XL（147.5GB；ModelScope 镜像）
/data/huggingface-downloads/GLM-5.3-Flash-GGUF/UD-Q3_K_XL/*.gguf

# 生成 pack（GLM：<模型目录>/pack，~几分钟）
pixi run -e maya-cuda maya-pack glm /data/huggingface-downloads/GLM-5.3-Flash-GGUF/UD-Q3_K_XL

# DeepSeek（将来）：Maya-S / Maya-XS，产 <模型目录>/maya-ds4
pixi run -e maya-cuda maya-pack ds4 /data/huggingface-downloads/DeepSeek-V4.1-Flash-1017-Maya-GGUF/Maya-S
```

* pack 必须和模型文件同目录（引擎从 `<pack>/..` 找 GGUF；`pack_gguf.py` 的
  `tensors.txt` 用相对路径）。模型目录须可写。
* GLM pack 用 `tools/iq_pack.py --compat-bf16`（Maya 自家、Unsloth 及其它 glm5-next
  社区 GGUF 都走这条路；社区量化属实验性，Maya 未做质量实测）；DeepSeek pack 用
  `tools/ds4/pack_gguf.py`（Maya GGUF 的 Engram 表在同一个 split 里）。
* GLM pack 会自动复制 `data/expert-profile-glm.bin` 作为初始专家放置表；
  DeepSeek 的 `expert-profile-ds4.bin` 同规则（服务启动时也会补）。
* 想重建：`maya-pack glm <dir> --force`。

## 其它家的 GLM-5.3-Flash 量化（Maya 支持情况）

| 来源 | 量化 / 大小 | Maya 支持 | 下载源 |
| ---- | ----------- | --------- | ------ |
| **unsloth/GLM-5.3-Flash-GGUF** | UD-Q3_K_XL 147.5GB（本次）、UD-IQ3_XXS 120.4GB、UD-IQ2_XXS 101.8GB、UD-Q4_K_XL 199.7GB、Q5/Q6/Q8 240-341GB | **支持（实验）**：`--gguf-dir` + `tools/iq_pack.py`；架构 `glm5-next`，`--compat-bf16` 处理高精度张量 | ModelScope 有镜像，`aria2c -x16` 实测 ~87-94MB/s |
| **peasantsmith/…-Maya-GGUF**（Maya 自家） | Maya-S 96.5GB、Maya-M 116GB、Maya-XS 73.4GB、Maya-L 156.3GB | 官方默认；质量有实测（Maya-M 97.9% FP8） | HF（hf-mirror 实测 ~5MB/s，太慢） |
| **turboderp/GLM-5.3-Flash-exl3** | 3.05bpw 125.3GB、4.05bpw 165.2GB、sc_4.10bpw 167.8GB | **官方支持**：`--model EXL3-3.05bpw` / `--model-dir`，直接读 safetensors（无需 GGUF pack），V100+ | HF（ModelScope 仓库只有 cal_trace，量化文件未镜像） |
| zai-org/GLM-5.3-Flash | FP8 / BF16 原版 | **不支持**：Maya 只吃 GGUF / EXL3 | - |
| bartowski / mradermacher / QuantStack 等 | 各家 GGUF | **实验**：只要 arch 是 `glm5-next` / `glm5next`，理论上都能 `iq_pack`；未实测 | 视镜像 |

结论（本次）：**Unsloth UD-Q3_K_XL 147.5GB** 是速度/质量/显存三者最平衡的可用项；
147.5GB 在 2×96G（~205GB）上能 100% 专家驻显存，且 ModelScope 下载只要 ~30 分钟。
Maya 自家 Maya-M 质量更好一点（专家 2-3 bit + Q6_K attention），但下载源太慢，留作后续。

## 实测（2026-11-24，2×PRO6000 96G，GPU 4,6，≤100G 主机内存）

| 项 | 数值 |
| --- | --- |
| 模型 | GLM-5.3-Flash · Unsloth UD-Q3_K_XL（147.5GB） |
| pack | `iq_pack.py --compat-bf16`，15 秒；pack 只写索引 + 0.88GiB dense，专家仍从 GGUF 读 |
| 首载 | 手动 ~14 分钟；llama-swap 首次请求 858s（14.3 分钟，HDD 200MB/s） |
| 显存 | 2 卡各 ~96G 用满；专家 100% 在 VRAM（llama-swap 启动的 auto split：层 0-23 / 24-44，预测 4.2/4.1 ms/token） |
| 主机内存 | 加载峰值 RSS ~47.7GB；稳态 **~14.8GB**（页缓存另算，系统 `available` 仍 ~150G） |
| decode | 手动 512 token 64.9 tok/s（97.7% VRAM）；**llama-swap 热态 256 token 71.3 tok/s**（14.02 ms/tok，**100% VRAM 命中**，RAM/磁盘 0；MTP 草稿 15/25 接受） |
| 首 token | 17 token prompt ~1.8s（含冷启动/固定开销）；短 prompt 主要吃固定开销 |
| API | `/health`、`/v1/models`、`/v1/chat/completions`、`/v1/messages` 正常；llama-swap 条目 `glm-5.3-flash-q3-1m` 已列出并端到端跑通（OpenAI 请求 200） |
| 备注 | 第一次手动启动 auto split 偏斜（99.2/38.6GB 专家池，97.7% VRAM 命中）；llama-swap 启动时自动分到 24/21 层、100% VRAM。auto 受启动时显存状态影响，正式配置建议显式 `layer_split` 并做一次 A/B（当前 58-65 tok/s 的差异在短样本内） |

### 长上下文 prefill（1M ctx，GPU 4,6，UD-Q3_K_XL）

| prompt tokens | 引擎读 prompt | prefill | decode |
| ---: | ---: | ---: | ---: |
| 210,572 | 42.0s | 5,013 tok/s | — |
| 421,231 | 89.1s | 4,727 tok/s | 40.6 tok/s（421K 上下文，32 token 样本） |
| 741,123 | 180.2s | 4,128 tok/s | 56.0 tok/s（741K，32 token 样本） |
| 98845（对照） | 19.3s | 5,046 tok/s | — |

* `--max-context 1048576` 启动成功，`/health` 报 `max_context: 1048576`；
  1M 的 KV 在主机侧约 12GB（KV streaming），2 卡显存仍 100% 专家驻留。
* 1M 下 740K prompt 的 prefill 仍有 4.1K tok/s；decode 40-56 tok/s（样本短，噪声大）。
* 日常建议：512K 是甜点（prefill 4.7K、KV ~6GB、decode ~41）；1M 适合一次性长任务。

### 长上下文 decode 调优 A/B（1M ctx，GPU 4,6，32-token 样本）

| 设置 | 421K decode | 741K decode | prefill |
| --- | ---: | ---: | ---: |
| **当前（auto→24/21，KV streaming on，MTP on）** | **40.6 tok/s** | **56.0 tok/s** | 4.7K / 4.1K |
| `MAYA_GLM_SHEXP_SIDE=1` | 38.5 | 41.2 | 4.7K / 4.1K |
| `MAYA_GLM_NO_MTP=1` | 36.3 | 40.9 | 4.7K / 4.1K |
| `--kv-streaming off`（KV 全放显存） | 38.9 | 48.5 | 4.7K / 4.2K |

* 三个“优化”都没有明显增益，SHEXP side 与 MTP off 反而略慢；MTP 在长上下文接受率仍有
  **70–77%**（`glm spec: 21 of 30` / `23 of 30`），保留 MTP。
* 分层：1M 启动时 auto 仍选 **24/21**（预测 4.2/4.1 ms，303 slots/layer，100% 专家在 VRAM）；
  config 里固定 `MAYA_GLM_SPLIT=24` 只是避免启动时偶发分到 30/15，不是性能调优。
* 32-token 样本噪声较大（例如 741K 的 56 可能是上偏）；但没有任何设置显示出 >5% 的稳定增益，
  按“没明显增益就保持现状”处理。

## 启动服务

`maya.py` 是 OpenAI + Anthropic 兼容服务（chat template、tokenizer、工具调用、
思考等级都在这一层），引擎是它的子进程。

```
# GLM-5.3-Flash · UD-Q3_K_XL（run config: config/maya-glm.json）
pixi run -e maya-cuda maya --config config/maya-glm.json --port 18080
```

* `config/maya-glm.json` 固定 GPU 4,6、**1M 上下文**（实测 740K prompt 可读）、`web_ui:false`；
  `--port` 覆盖配置里的端口（llama-swap 用 `${PORT}`）。
* 端点：`/health`、`/v1/models`、`/v1/chat/completions`、`/v1/messages`
  （Anthropic）。API key 默认不要求（llama-swap 在入口做鉴权）。
* 启动会加载模型、按路由频率放置专家：日志 `logs/maya-glm.log`；
  看进度用 `tail -f`、`nvidia-smi`、`ps -o rss`。
* **内存预算**：本机约定 2 卡 + 主机内存 ≤100GB。UD-Q3_K_XL 147.5GB，
  2×PRO6000 96G（~205GB 可用）余 ~57GB，主机侧主要吃 KV
  （128K 约 1.6GB、512K 约 6GB、1M 约 12GB，KV streaming 开）和页缓存。启动后核对：
  ```
  ps -o pid,rss,args -C maya
  free -g
  nvidia-smi --query-gpu=index,memory.used --format=csv
  ```
* 停止：Ctrl+C / `kill`（SIGTERM 会收敛成 KeyboardInterrupt，服务与引擎一起退出）。

### llama-swap 集成

宏与条目在 `config/llama-swap-config-PRO6000.yaml`：

```
"default-maya": >
  env -C ${env.LOCAL_LLAMA_HOME}
  pixi run -m ${env.LOCAL_LLAMA_HOME} -e maya-cuda maya
```

```
"glm-5.3-flash-ud-q3-128k":
  cmd: |
    ${default-maya}
    --config config/maya-glm.json
    --port ${PORT}
  ...
```

* Maya 的 `/health` 就绪后才算加载完成；模型首载较久，`healthCheckTimeout: 3600`
  足够（全局已设）。
* llama-swap 用 SIGTERM 卸载：`maya.py` 捕获后停服务/引擎，显存释放。
* strata 的 `deepseek-v4.1-flash-iq2-512k` 条目已删除（Strata 0.2.14 起无
  dsv41），DeepSeek 完全由 Maya 承载；原 strata 用的 GPU 4,6 卡可直接复用。

## 已知坑

1. **别在 maya.py 外再套 `python maya.py`**：没有 `MAYA_SH=1` 会创建
   `$CONDA_PREFIX/maya/.venv`，服务用 venv 的 python 启动、缺 pixi 包。
2. **`nvtx3/nvToolsExt.h`**：`cuda-nvtx` conda 包只有运行库；头文件来自
   `nvidia-nvtx` wheel + `CPATH`。重装环境后 `maya-verify` 会检查该头。
3. **GitHub 不可达**：`maya-src.sh` 对 codeload 失败回退 `gh-proxy.com`；
   `git ls-remote` 也走同一兜底。源码用 tag tarball（26MB）。
4. **下载源**：`hf-mirror.com` 单连接 ~85KB/s，`aria2c -x16` 走 HF xet CDN
   也只有 ~5MB/s（本次 116GB 的 Maya-M 因此放弃）；**ModelScope** 的
   `unsloth/GLM-5.3-Flash-GGUF` 单文件 16 连接实测 ~87-94MB/s（147.5GB ~30min）。
   ModelScope 没有 `peasantsmith/*-Maya-*`；turboderp EXL3 在 ModelScope 只有
   cal_trace，量化文件只在 HF。HF 302 的目标是内容哈希文件名，`aria2c` 要用
   `-o <原名>`。
5. **pack 位置**：别把 pack 放到仓库里——引擎和上游的 staleness 检查都假设
   pack 在模型目录；`/data` 可写，直接放 `<模型目录>/pack`（GLM）或
   `<模型目录>/maya-ds4`（DeepSeek）。
6. **DeepSeek 的 Engram 表**：Maya 是 Q6_K ~161GB，常驻 SSD（`/data` 是 HDD，
   ROTA=1），按 token 随机读；主机内存上限 100GB 时最多缓存 ~62%，冷行会掉到
   10-20 tok/s。这是选 DeepSeek 量化时要先接受的代价；GLM 没有这张表。
7. **systemd-oomd**：`maya --check` 会警告。加载大 RAM tier 时它可能杀会话；
   本机内存上限 100GB，风险比 200GB 场景小，但正式跑前仍建议按上游
   `docs/SETUP.md` 停掉或加 drop-in。

## 视觉（待办）

`vision/mmproj-GLM-5.3-Flash-F16.gguf` + `vocab` 已下载。要启用图片还需要：

1. 构建 `maya-vision`（llama.cpp mtmd，独立 `build-vision`，当前 `maya-build.sh`
   未包含；上游 `setup.py` 的 vision 步骤可参考）；
2. run config 加 `"vision": {"exe": ..., "mmproj": ..., "vocab": ..., "gpu": true}`；
3. llama-swap 条目的 `capabilities.in` 加 `image`。

DeepSeek 的视觉塔是引擎内置（EXL3/GGUF pack 的 `vision.*`），不需要 `maya-vision`；
本次未下载 DeepSeek。

## 待办 / 下一步

* [x] 环境构建 + 验证（v1.1.76，sm_120，GPU 4 自检）
* [ ] GLM-5.3-Flash UD-Q3_K_XL：下载 → pack → 首跑 → API/工具/长上下文实测 → llama-swap 条目
* [ ] 视觉编码器与图片链路
* [ ] DeepSeek 量化定案（2 卡 / ≤100G RAM / HDD）：Maya-S vs Maya-XS vs EXL3 2.25
* [ ] 与 strata dsv41 的 A/B（同 prompt、同卡、Engram 冷/热分开记）
