# pixi 环境

`pixi.toml` 管理八个推理环境（llama.cpp / vLLM / SGLang / stable-diffusion.cpp / Strata / Project Maya），
全部源码或 PyPI 安装，系统依赖最小化（CUDA 环境仅依赖 NVIDIA 驱动）。

## 环境一览

| 环境 | feature | 后端 | 包来源 |
| ---- | ------- | ---- | ------ |
| `llamacpp-cuda`  | `llama-base` + `llamacpp-cuda`  | CUDA   | conda 工具链 + llama.cpp 源码编译 |
| `llamacpp-vulkan`| `llama-base` + `llamacpp-vulkan` | Vulkan | conda 工具链 + llama.cpp 源码编译 |
| `vllm-cuda`      | `vllm-cuda`                      | CUDA 13| PyPI（vLLM + torch cu130） |
| `sglang-cuda`    | `sglang-cuda`                    | CUDA 13| PyPI（SGLang + torch cu130） |
| `sdcpp-vulkan`   | `sdcpp-base` + `sdcpp-vulkan`    | Vulkan | conda 工具链 + sd.cpp 源码编译 |
| `sdcpp-cuda`     | `sdcpp-base` + `sdcpp-cuda`      | CUDA   | conda 工具链 + sd.cpp 源码编译 |
| `strata-cuda`    | `strata-base` + `strata-cuda`    | CUDA 13| conda 工具链 + Strata 源码编译（CUDA 引擎 + Python 终端） |
| `maya-cuda`      | `maya-base` + `maya-cuda`        | CUDA 13| conda 工具链 + Project Maya 源码编译（maya / maya-ds4 + Python 服务） |

## 常用命令

```
# llama.cpp（版本/构建细节见 pixi.toml feature 注释）
pixi install -e llamacpp-cuda
pixi run   -e llamacpp-cuda llamacpp-build
pixi run   -e llamacpp-cuda llamacpp-verify
pixi run   -e llamacpp-cuda llamacpp-path

# vLLM
pixi install -e vllm-cuda
pixi run   -e vllm-cuda vllm-cuda-prepare   # 整理 pip nvidia 包为标准 CUDA toolkit 布局
pixi run   -e vllm-cuda vllm-cuda-verify    # 验证（import/CUDA + 工具链 + flashinfer JIT 探针）

# SGLang
pixi install -e sglang-cuda
pixi run   -e sglang-cuda sglang-cuda-prepare
pixi run   -e sglang-cuda sglang-cuda-verify    # 验证（版本 + 设备 + 工具链信息展示）

# stable-diffusion.cpp（Vulkan / CUDA；源码获取的多源重试细节见 docs/sd.cpp.md）
pixi install -e sdcpp-vulkan
pixi run   -e sdcpp-vulkan sdcpp-build
pixi run   -e sdcpp-vulkan sdcpp-verify
pixi run   -e sdcpp-vulkan sdcpp-path

pixi install -e sdcpp-cuda      # 需 N 卡（PRO6000 等）
pixi run   -e sdcpp-cuda   sdcpp-build
pixi run   -e sdcpp-cuda   sdcpp-verify
pixi run   -e sdcpp-cuda   sdcpp-path

# Strata（CUDA 引擎 + Python 终端；需 N 卡 sm_75+，RTX 50 需 CUDA>=13）
pixi install -e strata-cuda
pixi run   -e strata-cuda strata-build    # 下载源码 + 编译引擎 + 安装终端
pixi run   -e strata-cuda strata-verify   # --version + GPU 检测/显存自检 + python 依赖
pixi run   -e strata-cuda strata-path

# Project Maya（CUDA 引擎 + Python 服务；GLM-5.3-Flash / DeepSeek-V4.1-Flash）
pixi install -e maya-cuda
pixi run   -e maya-cuda maya-build     # 下载源码 + 编译 + 安装
pixi run   -e maya-cuda maya-verify    # --version + GPU 自检 + Python 依赖
pixi run   -e maya-cuda maya-pack glm <模型目录>   # 生成 GLM pack
pixi run   -e maya-cuda maya-path
```

verify 脚本缺 CUDA 布局时会自动调用 prepare。

## PyPI 环境的 CUDA 自包含策略（vllm-cuda / sglang-cuda）

不装 conda cuda 包、不用系统 `/usr/local/cuda`：

* torch cu130 wheel 依赖的 `nvidia-*-cu13` pip 包自带 CUDA 运行时、
  头文件与 nvcc（`site-packages/nvidia/cu13/`）。
