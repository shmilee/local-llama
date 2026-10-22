#!/bin/bash
# 启动 OpenChamber Web UI：先确保 OpenCode 后台服务在跑，再 attach 上去。
# 单 server / 多 client，避免两个 server 同时写一个 opencode.db。
# 会自动读取仓库根目录的 secrets.env 并 export 给 OpenCode 服务。
#
# 用法: bash openchamber-start.sh [选项]
#   --web             确保服务在跑并启动 OpenChamber（默认）
#   --server          只确保服务在跑并打印 URL
#   --stop            停止 OpenChamber（配合 --stop-service 可停 OpenCode 服务）
#   -p, --port N      OpenChamber 端口（默认 3000）
#   --host IP         绑定地址（默认 127.0.0.1；0.0.0.0 = 所有网卡）
#   --lan             --host 0.0.0.0 的简写
#   --ui-password [PW] 浏览器 UI 密码；省略值则让 OpenChamber 自动生成
#   --foreground      OpenChamber 前台运行（默认 daemon）
#   --stop-service    与 --stop 一起用：同时停止 OpenCode shared service
#   -h, --help        显示帮助
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 密钥：export 给 OpenCode 服务（provider 配置用 env 引用）---
SECRETS_FILE="$REPO_ROOT/secrets.env"
if [ -f "$SECRETS_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    set +a
fi

MODE="web"
PORT="3000"
HOST="127.0.0.1"
UI_PW=""
FOREGROUND=0
STOP_SERVICE=0

usage() { sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --web)        MODE="web"; shift ;;
        --server)     MODE="server"; shift ;;
        --stop)       MODE="stop"; shift ;;
        -p|--port)    PORT="${2:?--port 需要参数}"; shift 2 ;;
        --host|--bind) HOST="${2:?--host 需要参数}"; shift 2 ;;
        --lan)        HOST="0.0.0.0"; shift ;;
        --ui-password)
            if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
                UI_PW="$2"; shift 2
            else
                UI_PW="__AUTO__"; shift
            fi
            ;;
        --foreground) FOREGROUND=1; shift ;;
        --stop-service) STOP_SERVICE=1; shift ;;
        -h|--help)    usage ;;
        *) die "未知选项: $1（用 --help 查看）" ;;
    esac
done

command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v opencode >/dev/null 2>&1 || die "找不到 opencode 命令"

if [ -x "$REPO_ROOT/bin/openchamber" ]; then
    OPENCHAMBER_BIN="$REPO_ROOT/bin/openchamber"
elif [ -x "$HOME/.local/bin/openchamber" ]; then
    OPENCHAMBER_BIN="$HOME/.local/bin/openchamber"
else
    OPENCHAMBER_BIN="$(command -v openchamber || true)"
fi

if [ "$MODE" = "stop" ]; then
    if [ -n "$OPENCHAMBER_BIN" ]; then
        "$OPENCHAMBER_BIN" stop -p "$PORT" || true
    fi
    if [ "$STOP_SERVICE" = 1 ]; then
        opencode service stop || true
    fi
    exit 0
fi

[ -n "$OPENCHAMBER_BIN" ] || die "找不到 openchamber 命令（先运行 scripts/openchamber-install.sh）"

# --- 确保 OpenCode shared service 在跑 ---
service_url() {
    opencode service status 2>/dev/null | tail -n1 | tr -d '\r'
}

service_pid() {
    python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.local/state/opencode/service.json")))["pid"])' 2>/dev/null || true
}

# 服务进程是否缺少 secrets.env 里的变量（0 = 有缺失）
service_lacks_env() {
    local pid="$1" var
    [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] || return 1
    for var in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS_FILE" 2>/dev/null | tr -d '=' || true); do
        if ! tr '\0' '\n' < "/proc/$pid/environ" | grep -q "^$var="; then
            return 0
        fi
    done
    return 1
}

URL="$(service_url || true)"
case "$URL" in
    http://*|https://*) ;;
    *)
        echo "==> 启动 OpenCode 后台服务"
        opencode service start >/dev/null
        sleep 2
        URL="$(service_url || true)"
        ;;
esac
case "$URL" in
    http://*|https://*) ;;
    *) die "无法获取 OpenCode 服务地址（opencode service status）" ;;
esac

# 已运行的服务不会继承本脚本 export 的变量；缺密钥时重启一次
if [ -f "$SECRETS_FILE" ] && service_lacks_env "$(service_pid)"; then
    echo "==> OpenCode 服务缺少 secrets.env 中的密钥，重启服务以加载"
    opencode service restart >/dev/null
    sleep 2
    URL="$(service_url || true)"
    case "$URL" in
        http://*|https://*) ;;
        *) die "重启 OpenCode 服务后无法获取地址" ;;
    esac
fi

# --- 取密码并验证 ---
PW="$(opencode service get password 2>/dev/null || true)"
if [ -z "$PW" ]; then
    PW="$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.local/state/opencode/service.json")))["password"])' 2>/dev/null || true)"
fi
[ -n "$PW" ] || die "无法获取 OpenCode 服务密码（opencode service get password）"

CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "opencode:$PW" "$URL/api/info" || true)"
[ "$CODE" = "200" ] || die "OpenCode 服务认证失败（HTTP ${CODE:-000}）：$URL"

if [ "$MODE" = "server" ]; then
    echo "OpenCode: $URL"
    exit 0
fi

# --- OpenChamber attach 到同一个 server ---
# OpenChamber 拒绝在非回环地址上无认证启动；这里自动生成 UI 密码。
case "$HOST" in
    127.*|localhost|::1) NEED_AUTH=0 ;;
    *) NEED_AUTH=1 ;;
esac
if [ "$NEED_AUTH" = 1 ] && [ -z "$UI_PW" ] && [ -z "${OPENCHAMBER_UI_PASSWORD:-}" ]; then
    UI_PW="__AUTO__"
    echo "==> 绑定 $HOST 需要 UI 认证，已自动生成浏览器密码"
fi

OPENCHAMBER_ARGS=("--port" "$PORT" "--host" "$HOST")
[ "$FOREGROUND" = 1 ] && OPENCHAMBER_ARGS+=("--foreground")
if [ "$UI_PW" = "__AUTO__" ]; then
    OPENCHAMBER_ARGS+=("--ui-password")
elif [ -n "$UI_PW" ]; then
    OPENCHAMBER_ARGS+=("--ui-password" "$UI_PW")
fi

echo "==> 复用 OpenCode 服务: $URL"
if [ "$HOST" = "0.0.0.0" ]; then
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -z "$LAN_IP" ] && command -v ip >/dev/null 2>&1; then
        LAN_IP="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
    fi
    [ -n "$LAN_IP" ] || LAN_IP="<本机IP>"
    echo "==> 启动 OpenChamber: http://$LAN_IP:$PORT/（0.0.0.0；本机也可用 http://127.0.0.1:$PORT/）"
else
    echo "==> 启动 OpenChamber: http://$HOST:$PORT/"
fi
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "    提示: $HOME/.local/bin 不在 PATH 中（本脚本直接用了绝对路径）" ;;
esac

"$OPENCHAMBER_BIN" stop -p "$PORT" >/dev/null 2>&1 || true
OPENCODE_HOST="$URL" \
OPENCODE_SKIP_START=true \
OPENCODE_PASSWORD="$PW" \
    "$OPENCHAMBER_BIN" "${OPENCHAMBER_ARGS[@]}"

echo
echo "停止: $0 --stop -p $PORT"
