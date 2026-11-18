#!/usr/bin/env bash
# 准备两个 Strata run pack（幂等：已完整则跳过，--force 强制重建）
#
# run config 引用下列两个目录（缺 tokenizer/vocab.json 时终端拒绝启动：
# "the model's tokenizer is missing ...; run setup again"）：
#   strata-packs/qwen38fn-iq3xxs   Qwen3.8-Flash-Next   (tools/iq_pack.py，native，~1.5G，~1 分钟)
#   strata-packs/dsv41-iq2xxs      DeepSeek-V4.1-Flash  (tools/dsv41/pack_gguf.py，几 MB，几分钟)
#
# 用法：
#   pixi run -e strata-cuda strata-pack            # 两个都备
#   pixi run -e strata-cuda strata-pack qwen       # 只 qwen3.8-flash-next
#   pixi run -e strata-cuda strata-pack ds41       # 只 deepseek-v4.1
#   bash scripts/strata-pack.sh [all|qwen|ds41] [--force]
#
# 模型文件只读。路径不靠猜，从 config 推导（= 引擎运行时实际读的文件）：
#   qwen:  config/strata-qwen.json 的 --native（shard1）/ --ple-gguf（shard2）
#   ds41:  已有 pack 的 strata-packs/dsv41-iq2xxs/ds4.txt 的 model_dir（re-pack 场景）；
#          首建 pack 时取 config/llama-swap-config-*.yaml 的 "models_dir" + /DeepSeek-V4.1-Flash
#   ds41 目录内的分片 / Engram / dspark 按文件名识别（of-00006 布局，
#   下载记录见 docs/models.md；dspark 存在则自动打包进去）
#
# 文档：docs/strata.md「准备 pack」两节（手工命令与本脚本等价）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRATA_VERSION="${STRATA_VERSION:-v0.2.4.2}"
V="${STRATA_VERSION#v}"
SRC_DIR="$ROOT/download/Strata-$V"
PACKS_DIR="$ROOT/strata-packs"
QWEN_PACK="$PACKS_DIR/qwen38fn-iq3xxs"
DS41_PACK="$PACKS_DIR/dsv41-iq2xxs"

die() { echo "FATAL: $*" >&2; exit 1; }

TARGET="all"; FORCE=0
for a in "$@"; do
    case "$a" in
        all|qwen|ds41) TARGET="$a" ;;
        --force|-f)    FORCE=1 ;;
        -h|--help)     sed -n '2,23p' "$0"; exit 0 ;;
        *) die "未知参数 '$a'（用法：$0 [all|qwen|ds41] [--force]）" ;;
    esac
done
DO_QWEN=0; DO_DS41=0
[ "$TARGET" = "all"  ] && DO_QWEN=1 && DO_DS41=1
[ "$TARGET" = "qwen" ] && DO_QWEN=1
[ "$TARGET" = "ds41" ] && DO_DS41=1

# --- Strata 源码（缺则跑 strata-src.sh：下载 + 解压，幂等）---
if [ ! -d "$SRC_DIR" ]; then
    echo "== Strata 源码缺失，先跑 strata-src.sh（下载 + 解压 $V）=="
    PIXI_PROJECT_ROOT="$ROOT" STRATA_VERSION="$STRATA_VERSION" \
        bash "$ROOT/scripts/strata-src.sh"
fi
test -f "$SRC_DIR/tools/iq_pack.py" || die "$SRC_DIR/tools/iq_pack.py 缺失（源码目录不完整？删掉 download/Strata-$V 重跑）"
test -f "$SRC_DIR/tools/dsv41/pack_gguf.py" || die "$SRC_DIR/tools/dsv41/pack_gguf.py 缺失（源码目录不完整？删掉 download/Strata-$V 重跑）"

