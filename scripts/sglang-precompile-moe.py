#!/usr/bin/env python3
"""flashinfer CUTLASS fused-MoE 模块（SM120）JIT 预编译。

SM120 上 sglang 的首个 forward 会在进程内用 nvcc 编译该模块
（~96 个对象文件，分钟级，伴随主机内存分配突发）。模型加载后
cgroup 内存质量大（PLE 表 ~64G shmem），共享集群上编译期的
内存压力可能触发 systemd-oomd 杀掉 scheduler。本脚本在模型加载
前独立构建同一模块：cgroup 无模型内存在场，编译可安全完成。

进度按对象文件落盘到 flashinfer 缓存，被中断后重跑即续编；
模块完整时本脚本是秒级 no-op。

用法（sglang-cuda 环境内，目标卡空闲）:
    CUDA_VISIBLE_DEVICES=<n> python scripts/sglang-precompile-moe.py
"""
import os
import time

# 与 sglang 相同的 flashinfer 缓存基目录（flashinfer 自会追加 .cache/flashinfer）
os.environ.setdefault(
    "FLASHINFER_WORKSPACE_BASE", os.path.expanduser("~/.cache/sglang")
)

import torch

torch.cuda.init()
torch.cuda.set_device(0)
print("cuda ready:", torch.cuda.get_device_name(0), flush=True)

from flashinfer.fused_moe.core import get_cutlass_fused_moe_module

t0 = time.time()
get_cutlass_fused_moe_module(backend="120")
print("MODULE READY in %.1fs" % (time.time() - t0), flush=True)
