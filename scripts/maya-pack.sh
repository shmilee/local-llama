#!/usr/bin/env bash
# 从已下载的模型目录生成 Maya pack（幂等）
#
# 用法:
#   maya-pack ds4 <模型目录> [--force]   # DeepSeek Maya GGUF（产物 <目录>/maya-ds4）
#   maya-pack glm <模型目录> [--force]   # GLM-5.3-Flash Maya GGUF（产物 <目录>/pack）
#   maya-pack <模型目录> [--force]       # 默认 ds4
#
# 目录须可写：引擎从 <pack>/.. 找模型文件（上游 setup 同款）。
# GLM pack 需要 llama.cpp 的 gguf-py；默认取 $PIXI_PROJECT_ROOT/download/
# 下最新的 llama.cpp-*/gguf-py，也可用 MAYA_GGUF_PY 指定。
set -euo pipefail

FAMILY="ds4"
case "${1:-}" in
    ds4|glm) FAMILY="$1"; shift ;;
esac

MODEL_DIR=""
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) MODEL_DIR="$arg" ;;
    esac
done

[ -n "$MODEL_DIR" ] || MODEL_DIR="${MAYA_DS4_MODEL_DIR:-}"
[ -n "$MODEL_DIR" ] || {
    echo "FATAL: 未给模型目录。用法: maya-pack <ds4|glm> <模型目录>（或设 MAYA_DS4_MODEL_DIR）" >&2
    echo "       例: maya-pack glm /data/huggingface-downloads/GLM-5.3-Flash-Maya-GGUF/Maya-M" >&2
    exit 1
}
MODEL_DIR="$(readlink -f -- "$MODEL_DIR")"
[ -d "$MODEL_DIR" ] || { echo "FATAL: 模型目录不存在: $MODEL_DIR" >&2; exit 1; }
[ -w "$MODEL_DIR" ] || { echo "FATAL: 模型目录不可写（pack 要写在其中）: $MODEL_DIR" >&2; exit 1; }

APP_DIR="$CONDA_PREFIX/maya"
PY="$CONDA_PREFIX/bin/python3"
test -d "$APP_DIR" || { echo "FATAL: $APP_DIR 不存在（先跑 maya-build）" >&2; exit 1; }

# gguf-py（GLM 的 iq_pack 用；DeepSeek 的 pack_gguf 不需要）
find_gguf_py() {
    if [ -n "${MAYA_GGUF_PY:-}" ]; then echo "$MAYA_GGUF_PY"; return; fi
    local d
    d=$(ls -d "$PIXI_PROJECT_ROOT"/download/llama.cpp-*/gguf-py 2>/dev/null | tail -1 || true)
    if [ -n "$d" ] && [ -d "$d/gguf" ]; then echo "$d"; return; fi
    echo "FATAL: 找不到 llama.cpp 的 gguf-py；设 MAYA_GGUF_PY=<llama.cpp>/gguf-py" >&2
    exit 1
}

if [ "$FAMILY" = "glm" ]; then
    # ---- GLM-5.3-Flash（maya 主引擎，tools/iq_pack.py）----
    PACK="$MODEL_DIR/pack"
    PACK_FILES=(index.txt native_experts.txt dense.bin tokenizer/vocab.json tokenizer/merges.txt
                tokenizer/token_type.json tokenizer/chat_template.jinja)
    complete() {
        local f
        for f in "${PACK_FILES[@]}"; do test -f "$PACK/$f" || return 1; done
    }
    if [ "$FORCE" = 0 ] && complete; then
        echo "pack 已完整，跳过: $PACK（--force 重建）"
    else
        SHARD1=$(ls "$MODEL_DIR"/*-00001-of-*.gguf 2>/dev/null | head -1 || true)
        [ -n "$SHARD1" ] || { echo "FATAL: $MODEL_DIR 下没有 *-00001-of-*.gguf" >&2; exit 1; }
        GGUF_PY=$(find_gguf_py)
        echo "building GLM pack: $MODEL_DIR -> $PACK"
        MAYA_GGUF_PY="$GGUF_PY" "$PY" "$APP_DIR/tools/iq_pack.py" \
            --gguf "$SHARD1" --out "$PACK" --compat-bf16
    fi
    complete || { echo "FATAL: pack 不完整（缺 index.txt / native_experts.txt / dense.bin / tokenizer/*）" >&2; exit 1; }
    # 初始专家放置表（GLM-5.3-Flash 的通用 profile；引擎会边跑边学并写回）
    if [ -f "$APP_DIR/data/expert-profile-glm.bin" ] && [ ! -f "$PACK/expert-profile.bin" ]; then
        cp "$APP_DIR/data/expert-profile-glm.bin" "$PACK/expert-profile.bin"
        echo "seeded expert profile: $PACK/expert-profile.bin"
    fi
    echo "pack ready: $PACK"
    echo "run config 的 --glm-pack 指到这里，tokenizer 用 $PACK/tokenizer"
    exit 0
fi

# ---- DeepSeek-V4.1（maya-ds4，tools/ds4/pack_gguf.py）----
PACK_TOOL="$APP_DIR/tools/ds4/pack_gguf.py"
PROFILE="$APP_DIR/data/expert-profile-ds4.bin"
test -f "$PACK_TOOL" || { echo "FATAL: $PACK_TOOL 不存在（先跑 maya-build）" >&2; exit 1; }

PACK="$MODEL_DIR/maya-ds4"
complete() {
    test -f "$PACK/ds4.txt" && test -f "$PACK/tensors.txt" && \
    test -f "$PACK/engram.bin" && test -f "$PACK/tokenizer/vocab.json"
}
if [ "$FORCE" = 0 ] && complete; then
    echo "pack 已完整，跳过: $PACK（--force 重建）"
else
    N_GGUF=$(find "$MODEL_DIR" -maxdepth 1 -name '*.gguf' -type f | wc -l)
    [ "$N_GGUF" -gt 0 ] || { echo "FATAL: $MODEL_DIR 下没有 .gguf 文件" >&2; exit 1; }
    echo "building pack: $MODEL_DIR -> $PACK ($N_GGUF shards)"
    "$PY" "$PACK_TOOL" --model "$MODEL_DIR" --out "$PACK"
fi

# 初始专家放置表：与 maya.py 的 ds4_seed_profile 同规则（尺寸 = 层数 ×
# 路由专家数 × 4 才复制），服务启动时也会补，这里提前做便于校验。
if [ -f "$PROFILE" ] && [ ! -f "$PACK/expert-profile.bin" ]; then
    WANT=$("$PY" - "$PACK/ds4.txt" <<'PY'
import sys
g = {}
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        k, _, v = line.partition(" ")
        g[k] = v.strip()
    print(int(g["num_hidden_layers"]) * int(g["n_routed_experts"]) * 4)
except Exception:
    print(0)
PY
)
    if [ "$WANT" -gt 0 ] && [ "$(stat -c %s "$PROFILE")" = "$WANT" ]; then
        cp "$PROFILE" "$PACK/expert-profile.bin"
        echo "seeded expert profile: $PACK/expert-profile.bin"
    else
        echo "note: 未复制初始专家表（尺寸不匹配或几何未知；引擎首启会从零学习）"
    fi
fi

complete || { echo "FATAL: pack 不完整（缺少 ds4.txt / tensors.txt / engram.bin / tokenizer/vocab.json）" >&2; exit 1; }
echo "pack ready: $PACK"
echo "run config 的 --pack 指到这里，tokenizer 用 $PACK/tokenizer"
