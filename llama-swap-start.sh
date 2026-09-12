#!/bin/bash


usage() {
    echo "Start llama-swap with the given config and port."
    echo ""
    echo "Usage: $0 -n <name> [-p <port>]"
    echo ""
    echo "Options:"
    echo "  -n <name>    Config name (llama-swap-config-<name>.yaml)"
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

# Resolve config: cwd or script dir (deduplicated)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE=""
if [ "$PWD" = "$SCRIPT_DIR" ]; then
    searchPaths=("$PWD")
else
    searchPaths=("$PWD" "$SCRIPT_DIR")
fi
for searchPath in "${searchPaths[@]}"; do
    candidate="${searchPath}/llama-swap-config-${CONFIG_NAME}.yaml"
    if [ -f "$candidate" ]; then
        echo "Looking for config '$candidate': Found"
        CONFIG_FILE="$candidate"
        break
    else
        echo "Looking for config '$candidate': No such file"
    fi
done

if [ -z "$CONFIG_FILE" ]; then
    echo "Error: config file not found: llama-swap-config-${CONFIG_NAME}.yaml"
    exit 1
fi

echo "Starting llama-swap"
echo "  Config: $CONFIG_FILE"
echo "  Port:   $PORT"
echo "──────────────────────────────"

$SCRIPT_DIR/bin/llama-swap \
    -config "$CONFIG_FILE" \
    -watch-config \
    -listen "127.0.0.1:${PORT}" \
    | tee llama-swap-${CONFIG_NAME}-$(date +%F).log
