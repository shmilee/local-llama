# issue：opencode 长上下文请求/压缩在 ~300 s 被中断

> **现象**：`Qwen3.8-27B-vllm-1M`（1M 上下文）在 opencode 里发长请求或触发压缩时，约 300 s
> 左右被中断——错误文案 `Timed out waiting for response data` 或
> `Connection lost while reading the response`；llama-swap Activity 里表现为 `200 / 0 token`。
> 引擎本身正常（小请求毫秒级返回）。
>
> **根因（三处叠加）**：① opencode 的 `chunkTimeout`/`headerTimeout` 默认 **300 s**；
> ② 中间链路"静默即断"（隧道/NAT 空闲回收、Bun fetch 5 分钟空闲超时等）；
> ③ 长上下文的**冷 prefill 期间一个字节都不发**（70 万 token 需数分钟）——
> 于是任何 5 分钟级看门狗都会在 prefill 完成前误杀。
>
> **修复（两处配置）**：
> - `~/.config/opencode/opencode.json`：三个超时放宽到 30 min，并按档位规划
>   `limit.context/input/output`（控制压缩触发点）；
> - `config/llama-swap-config-PRO6000.yaml` 的 `default-vllm` 宏：加
>   `--sse-keep-alive-interval 15`（静默期每 **15 s** 发一行 `": keep-alive"`，实测），
>   从此任何"静默即断"的层都不可能再掐掉长 prefill/压缩。
>
> 记录日期 2026-10-16。环境：opencode 2.0.26（Bun 编译）、provider `HHF` →
> `http://127.0.0.1:12435/v1`（ssh 隧道到集群 llama-swap）。

## LLM 请求的三个超时（最容易踩）

V2 providers 文档原文：

> HTTP requests wait up to five minutes for response headers and up to five minutes
> between streamed response chunks. Set the provider's `settings.headerTimeout` or
> `settings.chunkTimeout` to a number of milliseconds to change a limit, or to `false`
> to disable it. `settings.timeout` additionally bounds the whole request from send
> until the response completes; it has no default.

| 键 | 管什么 | 默认 |
| --- | ---- | ---- |
| `timeout` | 整请求（发送 → 响应完成） | 无默认 |
| `headerTimeout` | 等响应头 | 300000 ms |
| `chunkTimeout` | 相邻数据块之间的间隔 | 300000 ms |

* 位置：V2 原生写 `provider.<id>.settings`；本仓库沿用遗留写法
  `provider.<id>.options`（`options` 里还会混 `baseURL`/`apiKey`，归一化器会把
  这些键挑出来交给 opencode 自己的 HTTP 层）。
* **遗留 `options` 里必须给数字**：布尔 `false` 会被判为
  `$.provider.HHF kind=invalid / skipped malformed recognized value`（即该值被跳过，
  等价于没设）。V2 的 `settings` 才接受 `false`。
* 当前取值（`options` 与 `settings` 双写，30 分钟）：

  ```jsonc
  "HHF": {
    "npm": "@ai-sdk/openai-compatible",
    "options":  { "baseURL": "...", "apiKey": "...",
                  "timeout": 1800000, "headerTimeout": 1800000, "chunkTimeout": 1800000 },
    "settings": { "timeout": 1800000, "headerTimeout": 1800000, "chunkTimeout": 1800000 }
  }
  ```

* 超时后 opencode 会自动重试最多 3 次 ⇒ Activity 里会出现**连续多条 ~300s、0 token**
  的同一请求。改 `opencode.json` 会热重载 provider（日志出现 `config.updated` /
  `provider.updated`），不需要重启服务。

### 症状 → 原因对照

| UI / 错误文案 | 原因 |
| --- | --- |
| `Timed out waiting for response data` | `chunkTimeout` 触发 |
| `Timed out waiting for response headers` | `headerTimeout` 触发 |
| `Connection lost while reading the response` | 传输层连接被断开（错误带 cause），**不是**超时 |
| `Model unavailable: <provider>/<model>` | 当时 provider 配置无效（如上面的布尔 `false`）或模型不在该 provider |
| `provider.invalid-request`：`maximum context length is 1000000 … you requested N output tokens and your prompt contains at least M input tokens` | `M + N > max-model-len`，vLLM 直接 400 |

