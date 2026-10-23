#!/bin/bash
# 启动 OpenChamber Web UI：先确保 OpenCode 后台服务在跑，再 attach 上去。
# 单 server / 多 client，避免两个 server 同时写一个 opencode.db。
# 会自动读取仓库根目录的 local.env 并 export 给 OpenCode 服务。
#
# 用法: bash openchamber-start.sh [选项]
#   --server          确保服务在跑并启动 OpenChamber（默认）
#   --status          显示当前 URL（OpenCode + OpenChamber）；只读，不启动任何服务
#   --stop            停止 OpenChamber 和 OpenCode shared service（默认一起停；
#                     加 --keep-opencode 保留 OpenCode 服务）
#   -p, --port N      OpenChamber 端口（默认 3000）
#   --host IP         绑定地址（默认 127.0.0.1；0.0.0.0 = 所有网卡；
#                     指定 IP 当前不可用时自动回退到 127.0.0.1）
#   --lan             --host 0.0.0.0 的简写
#   --ui-password [PW] 浏览器 UI 密码；省略值则让 OpenChamber 自动生成
#   --foreground      OpenChamber 前台运行（默认 daemon）
#   --keep-opencode   与 --stop 一起用：只停 OpenChamber，保留 OpenCode shared service
#   -h, --help        显示帮助
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 密钥：export 给 OpenCode 服务（provider 配置用 env 引用）---
LOCAL_ENV="$REPO_ROOT/local.env"
if [ -f "$LOCAL_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$LOCAL_ENV"
    set +a
fi

MODE="server"
PORT="${OPENCHAMBER_PORT:-3000}"
HOST="${OPENCHAMBER_BIND:-127.0.0.1}"
UI_PW=""
FOREGROUND=0
KEEP_OPENCODE=0
URL=""
PW=""

usage() { sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --server)     MODE="server"; shift ;;
        --status)     MODE="status"; shift ;;
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
        --keep-opencode) KEEP_OPENCODE=1; shift ;;
        -h|--help)    usage ;;
        *) die "未知选项: $1（用 --help 查看）" ;;
    esac
done

# --- 通用工具 ---

# 判断 IPv4 地址是否属于本机；无法探测时按“可用”处理
host_is_local() {
    local h="$1" checked=0
    case "$h" in
        127.*|localhost|0.0.0.0|::|::1) return 0 ;;
    esac
    if command -v ip >/dev/null 2>&1; then
        checked=1
        ip -4 addr show 2>/dev/null | grep -q "inet ${h}/" && return 0
    fi
    if command -v ifconfig >/dev/null 2>&1; then
        checked=1
        ifconfig 2>/dev/null | grep -q "inet ${h} " && return 0
    fi
    if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
        checked=1
        hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$h" && return 0
    fi
    [ "$checked" = 0 ] && return 0
    return 1
}

# 首个局域网 IPv4（用于 0.0.0.0 绑定时的访问 URL 展示）
lan_ip() {
    local ip=""
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
    fi
    printf '%s' "${ip:-<本机IP>}"
}

# opencode 服务运行时 status 最后一行是 URL，停止时不是
service_url() {
    opencode service status 2>/dev/null | tail -n1 | tr -d '\r'
}

service_pid() {
    python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.local/state/opencode/service.json")))["pid"])' 2>/dev/null || true
}

# 服务进程的“配置相关变量”是否与 local.env 不一致（0 = 缺失或不一致）。
# 只比较 OpenCode 配置真正引用的变量，避免 MACHINE_NAME/绑定地址等无关变量导致误重启。
service_lacks_env() {
    local pid="$1" var expected actual cfg="$REPO_ROOT/config/opencode-config.json" vars=""
    [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] || return 1

    if [ -f "$cfg" ]; then
        vars="$(grep -oE '\{env:[A-Za-z_][A-Za-z0-9_]*\}' "$cfg" 2>/dev/null \
            | sed -E 's/^\{env:(.*)\}$/\1/' | sort -u || true)"
    fi
    if [ -z "$vars" ]; then
        vars="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*_API_KEY(_[0-9]+)?=' "$LOCAL_ENV" 2>/dev/null \
            | tr -d '=' | sort -u || true)"
    fi

    for var in $vars; do
        expected="${!var:-}"
        actual="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n "s/^${var}=//p" | head -n1)"
        if [ "$actual" != "$expected" ]; then
            return 0
        fi
    done
    return 1
}

# 显示 $OPENCHAMBER_BIN 在指定端口上运行实例的 URL；无实例时返回 1
show_openchamber_url() {
    local port="$1" actual
    actual="$("$OPENCHAMBER_BIN" status -p "$port" 2>/dev/null \
        | grep -oE 'port [0-9]+' | head -n1 | awk '{print $2}')"
    [ -n "$actual" ] || return 1
    if [ "$HOST" = "0.0.0.0" ]; then
        echo "OpenChamber: http://$(lan_ip):$actual/（0.0.0.0；本机也可用 http://127.0.0.1:$actual/）"
    else
        echo "OpenChamber: http://$HOST:$actual/"
    fi
}

# --- 各模式 ---

mode_stop() {
    if [ -n "$OPENCHAMBER_BIN" ]; then
        "$OPENCHAMBER_BIN" stop -p "$PORT" || true
    fi
    # 默认连同 OpenCode shared service 一起停；--keep-opencode 时保留
    if [ "$KEEP_OPENCODE" = 0 ]; then
        echo "==> 停止 OpenCode 后台服务"
        opencode service stop || true
        # 验证确实停了（有监督进程时服务可能被重新拉起）
        local url
        url="$(service_url || true)"
        case "$url" in
            http://*|https://*) echo "WARN: OpenCode 服务仍在运行: $url（可能被监督进程重新拉起）" ;;
            *) echo "==> OpenCode 后台服务已停止" ;;
        esac
    fi
}

