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
  三种后端的公共前缀：
  - `default-llama`  — `pixi run -e llamacpp-cuda llama-server ...`
  - `default-vllm`   — `pixi run -e vllm-cuda vllm serve ...`
  - `default-sglang` — `pixi run -e sglang-cuda sglang serve ...`
  - 宏依赖 pixi 环境（`pixi run -m ${env.HOME}/local-llama -e <env>`），
    部署目录须是本仓库（pixi 项目）。
* `models`：每个模型一条，key 是 API 请求用的模型 ID：
  - `cmd`：完整启动命令（宏展开 + 模型参数），`|` 块内可写注释（启动时剔除）。
  - `useModelName`：转发请求时替换 model 字段的名称。
    vLLM / SGLang 按启动路径注册模型名，须指向 `${models_dir}/<model>`
    （llama.cpp 不校验 model 字段，无需此项）。
  - `env`：进程环境变量，如 `CUDA_VISIBLE_DEVICES`。
  - `ttl`：空闲自动卸载（秒）。
  - `filters.setParamsByID`：按 `模型ID[:变体]` 注入请求参数
    （temperature / reasoning-budget / chat-template-kwargs 等），
    变体名自动成为模型别名。
  - `capabilities` / `timeouts` / `sendLoadingState`：路由与超时行为。
* `routing`：swap 策略（group / scheduler），决定哪些模型可并存、
  加载新模型时谁被卸载。
* `hooks.on_startup.preload`：启动即预加载的模型。

### 模型清单（PRO6000）

| 模型 ID | 后端 | 模型文件 |
| ------- | ---- | -------- |
| `Qwen3.8-27B` | llama.cpp | GGUF UD-Q8_K_XL + mmproj |
| `Qwen3.6-35B-A3B` | llama.cpp | GGUF |
| `Qwen3.8-Flash-Next` | llama.cpp | GGUF UD-IQ4_XS (3 分片) + mmproj |
| `Qwen3.8-27B-vllm` | vLLM | FP8（~31G，单卡） |
| `Qwen3.8-27B-sglang` | SGLang | FP8 |
| `Qwen3.8-Flash-Next-vllm` | vLLM | NVFP4（133G，需多卡 TP） |
| `Qwen3.8-Flash-Next-sglang` | SGLang | NVFP4（需多卡 TP） |

vLLM / SGLang 后端的参数要点见 `docs/vllm.md` / `docs/sglang.md`；
vLLM/SGLang 条目默认 `CUDA_VISIBLE_DEVICES=1`，NVFP4 条目实际使用时
需改多卡并同步 TP 参数（见 conf 内注释）。
