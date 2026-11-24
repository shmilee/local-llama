# llama-swap

多模型/多后端推理路由器：按请求中的模型 ID 加载/卸载/切换推理服务
（OpenAI 兼容 API 入口）。

## 目录布局

```
bin/llama-swap                                # 二进制（不入库，部署时放入）
config/llama-swap-config-<name>.yaml          # 配置文件
logs/llama-swap-<name>-<date>.log             # 运行日志（start 脚本生成）
llama-swap-start.sh                           # 启动脚本
```

`bin/` 与 `logs/` 在 .gitignore 中。

## 启动

```
./llama-swap-start.sh -n PRO6000              # 集群，默认端口 12435
./llama-swap-start.sh -n T14p -p 12434        # 笔记本
```

* 配置文件在 cwd 或脚本目录的 `config/` 下按 `llama-swap-config-<name>.yaml` 查找。
* 二进制固定在 `bin/llama-swap`，日志写入 `logs/`。
* `-watch-config`：配置文件改动热加载（改 conf 无需重启）。

## 部署

### 服务器（PRO6000）

* 配置文件: `config/llama-swap-config-PRO6000.yaml`
* 运行: `~/local-llama/llama-swap-start.sh -n PRO6000 -p 12435`
* 本地端口映射: `ssh -Nv -L 127.0.0.1:12435:127.0.0.1:12435 hhf200.sans`

### 笔记本（T14p）

* 配置文件: `config/llama-swap-config-T14p.yaml`
* systemd 服务: /etc/systemd/system/llama-swap.service.d/T14p.conf
  ```
  [Service]
  # 清空原始的 ExecStart 命令列表
  ExecStart=
  ExecStart=/usr/bin/llama-swap -config %E/llama-swap/llama-swap-config-T14p.yaml -watch-config -listen 0.0.0.0:12434
  ```
* 或 `source /opt/intel/oneapi/setvars.sh` 后（后端是 SYCL 时），
  运行: `~/local-llama/llama-swap-start.sh -n T14p -p 12434`

## 配置文件结构（PRO6000）

* `macros`：可复用命令片段，`${MACRO_NAME}` 展开，支持 `${env.VAR}` /
  `${PORT}` / `${MODEL_ID}` / `${models_dir}` / `${ctx_256k}` 等。
  两种后端的公共前缀：
  - `default-llama`  — `pixi run -e llamacpp-cuda llama-server ...`
  - `default-vllm`   — `pixi run -e vllm-cuda vllm serve ...`
  （`default-sglang` 宏 2026-11-16 随 sglang 条目归档，展开后的命令见
  `docs/models/Qwen3.8-27B.md` / `docs/models/Qwen3.8-Flash-Next.md`）
  - 宏依赖 pixi 环境（`pixi run -m ${env.HOME}/local-llama -e <env>`），
    部署目录须是本仓库（pixi 项目）。
* `models`：每个模型一条，key 是 API 请求用的模型 ID：
  - `cmd`：完整启动命令（宏展开 + 模型参数），`|` 块内可写注释（启动时剔除）。
  - `useModelName`：转发请求时替换 model 字段的名称。
    vLLM / SGLang 按启动路径注册模型名，须指向 `${models_dir}/<model>`
    （llama.cpp 不校验 model 字段，无需此项）。
  - `env`：进程环境变量，如 `CUDA_VISIBLE_DEVICES`。
  - `ttl`：空闲自动卸载（秒）。
  - `filters.setParams`：对该模型所有请求恒注入的参数
    （sglang 条目用它注入 `return_spec_tokens_details` 与
    `stream_options.include_usage`）。
  - `filters.setParamsByID`：按 `模型ID[:变体]` 注入请求参数
    （temperature / reasoning-budget / chat-template-kwargs 等），
    变体名自动成为模型别名；在 setParams 之后应用，可覆盖之。
  - `capabilities` / `timeouts` / `sendLoadingState`：路由与超时行为。
* `routing`：swap 策略（group / scheduler），决定哪些模型可并存、
  加载新模型时谁被卸载。
* `hooks.on_startup.preload`：启动即预加载的模型。

### 模型清单（PRO6000）

模型清单、状态、实测与决策记录以 `docs/models/README.md` 为单一来源；
逐模型历史见 `docs/models/<模型>.md`。

在役条目（2026-11-16 归档后）：

| 模型 ID | 后端 | 模型文件 |
| ------- | ---- | -------- |
| `qwen3.8-27b-q8-256k` | llama.cpp | GGUF UD-Q8_K_XL + mmproj |
| `qwen3.8-27b-fp8-1m` | vLLM（YaRN） | FP8 |
| `qwen3.8-flash-next-fp4-1m` | vLLM（YaRN） | NVFP4（1M 上下文，TP2） |
| `glm-5.3-flash-q3-1m` | Project Maya | Unsloth Q3_K_XL（GLM-5.3-Flash，1M） |
| `qwen3.8-flash-next-iq3-1m` | strata flash_next | ISTA-DAS IQ3_XXS（1M，视觉已启用） |

已归档 7 条目（2026-11-16）：cmd 与实测冻结于对应模型文档
（`docs/models/Qwen3.8-27B.md` / `docs/models/Qwen3.8-Flash-Next.md`）。

* `-1M` 变体：同一份权重加 YaRN ×4 外推到 1M 上下文，与 262K 条目是
  各自独立的进程（互相切换 = 卸载 + 重载）；踩坑见 `docs/llama.cpp.md`
  与 `docs/vllm.md` 的「长上下文（YaRN 1M）」节。
