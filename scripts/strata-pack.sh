#!/usr/bin/env bash
# 准备 Strata run pack（幂等：已完整则跳过，--force 强制重建）
#
# run config 引用下列目录（缺 tokenizer/vocab.json 时终端拒绝启动：
# "the model's tokenizer is missing ...; run setup again"）：
#   strata-packs/qwen38fn-iq3xxs   Qwen3.8-Flash-Next   (terminal/tools/iq_pack.py，native，~1.5G，~1 分钟)
#
# 用法：
#   pixi run -e strata-cuda strata-pack            # 备 qwen3.8-flash-next
#   pixi run -e strata-cuda strata-pack qwen       # 同上
#   bash scripts/strata-pack.sh [qwen] [--force]
#
# 模型文件只读。路径不靠猜，从 config 推导（= 引擎运行时实际读的文件）：
#   qwen:  config/strata-qwen.json 的 --native（shard1）/ --ple-gguf（shard2）
#
# 文档：docs/strata.md「准备 pack」一节（手工命令与本脚本等价）。
# 0.2.14 起上游移除 DeepSeek（dsv41）引擎，本脚本不再生成 dsv41 pack。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRATA_VERSION="${STRATA_VERSION:-v0.2.20}"
V="${STRATA_VERSION#v}"
SRC_DIR="$ROOT/download/Strata-$V"
PACKS_DIR="$ROOT/strata-packs"
QWEN_PACK="$PACKS_DIR/qwen38fn-iq3xxs"

die() { echo "FATAL: $*" >&2; exit 1; }

TARGET="qwen"; FORCE=0
for a in "$@"; do
    case "$a" in
        all|qwen)   TARGET="qwen" ;;
        --force|-f) FORCE=1 ;;
        -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
        *) die "未知参数 '$a'（用法：$0 [qwen] [--force]）" ;;
    esac
done

# --- Strata 源码（缺则跑 strata-src.sh：下载 + 解压，幂等）---
if [ ! -d "$SRC_DIR" ]; then
    echo "== Strata 源码缺失，先跑 strata-src.sh（下载 + 解压 ${V}）=="
    PIXI_PROJECT_ROOT="$ROOT" STRATA_VERSION="$STRATA_VERSION" \
        bash "$ROOT/scripts/strata-src.sh"
fi
IQ_PACK="$SRC_DIR/terminal/tools/iq_pack.py"
test -f "$IQ_PACK" || die "$IQ_PACK 缺失（源码目录不完整或不是 0.2.16+ 布局？删掉 download/Strata-$V 重跑）"

# --- gguf-py（iq_pack 的 --compat-bf16 等转换路径需要；GSQ-RCO 文件集不触发。
#     0.2.16+ 源码自带 vendored 的 engine/third_party/strata-gguf-py）---
find_gguf_py() {
    local c
    if [ -d "$SRC_DIR/engine/third_party/strata-gguf-py/gguf" ]; then
        printf '%s\n' "$SRC_DIR/engine/third_party/strata-gguf-py"
        return 0
    fi
    c="$(ls -d "$ROOT"/download/llama.cpp-*/gguf-py/gguf 2>/dev/null | head -1 || true)"
    [ -n "$c" ] && { printf '%s\n' "$(dirname "$c")"; return 0; }
    return 1
}
if [ -z "${STRATA_GGUF_PY:-}" ]; then
    STRATA_GGUF_PY="$(find_gguf_py || true)"
fi
if [ -n "${STRATA_GGUF_PY:-}" ]; then
    export STRATA_GGUF_PY
    echo "gguf-py: $STRATA_GGUF_PY"
else
    echo "note: 未找到 gguf-py（当前 GSQ-RCO 文件集不触发它；只有 --compat-bf16 等转换路径需要，届时设 STRATA_GGUF_PY）"
fi

# --- python（iq_pack 需要 numpy；优先 strata-cuda 环境）---
if [ -n "${CONDA_PREFIX:-}" ] && [ -x "$CONDA_PREFIX/bin/python3" ]; then
    PY=("$CONDA_PREFIX/bin/python3")
elif command -v pixi >/dev/null 2>&1; then
    PY=(pixi run -m "$ROOT" -e strata-cuda python)
else
    PY=(python3)
fi
"${PY[@]}" -c "import numpy" >/dev/null 2>&1 \
    || die "python 缺 numpy（iq_pack.py 需要）。先在 strata-cuda 环境跑：pixi install -e strata-cuda"