# --- gguf-py（pinned llama.cpp commit 的 gguf-py/；iq_pack 的 --compat-bf16
#     路径需要。strata-src.sh 已随源码预下载解压，这里只负责定位/导出）---
find_gguf_py() {
    local GG_COMMIT="" c
    if grep -q "FetchContent_Declare(strata_llamacpp" "$SRC_DIR/CMakeLists.txt" 2>/dev/null; then
        GG_COMMIT=$(grep -oE "GIT_TAG [0-9a-f]{40}" "$SRC_DIR/CMakeLists.txt" | awk '{print $2}' | head -1)
    fi
    if [ -n "$GG_COMMIT" ] && [ -d "$ROOT/download/llama.cpp-${GG_COMMIT:0:12}/gguf-py/gguf" ]; then
        printf '%s\n' "$ROOT/download/llama.cpp-${GG_COMMIT:0:12}/gguf-py"
        return 0
    fi
    c="$(ls -d "$ROOT"/download/llama.cpp-*/gguf-py/gguf 2>/dev/null | head -1 || true)"
    [ -n "$c" ] && { printf '%s\n' "$(dirname "$c")"; return 0; }
    return 1
}
if [ -z "${STRATA_GGUF_PY:-}" ]; then
    STRATA_GGUF_PY="$(find_gguf_py || true)"
    # 只有 tarball 时解压一次（strata-src.sh 幂等：下载/解压/BUILD_ID 都检查存在）
    if [ -z "$STRATA_GGUF_PY" ] && ls "$ROOT"/download/llama.cpp-*.tar.gz >/dev/null 2>&1; then
        PIXI_PROJECT_ROOT="$ROOT" STRATA_VERSION="$STRATA_VERSION" bash "$ROOT/scripts/strata-src.sh" >/dev/null
        STRATA_GGUF_PY="$(find_gguf_py || true)"
    fi
fi
if [ -n "${STRATA_GGUF_PY:-}" ]; then
    export STRATA_GGUF_PY
    echo "gguf-py: $STRATA_GGUF_PY"
else
    echo "note: 未找到 pinned gguf-py（当前 GSQ-RCO 文件集不触发它；只有 --compat-bf16 等转换路径需要，届时设 STRATA_GGUF_PY）"
fi

# --- python（iq_pack 需要 numpy；优先 strata-cuda 环境）---
if [ -n "${CONDA_PREFIX:-}" ] && [ -x "$CONDA_PREFIX/bin/python3" ]; then
    PY=("$CONDA_PREFIX/bin/python3")
elif command -v pixi >/dev/null 2>&1; then
    PY=(pixi run -m "$ROOT" -e strata-cuda python)
else
    PY=(python3)
fi
if [ "$DO_QWEN" = "1" ] && ! "${PY[@]}" -c "import numpy" >/dev/null 2>&1; then
    die "python 缺 numpy（iq_pack.py 需要）。先在 strata-cuda 环境跑：pixi install -e strata-cuda"
fi

# run config 里的相对路径按 config 的 cwd 解析（两个 config 都是 "." = 仓库根）
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
    [ -f "$s1" ] || die "qwen shard1 不存在：$s1（来自 $cfg 的 --native；模型要下载到该路径，见 docs/models.md）"
    [ -f "$s2" ] || die "qwen shard2 缺失：$s2（来自 --ple-gguf；下载未完成？）"
    [ "$FORCE" = "1" ] && rm -rf "$QWEN_PACK"
    echo "qwen38fn: iq_pack.py  native（专家不复制，运行时直读 GGUF）"
    echo "  shard1: $s1"
    echo "  shard2: $s2"
    echo "  输出:   $QWEN_PACK"
    echo "  开始（约 1 分钟）..."
    # 不加 --experts-bin：i-quant 走 native pack（docs/strata.md）
    "${PY[@]}" "$SRC_DIR/tools/iq_pack.py" --gguf "$s1" --out "$QWEN_PACK"
    verify_pack "$QWEN_PACK" qwen38fn
}

# ================= deepseek-v4.1 =================

ds41_complete() {
    [ -f "$DS41_PACK/ds4.txt" ] && [ -f "$DS41_PACK/tensors.txt" ] \
        && [ -f "$DS41_PACK/tokenizer/vocab.json" ]
}