## 为什么长上下文必然踩：prefill 期间一个字节都不发

* vLLM 收到请求即回 SSE 200 头，但**第一个 token 之前不产生任何数据块**。冷启动
  （prefix cache 为空）时，70 万 token 的 prefill 需要几十秒到几分钟——期间客户端
  只能"干等"。
* 实测（2026-10-16，`Qwen3.8-27B-vllm-1M`，单卡 PRO6000）：
  - opencode 会话（in=698,941，冷 prefill）：`200`，**402 s** 完成
    （引擎侧 prefill ≈165 s，之后 decode ~75 t/s，out=12,069）；
  - 人工构造 620k token prompt：**TTFT 409 s**（≈1.5k t/s；与
    [vllm.md](vllm.md)「长上下文」节"prefill 近似腰斩"一致）。
* **陷阱**：vLLM 的 `vllm:prompt_tokens_total` 只在 prefill **结束时**才跳变，
  轮询指标会看到"零进展"的假象——那不是卡死（本次排查就一度误判）。
* 结论：客户端/中间层的任何 5 分钟级看门狗都会在冷 prefill 时误杀；
  `headerTimeout`/`chunkTimeout` 建议 ≥1800000 ms（或 `false`）。
* **服务端兜底：`--sse-keep-alive-interval 15`**（vLLM 0.30 自带，默认 0=关）。
  实现见 `vllm/entrypoints/serve/utils/sse_keep_alive.py`，由
  `entrypoints/openai/chat_completion/api_router.py` 包在流式生成器上：静默超过
  interval 就发一行 `": keep-alive\n\n"`。该文件注释写明正是为
  "反向代理/隧道在排队、prefill、token 间隙因无字节而断流" 准备的。开了它之后，
  所有"静默即断"的层（opencode 三个超时、隧道/NAT 空闲回收、Bun fetch）都不可能
  再误杀长 prefill。已加在 conf 的 `default-vllm` 宏里。**实测**（2026-10-16，33 万
  token 冷 prefill）：静默期间每 **15.0 s** 收到一条 `: keep-alive`（共 8 条），全程
  最大字节间隔 15.0 s，请求 135 s 正常完成。
* 冷 prefill 一次成功后就进 prefix cache，同会话后续每轮只算增量（秒级～十几秒），
  所以**别在长会话进行中重启 llama-swap/vLLM**。

## 压缩（compaction）：每次都是整段冷 prefill

opencode 的 compaction 会重写 prompt 头部（它自己的总结指令/system），因此**前缀
缓存全 miss**——与同会话普通轮次（99.9% 命中）完全不同：

| 实测（同会话，2026-10-16） | 结果 |
| --- | --- |
| 普通轮次 #16457 | in=913,872 / cache=885,504 → **73 s** |
| compaction #16458 | 200 / **0 字节** / **318.6 s** 中止；引擎侧 `Running: 1` 后 5 分钟无任何 `Engine 000` 统计行（= 整段在一个超长 prefill 里） |
| compaction #16459 / #16460 | 357.4 s / 105.8 s（均 0 token） |

* 会话越长压缩越贵：压缩时的会话大小 ≈ 触发点 ⇒ 冷 prefill 时间随触发点增长
  （2026-10-16 实测：620k ≈ 409 s、332k ≈ 135 s ⇒ 约 1.5–2.5k t/s，长上下文 prefill 近似腰斩）。
* **默认触发点 ≈ 上限的 90%**：默认 buffer = `max(⌊r×10%⌋, r ≥ 32000 ? 16000 : 0)`
  （1M 模型 ⇒ ≈90 万）⇒ "什么都不配"时自动压缩几乎必然是一整段 ~90 万的冷 prefill。
* 阈值公式与"按模型控制触发点"的正式做法见下节「模型 limit 规划」；
  `compaction.buffer` **不采用**（它是**配置文件级的绝对值**、显式值无钳制、按目录树合并，
  全局设大会让上限 < buffer 的模型（262k/128k/32k）阈值变负 → 每轮触发）。
  `keep.tokens` 默认 15000 = 摘要旁保留的最近对话；压缩用的是**会话自己的模型**，
  没有单独的压缩模型。