# run config 里的相对路径按 config 的 cwd 解析（config 是 "." = 仓库根）
abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$ROOT/$1" ;; esac; }

# ================= qwen3.8-flash-next =================

qwen_complete() {
    [ -f "$QWEN_PACK/index.txt" ] && [ -f "$QWEN_PACK/native_experts.txt" ] \
        && [ -f "$QWEN_PACK/tokenizer/vocab.json" ]
}

pack_qwen() {
    local s1 s2
    # 已完整则跳过（无需模型文件）
    if qwen_complete && [ "$FORCE" = "0" ]; then
        echo "qwen38fn: 已完整，跳过（--force 重建）: $QWEN_PACK"
        return 0
    fi
    # 路径取自 run config（引擎运行时读的就是这两个文件，pack 必须与之一致）
    local cfg="$ROOT/config/strata-qwen.json"
    test -f "$cfg" || die "缺少 run config：$cfg"
    local paths
    paths="$( "${PY[@]}" -c '
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8")).get("args", [])
for f in ("--native", "--ple-gguf"):
    i = a.index(f) if f in a else -1
    print(a[i + 1] if i >= 0 else "")
' "$cfg")" || die "解析 $cfg 失败"
    s1="$(sed -n 1p <<<"$paths")"
    s2="$(sed -n 2p <<<"$paths")"
    [ -n "$s1" ] || die "$cfg 的 args 里没有 --native"
    s1="$(abs "$s1")"; s2="$(abs "$s2")"
    [ -n "$s2" ] || s2="${s1/00001-of-/00002-of-}"
    # 不 resolve symlink（HF 快照 blob 名会破坏 iq_pack 的 -0000N-of-0000M 兄弟分片发现）
    [ -f "${s1}" ] || die "qwen shard1 不存在：${s1}（来自 ${cfg} 的 --native；模型要下载到该路径，见 docs/models.md）"
    [ -f "${s2}" ] || die "qwen shard2 缺失：${s2}（来自 --ple-gguf；下载未完成？）"
    [ "$FORCE" = "1" ] && rm -rf "$QWEN_PACK"
    echo "qwen38fn: iq_pack.py  native（专家不复制，运行时直读 GGUF）"
    echo "  shard1: $s1"
    echo "  shard2: $s2"
    echo "  输出:   $QWEN_PACK"
    echo "  开始（约 1 分钟）..."
    # 不加 --experts-bin：i-quant 走 native pack（docs/strata.md）
    "${PY[@]}" "$IQ_PACK" --gguf "$s1" --out "$QWEN_PACK"
    verify_pack "$QWEN_PACK" qwen38fn
}

# ================= 校验 =================

verify_pack() {
    local out="$1" label="$2" f missing=0
    local need="index.txt native_experts.txt dense.bin
tokenizer/vocab.json tokenizer/merges.txt tokenizer/token_type.json
tokenizer/tokenizer.json tokenizer/chat_template.jinja"
    for f in $need; do
        if [ ! -f "$out/$f" ]; then
            echo "  MISSING: $f" >&2; missing=1
        fi
    done
    [ "$missing" = "0" ] || die "$label pack 产物不完整（见上）"
    "${PY[@]}" -c '
import json, sys
d = sys.argv[1]
v = json.load(open(d + "/vocab.json", encoding="utf-8"))
assert isinstance(v, dict) and v, "vocab.json 应为非空 {token: id}"
m = open(d + "/merges.txt", encoding="utf-8").read()
assert m.strip(), "merges.txt 为空"
t = json.load(open(d + "/token_type.json"))
assert isinstance(t, list) and len(t) == len(v), "token_type.json 与 vocab 数量不符"
json.load(open(d + "/tokenizer.json", encoding="utf-8"))
print("  tokenizer ok: vocab %d, merges %d" % (len(v), len(m.splitlines())))
' "$out/tokenizer" || die "$label tokenizer 校验失败"
    echo "  $label pack ok: $(du -sh "$out" 2>/dev/null | cut -f1)  $out"
}

# ================= 主流程 =================
echo "Strata 源码: $SRC_DIR"
echo "python: ${PY[*]}"
echo

pack_qwen

echo
echo "== 完成 =="
qwen_complete && echo "  qwen38fn-iq3xxs  $QWEN_PACK          <- config/strata-qwen.json"
echo "下一步（docs/strata.md）："
echo "  nvidia-smi 选空闲卡后：pixi run -e strata-cuda strata serve --config config/strata-qwen.json --port <端口>"