* GPU 分配见 conf `env`：卡号可选（以 conf 实际值为准），均避开 CUDA0
  （防 CLIP 误用）；唯一不变式是 27B 家族与 Flash-Next 家族不共卡
  （两组可并存）。`qwen3.8-flash-next-fp4-1m` 带 numactl NUMA 绑定，
  node 编号须与所选卡所在 socket 一致（见下文「NUMA / CPU 绑定」）。
* `routing` 两个 group 与家族对应：group1 = 27B 家族（2 条目），
  group2 = 4,6 卡系（FP4 vLLM 1M + Maya GLM 条目 + strata Qwen 条目，共 3 条目）；
  组内换模型即卸载，两组可并存。

vLLM / SGLang 后端的参数要点见 `docs/vllm.md` / `docs/sglang.md`。

## NUMA / CPU 绑定（双路服务器）

PRO6000 为双路（无 NVLink）：GPU 0-3 挂 NUMA node 0，GPU 4-7 挂 node 1
（`nvidia-smi topo -m` 的 NUMA Affinity 列；同 socket 卡对为 `NODE`，
跨 socket 为 `SYS`）。1M 条目（`qwen3.8-flash-next-fp4-1m`；已归档的
`Qwen3.8-Flash-Next-1M` 同法）的 cmd 以 `numactl --cpunodebind=1` 包裹
（当前选 4,6，均在 node 1，故编号为 1；改选卡时先确认所选卡所在 node
再改编号）：

* `--cpunodebind=1`：进程全部线程只调度在 node 1 的 CPU 上
  （本机为核 32-63, 96-127）——即 GPU 所连的 socket 侧。内存按默认
  local 策略就近分配（优先 node 1，不足时回退 node 0，不会硬失败）。
* 不加 `--membind=1`：严格绑定禁止回退到 node 0，徒增硬失败风险，而
  cpunodebind 已让首次触碰的页落在同侧 node。宿主内存胃口不小——
  vLLM 的 PLE 表是 **ETP 切分**的（`ngram_embedding.py`："ETP-sharded
  PLE table"，词表每行只有一个 rank 持有），TP2 下每 rank ~36G
  （实测 CPU Memory 36G+36G）；llama.cpp 的 N-gram 表 mmap+mlock ~70G
  + cache-ram 12G；node 1 共 128G。（membind 未单独 A/B 验证过——
  早前失败探针里它与其他变量同时存在，故此处按"收益/风险"取舍。）
* 为什么需要绑定：两条目都重度依赖宿主内存——vLLM 的 PLE 表（FP8，
  切分后 ~36G/rank）逐 token 经 UVA 异步预取，N-gram 层特意放在
  layer 2 就是为了与 layer 1 计算重叠；llama.cpp 的 N-gram 表
  mmap+mlock ~70G。内存若落在对侧 socket，每次读取都过一次 UPI，
  侵蚀预取重叠的设计收益；而「CPU 绑定 + 默认 local 就近分配」已足以
  让绝大部分页落在同侧。
* NUMA 策略与 CPU affinity 会被子进程继承（vLLM 的 TP worker）、跨 exec
  保留，故只需包裹入口命令。
* node 编号查询：`numactl --hardware` 或 `nvidia-smi topo -m`。通常稳定，
  但换主板/CPU/BIOS 后拓扑可能变化，须重新核对。同时核对宿主内存预算：
  node 1 = 128G，而 PLE（TP2 下每 rank ~36G）或 N-gram 表（~70G
  + 12G cache-ram）已占大半。
* 依赖：系统 `numactl`（服务器发行版一般已装，否则
  `yum install numactl` / `apt install numactl`）；缺失时条目启动报
  `command not found`，装好或去掉前缀（去掉只损失性能，不影响正确性）。

## 官方二进制与版本更新

* 2026-11-16 起直接采用官方预编译 release（已含 UI），
  安装/升级：`bash scripts/llama-swap-install.sh`——TAG 硬编码于脚本，
  上游发新版后更新 TAG 重跑即可（下载幂等、sha256 按 release 的
  checksums 校验）；下载在 `download/`，旧二进制保留 `bin/llama-swap.prev`
  作首个回退基线，版本串显示官方 tag（如 `v273`）。
* 安装后重启 llama-swap 生效。注意重启会卸载在跑的模型
  （vLLM 1M 冷加载 ~18min），选空闲时段执行。
* v262 及以前的本地补丁构建（源码打补丁 + npm 嵌 UI + go 编译）已于
  2026-11-16 移除：
  - 补丁三块内容：解析 SGLang `sglext.spec_tokens_details`（Activity 页
    Drafted 列）、SGLang 流式 decode 速率回退（首写字节时间窗，
    后端自报速率时不触发）、`sendLoadingState` loading 流的首写时钟
    重置（仅为前两项修正）。
  - 受益者仅为 SGLang LLM 条目（同日归档）；现役 llama.cpp / vLLM /
    Strata 后端均自报逐请求指标（Strata 的 `strata serve` 返回
    llama.cpp 风格 `timings`），补丁对它们零效果。
  - 规划的 SGLang 用途是 T2I：无 token/投机解码/流式 decode，
    补丁不触发，T2I 条目也不需要 `setParams` 注入统计参数。
  - 补丁与旧构建脚本可从 git 历史找回（83d14e7、64d2624）；若将来
    恢复 SGLang LLM 条目且需要 Drafted/Decode 列，按当时上游 tag
    重新生成（v269 起触点在 `internal/server/usage/` 的按后端
    extractor 与 metrics 中间件的 `responseBodyCopier`）。
