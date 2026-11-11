#!/usr/bin/env bash
# 获取 stable-diffusion.cpp 源码（幂等，可重复执行）
# 所需环境变量（由 pixi 注入）: PIXI_PROJECT_ROOT, SDCPP_VERSION
# 可选环境变量:
#   SDCPP_TARBALL_URL       显式指定 tarball URL（设置后仅用此源，忽略内置列表）
#   SDCPP_SRC_MAX_ATTEMPTS  每个源的最大尝试次数（默认 3）
#   SDCPP_SRC_TIMEOUT       单次下载超时秒数（默认 900）
#
# 国内网络实测（T14p, 2026-10）：GitHub codeload（tarball）与 git 协议在长传输
# 中都会断流/静默截断（tarball ~7MB 处 EOF、git fetch-pack ~8MB 失败、
# gh-proxy ~2.6MB 失败），但也存在单次直连稳定传完 40MB+ 的窗口（~11min）。
# 备用通道：GitHub REST API（gh 认证时稳定）。
# 故采用「多源 + 每源有限重试 + 完整性校验」：
#   * 每次失败删除半成品（.part），绝不带病进入解压
#   * 下载后 gzip -t 校验，解压后校验关键目录
#   * 任一环节不通过都清场重来，保证幂等
set -euo pipefail

DL_DIR="$PIXI_PROJECT_ROOT/download"
SRC_DIR="$DL_DIR/stable-diffusion.cpp-$SDCPP_VERSION"
TARBALL="$DL_DIR/stable-diffusion.cpp-$SDCPP_VERSION.tar.gz"
BASE_URL="https://github.com/leejet/stable-diffusion.cpp/archive/refs/tags/$SDCPP_VERSION.tar.gz"
# 源列表：直连 + 常用国内加速镜像（顺序即优先级）
SOURCES=("$BASE_URL" "https://gh-proxy.com/$BASE_URL" "https://ghfast.top/$BASE_URL")
MAX_ATTEMPTS="${SDCPP_SRC_MAX_ATTEMPTS:-3}"
DL_TIMEOUT="${SDCPP_SRC_TIMEOUT:-900}"

mkdir -p "$DL_DIR"
cd "$DL_DIR"

# 通用单 URL 下载（多源重试链的最内层）
# $1=URL $2=输出文件 $3=日志前缀
try_download_url() {
    local url="$1" out="$2" label="${3:-dl}" i=0
    while [ $i -lt "$MAX_ATTEMPTS" ]; do
        i=$((i+1))
        echo "[sdcpp-src] [$label] 尝试 $i/$MAX_ATTEMPTS: $url"
        if curl -fL --max-time "$DL_TIMEOUT" -o "$out.part" "$url" 2>/dev/null; then
            if gzip -t "$out.part" 2>/dev/null; then
                mv "$out.part" "$out"
                echo "[sdcpp-src] [$label] 下载完整: $(du -h "$out" | cut -f1)"
                return 0
            fi
            echo "[sdcpp-src] [$label] 截断（gzip 校验失败），重试"
        else
            echo "[sdcpp-src] [$label] 下载失败（断流/超时），重试"
        fi
        rm -f "$out.part"
        sleep 15
    done
    return 1
}

# --- 主 tarball 下载（已有完整文件则跳过）---
if [ ! -f "$TARBALL" ] || ! gzip -t "$TARBALL" 2>/dev/null; then
    rm -f "$TARBALL" "$TARBALL.part"
    if [ -n "${SDCPP_TARBALL_URL:-}" ]; then
        SOURCES=("$SDCPP_TARBALL_URL")
    fi
    ok=1
    for url in "${SOURCES[@]}"; do
        if try_download_url "$url" "$TARBALL" "main"; then ok=0; break; fi
    done
    [ "$ok" -eq 0 ] || { echo "FATAL: 所有下载源均失败（可设 SDCPP_TARBALL_URL 指定其他源后重试）" >&2; exit 1; }
fi

# --- 解压（已有完整源码目录则跳过）---
if [ ! -d "$SRC_DIR" ]; then
    tar -xzf "$TARBALL"
fi

# --- 解压完整性校验 ---
for sub in src examples ggml thirdparty; do
    if [ ! -d "$SRC_DIR/$sub" ]; then
        echo "FATAL: $SRC_DIR/$sub 缺失（tarball 可能不完整），清场重试" >&2
        rm -rf "$SRC_DIR" "$TARBALL"
        exit 1
    fi
done