* 手动压缩（随时可用）：`opencode api post /api/session/<sessionID>/compact --data '{}'`
  ——返回只表示已受理，完成后看 `session.compaction.*` 事件。
* **opencode 的记录是定性证据**：这次失败的压缩消息错误是
  `{"type":"compaction.interrupted","message":"Compaction was interrupted"}`
  ⇒ **是被打断（人工停 / UI / 新输入），不是超时**；配合"中止时长不固定"
  （105.8 / 318.6 / 357.4 s）即可判定。压缩期间请注意不要打断它。
* 想快就**更早压缩**：在 ~30–50 万时就触发，冷 prefill 只需 2–4 分钟；等到贴近
  1M 上限才压缩，压缩本身就是一次 ~90 万 token 冷 prefill。
* 配上 `--sse-keep-alive-interval`（见上节）后，压缩期间也不会被任何"静默即断"的
  层掐掉。

## 模型 limit 规划与压缩触发点

**策略**（所有 provider 统一）：

1. `limit.context` = 模型真实上限，不人为减小；
2. `limit.output` 按档位：`1M → 65536`、`256k → 32768`、`32k → 8192`
   （它同时是该模型的请求 max_tokens）；
3. `limit.input = min(⌊期望触发点 D ÷ 0.9⌋, context − output)`。

**阈值公式**（opencode 2.0.26 bundle 读出）：

```
r    = limit.input || limit.context            // input 优先；未设 input 时取 context
buf  = max(⌊r×0.1⌋, r ≥ 32000 ? 16000 : 0)     // 显式 buffer 时 buf = buffer（无钳制）
阈值 = r − buf                                  // 自动压缩在 用量 ≥ 阈值 时触发
```

**已应用取值与验算**（期望 D = 800k / 196k / 20k，逐档精确命中）：

| provider/model | context | input | output | **阈值** | 期望 |
| --- | ---: | ---: | ---: | ---: | ---: |
| HHF/Qwen3.8-27B | 262144 | 217777 | 32768 | 196000 | 196000 |
| HHF/Qwen3.8-27B-vllm-1M | 1000000 | 888888 | 65536 | 800000 | 800000 |
| HHF/Qwen3.8-Flash-Next | 262144 | 217777 | 32768 | 196000 | 196000 |
| HHF/Qwen3.8-Flash-Next-vllm-1M | 1000000 | 888888 | 65536 | 800000 | 800000 |
| T14p ×4（Qwen3.6-35B-A3B / Gemma4-26B-A4B / Toy-A / Toy-B） | 32768 | 22222 | 8192 | 20000 | 20000 |

**两个公式边界陷阱**（映射非线性，不是算错）：

* `min(·, context − output)` 会**静默压低**触发点：当 `D/0.9 > C−O` 时实际阈值 =
  `0.9(C−O) < D`。规则：**保持 `D < 0.9(C−O)`**（当前三档都满足；例如 256k 档若把
  output 提到 64k，`C−O=196608` 就会钳制 → 阈值掉到 176,947）。
* 默认 buffer 的 **16000 下限**（`r ≥ 32000` 时生效）⇒ 当 `input ∈ [32000, 160000)`
  （⇔ `D ∈ [28800, 144000)`）阈值 = `input − 16000`，`D/0.9` 会**偏早最多 ~12.8k**。
  该区间正确取法 **`input = D + 16000`**。当前三档在安全侧（`input ≥ 160000` 或 `< 32000`），
  所以精确；以后加中等档（128k / 200k 之类）按下面分段取。
* 分段总表：`D < 28800 → input = ⌊D/0.9⌋`；`28800 ≤ D < 144000 → input = D + 16000`；
  `D ≥ 144000 → input = ⌊D/0.9⌋`；最后 `min(·, C−O)` 兜底。

**语义提醒**：

