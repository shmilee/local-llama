# stable-diffusion.cpp (sd.cpp)

* 官网: <https://github.com/leejet/stable-diffusion.cpp>
* 定位: "图像生成版的 llama.cpp" —— 纯 C/C++（ggml）diffusion 推理，GGUF 权重
* 本仓库用途: T2I（文字生成图片）后端。llama-swap 对其 SDAPI 路由有一等公民支持，
  且 sd-server 本身还内置 OpenAI 兼容 `/v1/images/generations`
* 支持的模型: SD1.x/SDXL/SD3.5、FLUX.1/2/3、Qwen-Image、Z-Image、MOSS-Image、
  Krea2、Chroma 等（见上游 README，迭代很快，以 pin 的 tag 为准）

## 安装方式

### pixi 源码编译（本仓库）

`pixi.toml` 的 `sdcpp-vulkan` 环境（Vulkan 后端，T14p 核显；CUDA 后端环境 `sdcpp-cuda`
预留给 PRO6000，结构相同）：

```
pixi install -e sdcpp-vulkan
pixi run   -e sdcpp-vulkan sdcpp-build    # 拉取源码 + 编译 + 安装
pixi run   -e sdcpp-vulkan sdcpp-verify   # 验证安装（bin + --version + GPU 设备）
pixi run   -e sdcpp-vulkan sdcpp-path     # 打印 sd-cli 绝对路径
```

版本与构建细节见 `pixi.toml` 的 feature 注释（当前
`SDCPP_VERSION = "master-1014-012c7f8"`，2026-10-25 发布）。

### 源码获取（国内网络要点）

GitHub codeload（tarball）与 git 协议在长传输中都会断流/静默截断（T14p 实测：
tarball ~7MB 处 EOF、git fetch-pack ~8MB 失败、gh-proxy 镜像 ~2.6MB 失败），
但也存在单次直连稳定传完 40MB+ 的窗口（~11min）。
`scripts/sdcpp-src.sh` 因此采用**多源 + 每源有限重试 + 完整性校验**：

* 源顺序: GitHub 直连 → gh-proxy.com → ghfast.top（`SDCPP_TARBALL_URL` 可整体覆盖）
* 每次失败删除 `.part` 半成品；下载后 `gzip -t`，解压后校验关键目录
* 任一环节不通过都清场重来，任务幂等可重跑

## 构建选项（sdcpp-build.sh）

| 选项 | 取值 | 说明 |
| ---- | ---- | ---- |
| `SD_VULKAN` / `SD_CUDA` | 由 `$SDCPP_BACKEND` 决定 | ggml 后端 |
| `SD_BUILD_EXAMPLES` | ON | 构建 sd-cli / sd-server |
| `SD_SERVER_BUILD_FRONTEND` | OFF | 关闭 server Web 前端（pnpm/node 构建链），纯 API 服务 |
| `SD_WEBP` / `SD_WEBM` | OFF | 不引入 libwebp/libwebm 子模块 |
| `SD_BUILD_SHARED_LIBS` | OFF（默认） | 静态链接，sd-cli / sd-server 自包含 |

构建缓存防护与 `llamacpp-build.sh` 同构（编译器路径失效 + 工具链指纹）。

## sd-server 端点（llama-swap 集成点）

源码 `examples/server/routes_*.cpp` 核实（master-1006-0886f11，1014 未变）:

* OpenAI 兼容: `GET /v1/models`、`POST /v1/images/generations`、`POST /v1/images/edits`
* SDAPI 兼容: `POST /sdapi/v1/txt2img`、`POST /sdapi/v1/img2img`、
  `GET /sdapi/v1/loras`、`/sd-models`、`/samplers` 等
* sd.cpp 专属: `routes_sdcpp.cpp`（`/api/v1/*`）

即 llama-swap 注册时客户端两种 API 形态都可用（OpenAI images API 或 SDAPI），
无需转换层。

## 运行测试

### Z-Image Turbo（T14p 集显实测通过）

```
sd-cli --diffusion-model /media/Data/huggingface-models/Z-Image-Turbo/z-image-turbo-Q4_K_M.gguf \
  --vae /media/Data/huggingface-models/Z-Image-Turbo/ae.safetensors \
  --llm /media/Data/huggingface-models/Z-Image-Turbo/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  -p "PPT黑板，主题：算术加法" --cfg-scale 1.0 -v --offload-to-cpu \
  -H 512 -W 512 --steps 8
```

* 权重下载记录见 `docs/models.md`「7. Z-Image, 文生图」
* 集显（Vulkan）+ `--offload-to-cpu` 混合 offload；8 步蒸馏模型，`cfg_scale 1.0`
* llama-swap 接入：`config/llama-swap-config-T14p.yaml` 的 `Z-Image-Turbo` 条目，
  sd-server 启动时经 `--diffusion-model/--llm/--vae` 加载同一组权重，
  走 SDAPI `/sdapi/v1/txt2img`（steps/cfg/sampler/尺寸默认值在
  `filters.setParamsByID` 注入）

其他模型（Qwen-Image / Krea2 / MOSS-Image / SDXL 等）的具体权重组合与参数，
见上游 `docs/z_image.md`、`docs/qwen_image.md`、`docs/krea2.md`、`docs/moss_image.md`。

## T2I 模型路线（规划）

* PRO6000（GPU）: SGLang Diffusion + sd.cpp 双引擎 × Z-Image / Qwen-Image / Krea2
* T14p（CPU/核显）: 仅 sd.cpp（SDXL 主力 + Z-Image Turbo 实验）
* 详见仓库 T2I 调研结论（sd.cpp 对 Z-Image、Qwen-Image、Krea2 均有原生支持）