* `*-cuda-prepare` 任务把该布局整理成标准 CUDA toolkit 目录结构
  （`$CONDA_PREFIX/<name>-cuda/{bin,include,lib,lib64}`，symlink 视图），
  供 flashinfer JIT / torch inductor / sglang JIT 按 `CUDA_HOME` 查找。
  幂等，pip 包升级后重跑。
  项目内的 symlink 均为相对路径，pixi 项目目录整体移动后链接不断
  （唯一例外 `stubs/libcuda.so` 指向项目外的系统驱动库，用绝对路径）；
  sglang 的 nvcc wrapper 运行时按自身位置解析真实 nvcc，同样可移动。
* 唯一系统依赖：NVIDIA 驱动（`libcuda.so.1` + `/dev/nvidia*`）。
* prepare 同时补两处链接用符号链接：
  - `libcudart.so`（PyPI 包只有版本化 `.so.13`）
  - `lib64/stubs/libcuda.so` → 系统驱动库（conda ld 搜索路径不含
    系统库目录；stub 仅链接时使用，运行时按 SONAME 找真实驱动）
* `sglang-cuda-prepare` 额外把布局里的 `nvcc` 换成 wrapper 脚本
  （注入 `-DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK`，原因见 `docs/sglang.md`）。

## Strata 环境策略（strata-cuda）

Strata 是 Qwen3.8-Flash-Next（`flash_next` 形状）等 MoE 模型专用的 CUDA
推理引擎（0.2.16+ 的 ggml 已 vendored 在 `engine/third_party/strata-ggml`，
无外部 llama.cpp 依赖）。引擎直跑说明与注意点见 **`docs/strata.md`**。
**0.2.14 起上游移除了 DeepSeek（dsv41）引擎（#6072/#6048）**，本环境只
保留主引擎；DeepSeek-V4.1 用独立的 `maya-cuda` 环境（Project Maya）。

源码布局（0.2.16+）：`engine/`（C++/CUDA 引擎）+ `terminal/`（Python 终端，
`tools/vision` 是图片编码器）+ `tools/`（仓库工具）。环境装三样东西：

* **引擎**（C++/CUDA 源码编译，安装到 `$CONDA_PREFIX/bin`）：
  - `strata-engine` —— 引擎本体（官方二进制名 `strata`，改名是为了把
    `strata` 留给 Python 终端启动器；server 通过 run config 的相对路径调引擎）
  - `strata-device` —— GPU 诊断/显存自检（verify 用它）
  - 仓库无 CMake install 规则：`strata-build.sh` 手动拷贝后用
    `patchelf` 把 RPATH 设为 `$ORIGIN/../lib`（环境内 CUDA 运行库）
  - CUDA 架构默认取 `nvidia-smi compute_cap`（如 120）；跨卡发行设
    `STRATA_CUDA_ARCHS="75;86;89;120"`
  - 默认模型形状 `STRATA_GEOMETRY=flash_next`；其他形状经
    `STRATA_CMAKE_EXTRA` 传 `-DSTRATA_GEOMETRY=<name>`
* **图片编码器**（`strata-vision`，0.2.16+ 是 Strata 自有 Qwen 视觉塔
  `terminal/tools/vision/own`，不编译 llama.cpp/mtmd；构建目录
  `<源码>/build-vision`）。QFN 的 run config 有 vision 段而缺它时模型
  起不来，故不是可选项；`strata-verify` 会检查它。
* **Python 终端**（`strata` 命令，OpenAI/Anthropic 兼容 API server、
  status/monitor 等）：整套 python 树从 `terminal/` 拷入
  `$CONDA_PREFIX/strata/`（strata.py / strata_cli / strata_control /
  serve / data / tools / setup.py），`$CONDA_PREFIX/bin/strata` 是 3 行 sh
  启动器（环境 python3 + 自设 PYTHONPATH，未 `pixi activate` 直接调用也能跑）。
  运行依赖 pin 与 `terminal/requirements.txt` 一致（python 3.12 分支）。

源码下载：tag tarball（`download/Strata-<版本>.tar.gz`）；直连 codeload
失败时回退 `gh-proxy.com` 镜像（`scripts/strata-src.sh`）。

验证不加载模型、不启动服务（与其他环境同策略）：引擎的 `--version` +
`strata-device --list-devices`（架构不匹配会报 `cannot run`，据此抓
"编译成功但后端没编进去"的静默失败）+ `--selftest`（真实占用显存）+
`strata-vision` usage + python 终端 import 检查。