mode_status() {
    # 只读：显示当前 URL，不启动任何服务
    local url
    url="$(service_url || true)"
    case "$url" in
        http://*|https://*) echo "OpenCode: $url" ;;
        *) echo "OpenCode: 未启动（启动: bash $0）" ;;
    esac
    if [ -n "$OPENCHAMBER_BIN" ]; then
        show_openchamber_url "$PORT" \
            || echo "OpenChamber: 端口 $PORT 无运行实例（启动: bash $0 -p $PORT）"
    else
        echo "OpenChamber: 未安装（先运行 scripts/openchamber-install.sh）"
    fi
}

# 确保 OpenCode shared service 在跑且已加载 local.env 密钥（结果存 URL）
ensure_service() {
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
    # 已运行的服务不会继承本脚本 export 的变量；缺密钥时重启一次
    if [ -f "$LOCAL_ENV" ] && service_lacks_env "$(service_pid)"; then
        echo "==> OpenCode 服务与 local.env 不一致，重启服务以加载"
        opencode service restart >/dev/null
        sleep 2
        URL="$(service_url || true)"
    fi
    case "$URL" in
        http://*|https://*) ;;
        *) die "无法获取 OpenCode 服务地址（opencode service status）" ;;
    esac
}

# 取服务密码并验证认证（结果存 PW）
check_auth() {
    PW="$(opencode service get password 2>/dev/null || true)"
    if [ -z "$PW" ]; then
        PW="$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.local/state/opencode/service.json")))["password"])' 2>/dev/null || true)"
    fi
    [ -n "$PW" ] || die "无法获取 OpenCode 服务密码（opencode service get password）"
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "opencode:$PW" "$URL/api/info" || true)"
    [ "$code" = "200" ] || die "OpenCode 服务认证失败（HTTP ${code:-000}）：$URL"
}

# 确保服务在跑，把 OpenChamber attach 到同一个 OpenCode server
mode_server() {
    ensure_service
    check_auth

    # 指定了具体 IPv4 但该地址当前不在本机（如 Tailscale 下线）时，回退到
    # 127.0.0.1，保证本机仍可访问，而不是启动失败。
    if printf '%s' "$HOST" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && [ "$HOST" != "0.0.0.0" ] \
        && ! host_is_local "$HOST"; then
        echo "WARN: 绑定地址 $HOST 当前不可用（Tailscale/网卡未就绪？），回退到 127.0.0.1" >&2
        HOST="127.0.0.1"
    fi

    # OpenChamber 拒绝在非回环地址上无认证启动；这里自动生成 UI 密码。
    case "$HOST" in
        127.*|localhost|::1) ;;
        *)
            if [ -z "$UI_PW" ] && [ -z "${OPENCHAMBER_UI_PASSWORD:-}" ]; then
                UI_PW="__AUTO__"
                echo "==> 绑定 $HOST 需要 UI 认证，已自动生成浏览器密码"
            fi ;;
    esac

    local args=("--port" "$PORT" "--host" "$HOST")
    if [ "$FOREGROUND" = 1 ]; then
        args+=("--foreground")
    fi
    if [ "$UI_PW" = "__AUTO__" ]; then
        args+=("--ui-password")
    elif [ -n "$UI_PW" ]; then
        args+=("--ui-password" "$UI_PW")
    fi

    echo "==> 复用 OpenCode 服务: $URL"
    if [ "$HOST" = "0.0.0.0" ]; then
        echo "==> 启动 OpenChamber: http://$(lan_ip):$PORT/（0.0.0.0；本机也可用 http://127.0.0.1:$PORT/）"
    else
        echo "==> 启动 OpenChamber: http://$HOST:$PORT/"
    fi
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) echo "    提示: $HOME/.local/bin 不在 PATH 中（本脚本直接用了绝对路径）" ;;
    esac

    # 换实例前先停旧实例
    "$OPENCHAMBER_BIN" stop -p "$PORT" >/dev/null 2>&1 || true
    OPENCODE_HOST="$URL" \
    OPENCODE_SKIP_START=true \
    OPENCODE_PASSWORD="$PW" \
        "$OPENCHAMBER_BIN" "${args[@]}"

    echo
    echo "停止: $0 --stop -p $PORT（默认同时停 OpenCode 服务；加 --keep-opencode 保留）"
}

# --- 前置检查与分发 ---

command -v curl >/dev/null 2>&1 || die "需要 curl"
# opencode 命令只在需要管理 shared service 时才用到（--stop --keep-opencode 除外）
if [ "$MODE" != "stop" ] || [ "$KEEP_OPENCODE" = 0 ]; then
    command -v opencode >/dev/null 2>&1 || die "找不到 opencode 命令"
fi

if [ -x "$REPO_ROOT/bin/openchamber" ]; then
    OPENCHAMBER_BIN="$REPO_ROOT/bin/openchamber"
elif [ -x "$HOME/.local/bin/openchamber" ]; then
    OPENCHAMBER_BIN="$HOME/.local/bin/openchamber"
else
    OPENCHAMBER_BIN="$(command -v openchamber || true)"
fi

case "$MODE" in
    stop)   mode_stop ;;
    status) mode_status ;;
    server)
        [ -n "$OPENCHAMBER_BIN" ] || die "找不到 openchamber 命令（先运行 scripts/openchamber-install.sh）"
        mode_server
        ;;
esac
