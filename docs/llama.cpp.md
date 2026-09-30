# llama.cpp

* 官网: <https://github.com/ggml-org/llama.cpp>

## 安装方式

### pixi 源码编译（本仓库）

`pixi.toml` 的 `llamacpp-cuda` / `llamacpp-vulkan` 环境，源码编译 + 安装：

```
pixi install -e llamacpp-cuda
pixi run   -e llamacpp-cuda llamacpp-build    # 下载源码并编译 + 安装
pixi run   -e llamacpp-cuda llamacpp-verify   # 验证安装（bin + --version + GPU 设备）
pixi run   -e llamacpp-cuda llamacpp-path     # 打印 llama-server 绝对路径
```

版本与构建细节见 `pixi.toml` 的 feature 注释（当前 `LLAMACPP_VERSION = "b10909"`，
b11224 decode 吞吐回退，待上游修复）。

### Arch Linux 包（备用）

* 服务器: <https://aur.archlinux.org/packages/llama.cpp-cuda>
* 笔记本: extra/llama-cpp 或 <https://aur.archlinux.org/packages/llama.cpp-vulkan-git> / <https://aur.archlinux.org/packages/llama.cpp-sycl>
  - CPU 版本最成熟 `pacman -S llama-cpp`
  - <https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md>
  - note: sycl 依赖 intel oneapi, like
    + intel-oneapi-dpcpp-cpp, intel-compute-runtime
    + intel-oneapi-mkl-sycl, level-zero-headers, onednn
  - note: sycl 的 cmake options
    ```
        -DGGML_SYCL=ON \
        -DGGML_SYCL_F16=ON \
        -DCMAKE_C_COMPILER=icx \
        -DCMAKE_CXX_COMPILER=icpx \
    ```

## 运行测试

```
llama-cli -m XX.gguf --mmproj XX-mmproj-BF16.gguf
```