pack_ds41() {
    local d f engram dspark
    # 已完整则跳过（无需模型文件）
    if ds41_complete && [ "$FORCE" = "0" ]; then
        echo "dsv41: 已完整，跳过（--force 重建）: $DS41_PACK"
        return 0
    fi
    # 模型目录：优先已有 pack 的 ds4.txt 的 model_dir（re-pack 时引擎读的就是它）；
    # 首建时 ds41 的 run config 不写模型路径，取 yaml 的 "models_dir" 宏
    d=""
    if [ -f "$DS41_PACK/ds4.txt" ]; then
        d="$(grep -m1 '^model_dir ' "$DS41_PACK/ds4.txt" | awk '{print $2}')"
        [ -n "$d" ] && [ -d "$d" ] || d=""
    fi
    if [ -z "$d" ]; then
        local md="" y
        for y in "$ROOT"/config/llama-swap-config-*.yaml; do
            [ -f "$y" ] || continue
            md="$(sed -n 's/^[[:space:]]*"models_dir"[[:space:]]*:[[:space:]]*//p' "$y" | head -1 | tr -d '"')"
            [ -n "$md" ] && break
        done
        [ -n "$md" ] || die "ds41 首建 pack 需要模型目录：已有 pack 的 ds4.txt 无有效 model_dir，config/*.yaml 也没有 models_dir 宏"
        d="$(abs "$md")/DeepSeek-V4.1-Flash"
    fi
    [ -d "$d" ] || die "ds4.1 模型目录不存在：$d"
    # 四分片/六分片以外的布局不认（本机是 of-00006：1 元数据 + 2-5 模型 + 6 Engram）
    local shards=()
    for i in 1 2 3 4 5; do
        f="$(find "$d" -maxdepth 1 \( -type f -o -type l \) -name "*-0000${i}-of-00006.gguf" 2>/dev/null | head -1 || true)"
        [ -n "$f" ] && [ -f "$f" ] \
            || die "模型目录 $d 缺分片 *-0000${i}-of-00006.gguf（下载未完成或布局不是 of-00006？四分片布局的 --engram-meta 需另下 unsloth 元数据分片，见 docs/strata.md）"
        shards+=("$f")
    done
    # Engram 表（110G 本体只读 header 进 pack，数据运行时直读）
    engram="$(find "$d" -maxdepth 1 -type f -name '*Engram*.gguf' 2>/dev/null | head -1 || true)"
    if [ -z "$engram" ]; then
        local link="$d/DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-00006-of-00006.gguf"
        [ -L "$link" ] && engram="$(readlink -f "$link")"
    fi
    [ -n "$engram" ] && [ -f "$engram" ] \
        || die "模型目录 $d 找不到 Engram gguf（DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf）"
    [ "$engram" != "$d/$(basename "$engram")" ] && \
        echo "  note: Engram 在模型目录外：$engram（tensors.txt 用相对路径引用）"
    # DSpark drafter（可选；IST-DAS 量化需要 noise token / markov rank）
    dspark="$(find "$d" -maxdepth 1 \( -type f -o -type l \) -name 'dspark-*.gguf' 2>/dev/null | head -1 || true)"

    [ "$FORCE" = "1" ] && rm -rf "$DS41_PACK"
    local args=(--model "$d" --shards "${shards[@]}" --engram "$engram" \
                --engram-meta "${shards[0]}" --out "$DS41_PACK")
    [ -n "$dspark" ] && args+=(--dspark-gguf "$dspark" --dspark-noise-token 128799 --dspark-markov-rank 256)
    echo "dsv41: pack_gguf.py（只写 header/表，产物几 MB）"
    echo "  目录:   $d（shards 00001-00005，00001 兼 engram-meta）"
    echo "  engram: $engram"
    echo "  dspark: ${dspark:-无（--dspark auto 将不启用，decode 稍慢）}"
    echo "  输出:   $DS41_PACK"
    echo "  开始（几分钟）..."
    "${PY[@]}" "$SRC_DIR/tools/dsv41/pack_gguf.py" "${args[@]}"
    verify_pack "$DS41_PACK" dsv41
}

# ================= 校验 =================

verify_pack() {
    local out="$1" label="$2" f missing=0
    local need
    case "$label" in
        qwen38fn) need="index.txt native_experts.txt dense.bin
tokenizer/vocab.json tokenizer/merges.txt tokenizer/token_type.json
tokenizer/tokenizer.json tokenizer/chat_template.jinja" ;;
        dsv41)    need="ds4.txt tensors.txt engram.bin
tokenizer/vocab.json tokenizer/merges.txt tokenizer/token_type.json
tokenizer/tokenizer.json tokenizer/chat_template.jinja" ;;
    esac
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

[ "$DO_QWEN" = "1" ] && pack_qwen
[ "$DO_DS41" = "1" ] && { [ "$DO_QWEN" = "1" ] && echo; pack_ds41; }

echo
echo "== 完成 =="
qwen_complete && echo "  qwen38fn-iq3xxs  $QWEN_PACK          <- config/strata-qwen.json"
ds41_complete && echo "  dsv41-iq2xxs     $DS41_PACK  <- config/strata-ds41.json"
echo "下一步（docs/strata.md）："
echo "  nvidia-smi 选空闲卡后：pixi run -e strata-cuda strata serve --config config/strata-{qwen,ds41}.json --port <端口>"
