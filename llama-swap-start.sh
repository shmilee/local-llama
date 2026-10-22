#!/bin/bash
# 启动 llama-swap。
# 目录布局（相对本脚本所在目录）:
#   bin/llama-swap          二进制命令
#   config/llama-swap-config-<name>.yaml   配置文件
#   logs/llama-swap-<name>-<date>.log      运行日志


usage() {
    echo "Start llama-swap with the given config and port."
    echo ""
    echo "Usage: $0 -n <name> [-p <port>]"
    echo ""
    echo "Options:"
    echo "  -n <name>    Config name (config/llama-swap-config-<name>.yaml)"
    echo "  -p <port>    Listen port (default: 12435)"
    echo "  -h           Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -n PRO6000"
    echo "  $0 -n T14p -p 12434"
}

CONFIG_NAME=""
PORT="12435"

PARSED=$(getopt -o "n:p:h" -l "" -n "$0" -- "$@") || exit 1
eval set -- "$PARSED"

while true; do
    case $1 in
        -n) CONFIG_NAME="$2"; shift 2 ;;
        -p) PORT="$2"; shift 2 ;;
        -h) usage; exit 0 ;;
        --) shift; break ;;
        *) echo "Invalid option: $1"; exit 1 ;;
    esac
done

if [ -z "$CONFIG_NAME" ]; then
    echo "Error: -n <name> is required"
    echo ""
    usage
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/bin/llama-swap"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/llama-swap-${CONFIG_NAME}-$(date +%F).log"

# Resolve config: cwd or script dir (deduplicated)
if [ ! -x "$BIN" ]; then
    echo "Error: binary not found or not executable: $BIN"
    exit 1
fi
CONFIG_FILE=""
if [ "$PWD" = "$SCRIPT_DIR" ]; then
    searchPaths=("$PWD")
else
    searchPaths=("$PWD" "$SCRIPT_DIR")
fi
for searchPath in "${searchPaths[@]}"; do
    candidate="${searchPath}/config/llama-swap-config-${CONFIG_NAME}.yaml"
    if [ -f "$candidate" ]; then
        echo "Looking for config '$candidate': Found"
        CONFIG_FILE="$candidate"
        break
    else
        echo "Looking for config '$candidate': No such file"
    fi
done

if [ -z "$CONFIG_FILE" ]; then
    echo "Error: config file not found: config/llama-swap-config-${CONFIG_NAME}.yaml"
    exit 1
fi

# --- 密钥：从 secrets.env 读取并 export，供配置中的 ${env.XXX} 使用 ---
SECRETS_FILE="$SCRIPT_DIR/secrets.env"
if [ -f "$SECRETS_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    set +a
else
    echo "WARN: 未找到 $SECRETS_FILE；配置中的 \${env.*} 可能为空" >&2
fi

missing=""
# 先去掉 YAML 注释，避免把注释里的示例 ${env.XXX} 当成必需变量
for var in $(sed 's/#.*//' "$CONFIG_FILE" 2>/dev/null | grep -oE '\$\{env\.[A-Za-z_][A-Za-z0-9_]*\}' | sed -E 's/^\$\{env\.(.*)\}$/\1/' | sort -u || true); do
    if [ -z "${!var:-}" ]; then
        missing="$missing $var"
    fi
done
if [ -n "$missing" ]; then
    echo "FATAL: 配置引用的环境变量未设置:$missing" >&2
    echo "请在 $SECRETS_FILE 中补齐后重试。" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

echo "Starting llama-swap"
echo "  Binary: $BIN"
echo "  Config: $CONFIG_FILE"
echo "  Log:    $LOG_FILE"
echo "  Port:   $PORT"
echo "──────────────────────────────"

# 宏命令依赖 pixi；ssh / systemd 拉起的环境 PATH 里未必有
export PATH="$HOME/.pixi/bin:$PATH"

"$BIN" \
    -config "$CONFIG_FILE" \
    -watch-config \
    -listen "127.0.0.1:${PORT}" \
    | tee "$LOG_FILE"