# --- ggml 子模块补全 ---
# 1014 起 ggml 从 vendored 目录改为 git submodule（指向 leejet/ggml patched fork），
# GitHub tarball 不含子模块内容。若 ggml/ 为空（无 ggml-impl.h），从 API 解析
# pin 的 commit 后多源下载对应 archive 补入。
# ggml 布局探测：新布局（1014+，ggml target 定义于 src/）impl.h 在 src/ 下；
# 旧布局可能在根目录。两者任一存在即视为完整。
ggml_present() {
    local d="$1"
    [ -f "$d/ggml-impl.h" ] || [ -f "$d/src/ggml-impl.h" ]
}
ensure_ggml() {
    local ggml_dir="$SRC_DIR/ggml"
    if ggml_present "$ggml_dir"; then
        echo "[sdcpp-src] ggml 已就位（vendored 或已补全）"
        return 0
    fi
    local sha
    sha=$(curl -fsSL --http1.1 --max-time 30 \
        "https://api.github.com/repos/leejet/stable-diffusion.cpp/contents/ggml?ref=$SDCPP_VERSION" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['sha'] if d['type']=='submodule' else '')" 2>/dev/null)
    if [ -z "$sha" ]; then
        echo "FATAL: 无法解析 ggml submodule pin（API 不可达？），且本地 ggml/ 为空" >&2
        return 1
    fi
    local gbase="https://github.com/leejet/ggml/archive/$sha.tar.gz"
    local gsources=("$gbase" "https://gh-proxy.com/$gbase" "https://ghfast.top/$gbase")
    local gtmp="$DL_DIR/ggml-$sha.tar.gz"
    if [ ! -f "$gtmp" ] || ! gzip -t "$gtmp" 2>/dev/null; then
        rm -f "$gtmp" "$gtmp.part"
        local gok=1
        for gurl in "${gsources[@]}"; do
            if try_download_url "$gurl" "$gtmp" "ggml"; then gok=0; break; fi
        done
        [ "$gok" -eq 0 ] || { echo "FATAL: ggml archive 所有源均失败（可手动下载 $gbase 到 $gtmp 后重试）" >&2; return 1; }
    fi
    # 解压并落位（archive 顶层为 ggml-<sha>/）
    local gwork="$DL_DIR/.ggml-extract"
    rm -rf "$gwork" "$ggml_dir"
    mkdir -p "$gwork"
    tar -xzf "$gtmp" -C "$gwork"
    mv "$gwork"/ggml-* "$ggml_dir"
    rmdir "$gwork"
    ggml_present "$ggml_dir" || { echo "FATAL: ggml 落位后仍缺 ggml-impl.h" >&2; return 1; }
    echo "[sdcpp-src] ggml 子模块已补全: $sha"
    return 0
}
ensure_ggml

# --- cutlass 子模块补全（仅 CUDA 后端）---
# 1086 起 CUDA 后端默认要求 thirdparty/cutlass（INT8/W4/BF16 GEMM + CuTe
# attention 的快速内核，上游标注 tested with 3.9.2），头文件缺失时 CMake
# FATAL。GitHub tarball 不含子模块内容，故对 cuda 后端从 API 解析 pin 的
# commit 后多源下载对应 archive 补入（与 ensure_ggml 同模式）。
# vulkan 后端不使用 cutlass，跳过以免无谓大下载。
ensure_cutlass() {
    [ "${SDCPP_BACKEND:-}" = "cuda" ] || return 0
    local cut_dir="$SRC_DIR/thirdparty/cutlass"
    # 与上游 cutlass.cmake 的完整性检查一致的判定（两个关键头文件）
    if [ -f "$cut_dir/include/cutlass/gemm/kernel/default_gemm_universal_with_visitor.h" ] \
       && [ -f "$cut_dir/include/cute/tensor.hpp" ]; then
        echo "[sdcpp-src] cutlass 已就位"
        return 0
    fi
    local sha
    sha=$(curl -fsSL --http1.1 --max-time 30 \
        "https://api.github.com/repos/leejet/stable-diffusion.cpp/contents/thirdparty/cutlass?ref=$SDCPP_VERSION" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['sha'] if d['type']=='submodule' else '')" 2>/dev/null)
    if [ -z "$sha" ]; then
        echo "FATAL: 无法解析 cutlass submodule pin（API 不可达？），且本地 thirdparty/cutlass 为空" >&2
        return 1
    fi
    local cbase="https://github.com/NVIDIA/cutlass/archive/$sha.tar.gz"
    local csources=("$cbase" "https://gh-proxy.com/$cbase" "https://ghfast.top/$cbase")
    local ctmp="$DL_DIR/cutlass-$sha.tar.gz"
    if [ ! -f "$ctmp" ] || ! gzip -t "$ctmp" 2>/dev/null; then
        rm -f "$ctmp" "$ctmp.part"
        local cok=1
        for gurl in "${csources[@]}"; do
            if try_download_url "$gurl" "$ctmp" "cutlass"; then cok=0; break; fi
        done
        [ "$cok" -eq 0 ] || { echo "FATAL: cutlass archive 所有源均失败（可手动下载 $cbase 到 $ctmp 后重试）" >&2; return 1; }
    fi
    # 解压并落位（archive 顶层为 cutlass-<sha>/）
    local cwork="$DL_DIR/.cutlass-extract"
    rm -rf "$cwork" "$cut_dir"
    mkdir -p "$cwork"
    tar -xzf "$ctmp" -C "$cwork"
    mv "$cwork"/cutlass-* "$cut_dir"
    rmdir "$cwork"
    [ -f "$cut_dir/include/cutlass/gemm/kernel/default_gemm_universal_with_visitor.h" ] \
        && [ -f "$cut_dir/include/cute/tensor.hpp" ] \
        || { echo "FATAL: cutlass 落位后仍缺关键头文件" >&2; return 1; }
    echo "[sdcpp-src] cutlass 子模块已补全: $sha"
    return 0
}
ensure_cutlass

echo "source ready: $SRC_DIR"
