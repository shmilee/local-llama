# pixi 环境

`pixi.toml` 管理三个推理环境（llama.cpp / vLLM / SGLang），
全部源码或 PyPI 安装，系统依赖最小化（CUDA 环境仅依赖 NVIDIA 驱动）。

## 环境一览

| 环境 | feature | 后端 | 包来源 |
| ---- | ------- | ---- | ------ |
| `llamacpp-cuda`  | `llama-base` + `llamacpp-cuda`  | CUDA   | conda 工具链 + llama.cpp 源码编译 |
| `llamacpp-vulkan`| `llama-base` + `llamacpp-vulkan` | Vulkan | conda 工具链 + llama.cpp 源码编译 |
| `vllm-cuda`      | `vllm-cuda`                      | CUDA 13| PyPI（vLLM + torch cu130） |
| `sglang-cuda`    | `sglang-cuda`                    | CUDA 13| PyPI（SGLang + torch cu130） |

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
* 预发布依赖：sglang 硬 pin `cuda-tile==1.6.0rc5`，
  `[feature.sglang-cuda.pypi-options] prerelease-mode = "allow"`。

## lock 文件

`pixi.lock` 提交入库，保证可复现。改 `pixi.toml` 后 `pixi lock` 更新
（torch 四件套解析到哪个镜像以 lock 记录为准）。