Qwen3.8-Flash-Next 推理冒烟（PRO6000 单卡实测，GSQ-RCO IQ3_XXS 71GB，
空闲卡 `--gpu N`；模型只读自 `/data/huggingface-downloads`）：

1. 准备 pack（约 1 分钟，输出 1.5G；专家权重运行时直接读 GGUF，
   不复制 `experts.bin`）：
   `python terminal/tools/iq_pack.py --gguf <shard1> --out <pack_dir>`
   （0.2.16+ 源码自带 vendored gguf-py，GSQ 文件集不需要额外设置）
2. 引擎直跑（IQ/native pack **必须**带 `--native <shard1> --spec 2
   --prefill auto`；`--ple-gguf` 给含 `per_layer_token_embd.weight`
   的分片；`--expert-profile` 给环境自带
   `$CONDA_PREFIX/strata/data/expert-profile.bin`，缺了 decode 会拒启）：
   ```
   strata-engine --pack <pack_dir> --native <shard1> --ple-gguf <shard2> \
       --spec 2 --prefill auto --expert-profile $CONDA_PREFIX/strata/data/expert-profile.bin \
       --tokens "<逗号分隔 token id>" --gpu N --max-new 64 --max-context 4096 --greedy
   ```
3. 结果（v0.2.20 / 0.1.66，单卡）：131k prompt prefill **7,562 tok/s**、
   decode 173 tok/s；启动需 ~74GB 主机内存（PLE 26.8GiB mlock + 40GiB
   专家 arena 流式读入）；冷缓存首跑约 5-10 分钟。

## 国内 PyPI / torch 镜像

* `[pypi-options] index-url`：USTC PyPI 镜像（项目级 `.pixi/config.toml`
  的 `[pypi-config]` 同步设置；conda 侧 conda-forge 走 USTC anaconda 镜像）。
* torch 系 cu130 wheel 走 `[pypi-options] find-links`（等价 pip
  `--find-links`，flat-file 目录）：
  ```toml
  find-links = [
      { url = "https://mirrors.nju.edu.cn/pytorch/whl/cu130/torch" },
      ...（南大 4 个项目子目录）
      { url = "https://mirror.sjtu.edu.cn/pytorch-wheels/cu130/torch" },
      ...（上交 4 个项目子目录）
      { url = "https://mirrors.aliyun.com/pytorch-wheels/cu130" },
  ]
  ```
  - 官方源 `https://download.pytorch.org/whl/cu130` 国内不可达。
  - 三个国内镜像按下载速度排序，阿里云兜底。
  - 南大/上交的 wheel 文件在 `cu130/` 根下，但列表页按项目分子目录，
    故 find-links 指向各项目的子目录；阿里云是 flat-file，直接指向根目录。
  - find-links 是列表字段，workspace 级声明一次，vllm-cuda / sglang-cuda
    两个环境都生效（llama.cpp 环境无 pypi 依赖，不受影响）。
  - torch 版本写完整本地版本号（`==2.13.0+cu130`），
    find-links 源里 wheel 文件名带 `+cu130`。

## pixi 行为备忘（实测，pixi 0.76.0）

* 同名 env 冲突的 feature 列表里靠前者赢；标准平台须显式声明。
* TOML 简单 key 写在子表头之后时归属该子表。
* `activation.env` 的值支持 `$CONDA_PREFIX` / `$PATH` 等环境变量展开；
  vllm-cuda / sglang-cuda 用 `PATH = "$CONDA_PREFIX/<name>-cuda/bin:$PATH"`
  把 nvcc 放进 PATH（vLLM 的 `has_flashinfer()` 按 PATH 查找 nvcc）。
* task 不支持 bash 语法（deno_task_shell 驱动），多行脚本放
  `scripts/*.sh`，task 写 `bash $PIXI_PROJECT_ROOT/scripts/xxx.sh`。
* pypi-dependencies 用 PEP 440（`">=0.30,<0.31"`，conda 语法非法）。
* feature 级 `[feature.X.pypi-options]` 单值字段覆盖 workspace，
  列表字段（`find-links`、`extra-index-urls`）与 workspace 合并。
* conda-forge 的 g++ 无裸名符号链接，须用 `x86_64-conda-linux-gnu-g++`。
* 预发布依赖：sglang 依赖树含 `flash-attn-4` 的 b 系列预发布版，
  `[feature.sglang-cuda.pypi-options] prerelease-mode = "allow"`。

## lock 文件

`pixi.lock` 提交入库，保证可复现。改 `pixi.toml` 后 `pixi lock` 更新
（torch 四件套解析到哪个镜像以 lock 记录为准）。
