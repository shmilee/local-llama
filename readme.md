# local-llama

本地 LLM 推理环境：[pixi](https://pixi.sh) 管理 llama.cpp / vLLM / SGLang
三种推理后端，[llama-swap](https://github.com/mostlygeek/llama-swap)
做多模型/多后端路由（OpenAI 兼容 API）。

## 目录结构

```
pixi.toml / pixi.lock      pixi 环境定义（三个推理环境）+ lock
scripts/                   pixi task 脚本（build/verify/prepare）
config/                    llama-swap 配置文件（PRO6000 / T14p）
llama-swap-start.sh        llama-swap 启动脚本
bin/                       llama-swap 二进制（不入库）
logs/                      llama-swap 运行日志（不入库）
docs/                      文档
TODO.md                    待办跟踪
```

## 快速上手

```
# 1. 安装推理环境（按需选一个或多个）
pixi install -e llamacpp-cuda     # llama.cpp（CUDA，源码编译）
pixi install -e vllm-cuda         # vLLM（PyPI + torch cu130）
pixi install -e sglang-cuda       # SGLang（PyPI + torch cu130）

# 2. 验证
pixi run -e llamacpp-cuda  llamacpp-build && pixi run -e llamacpp-cuda  llamacpp-verify
pixi run -e vllm-cuda      vllm-cuda-verify
pixi run -e sglang-cuda    sglang-cuda-verify

# 3. 启动路由服务
./llama-swap-start.sh -n PRO6000 -p 12435
```

## 文档

| 文档 | 内容 |
| ---- | ---- |
| [docs/pixi-environments.md](docs/pixi-environments.md) | 三个 pixi 环境、CUDA 自包含策略、国内镜像 |
| [docs/llama-swap.md](docs/llama-swap.md) | 部署、conf 结构、模型清单 |
| [docs/llama.cpp.md](docs/llama.cpp.md) | llama.cpp 安装/编译/运行 |
| [docs/vllm.md](docs/vllm.md) | vLLM 启动参数、工具链要点、已知坑 |
| [docs/sglang.md](docs/sglang.md) | SGLang 启动参数、混合注意力（GDN）要点 |
| [docs/models.md](docs/models.md) | 模型挑选、量化说明、下载记录、chat templates |
| [docs/speed-report.md](docs/speed-report.md) | 速度测试报告 |

## TTS

MOSS?