* `limit.input` 在 2.0.26 里**只驱动上述阈值**（`limit.context` 另用于 UI 的上下文百分比）——
  **不约束实际发送的 prompt**，是"触发旋钮"而非"输入硬上限"；且只覆盖显式配置的模型
  （catalog provider 如 deepseek 的 `limit.*` 来自 models.dev，触发点与本地这套不一致）。
* opencode **不会**把未设的 `input` 推导成 `context − output`（未设时 base = `context`；
  实测：会话 875k 无压缩动作、913k 完成后立即触发 ⇒ 默认触发点 ≈900k = 1M − 10%）。
* `prompt + max_tokens ≤ max-model-len` 是**服务端 vLLM** 的限制（最大可发 prompt = C−O），
  与压缩阈值是两件事。历史事故：prompt 904,001 + output 96,000 = 1,000,001 > 1,000,000
  → vLLM 400（"requested 96000 output tokens … prompt contains at least 904001 input tokens"）。
* 压缩触发后压缩本身是**冷 prefill**（≈触发点大小；1M 档 80 万 ⇒ 6–9 分钟）——触发点高低
  只决定"多早开始等"，不改变这段等待；保护来自 `--sse-keep-alive-interval` + 不要打断。

## 排查手法（本次实际用到的）

* **llama-swap Activity API**（需要 conf 里的 `apiKeys`）：
  `GET /api/metrics/activity?limit=N` → 每条请求的 `in/out`、`duration_ms`、
  `resp_status_code`、`has_capture`。用它区分"正常完成"与"0 token 失败"。
* **vLLM 指标**：`curl localhost:16004/metrics` →
  `num_requests_running`/`num_requests_waiting`、`prompt_tokens_total`、
  `generation_tokens_total`、`time_to_first_token_seconds_{count,sum}`
  （`sum/count` 即平均 TTFT）。
* **llama-swap 日志**：
  - `recovered from upstream disconnection during streaming` +
    `metrics: empty body, recording minimal metrics` ⇒ 本次流**一个字节都没回给客户端**
    （客户端先走或上游先走都会打这行，方向不能只看它）。
  - `Engine 000: ...`（来自 vLLM）只在引擎步进跨过 10s 间隔时出现，可用于区分
    "引擎没在算"与"链路没数据"。
* **opencode 侧**：
  - `~/.local/share/opencode/log/opencode.log`，**时间戳是 UTC**；
    `configuration normalization diagnostic` 中 `kind=invalid` = 该配置值被跳过，
    `kind=unsupported / omitted unsupported legacy setting`（如 `models.<m>.reasoning`）
    只是警告、无影响。
  - `~/.local/share/opencode/opencode.db`（sqlite，表 `session_v2` /
    `session_message` / `part`）：消息级错误如 `provider.invalid-request`（上下文超限）、
    `aborted / "Step interrupted"`；`tokens.cache.read` 可直接读出会话上下文实际大小
    （本次读到 696,128 ⇒ 即 ~70 万 token 会话）。
* **判断"是谁掐的"**（本次排除过程）：
  - ssh 隧道：新建隧道挂静默通道 **480 s 无损**（`ssh -v` 显示 channel
    `inactive timeout: 0.000000`）；`ServerAliveInterval/ServerAliveCountMax` 只作用于
    SSH **连接**，对"静默 channel"无帮助（实测加与不加都一样）。
  - llama-swap：主 HTTP server 是裸 `http.Server{Addr, Handler}`（无 Read/Idle/Write
    超时）；集群内静默连接 ≥420 s 存活 ⇒ 不关空闲连接。
  - 最终定位：**opencode `headerTimeout` 默认 300 s**（`chunkTimeout` 是更早被改掉的
    那个，所以错误串从 `Timed out ...` 变成 `Connection lost ...`）。
* opencode 跑在 Bun 上，Bun 的 `fetch` 自身有 5 分钟空闲超时（源码常量 300 s，
  计时器轮 pad 到 ~360 s），**但 opencode 已显式关闭**（给 fetch 传 `timeout: false`，
  由自己的三个超时接管）——排查时不要往 Bun 方向找。
* ssh 隧道进程一旦退出，opencode 侧表现为连接被拒：
  `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:12435/health` 不是 `200`。
