#!/bin/bash
# 安装 OpenChamber（CLI + Web UI）到仓库外的 $HOME/.local/openchamber，
# 并把可执行命令软链到 $HOME/.local/bin（参考官方 scripts/install.sh，
# 按其行为做了项目化改造）。安装目录与链接目录分别用 --prefix / --bin-dir
# 覆盖；默认都在仓库外，避免项目目录里出现 300M+ 的 node_modules。
#
# 用法: bash scripts/openchamber-install.sh [选项]
#   --prefix DIR        安装目录（默认 $HOME/.local/openchamber，仓库外）
#   --bin-dir DIR       命令链接目录（默认 $HOME/.local/bin）
#   --no-bin-link       不创建 bin 软链（自行把 $PREFIX/bin 加入 PATH）
#   --version V         @openchamber/web 版本（默认 latest）
#   --node-version V    下载 Node 时使用的版本（默认 24.22.0）
#   --opencode-version V 安装指定版本的 @opencode/cli（隐含 --force-opencode）
#   --force-node        即使系统 node 满足要求也安装到 prefix
#   --force-opencode    即使系统 opencode 满足要求也安装到 prefix
#   --no-opencode-config 不复制 config/opencode-config.json（默认复制）
#   --no-omp            跳过 oh-my-opencode-slim（默认安装）
#   --omp-version V     oh-my-opencode-slim 版本（默认 latest）
#   --omp-preset NAME   生成/激活的 preset（默认 openai；另见 opencode-go）
#   --omp-skills MODE   bundled skills: yes|no|force（默认 yes）
#   --omp-background-subagents yes|no
#                       是否把后台 subagent 环境变量写入 shell rc（默认 no）
#   --omp-dry-run       只模拟 oh-my-opencode-slim 安装，不写文件
#   --check             只检测并打印决策，不做任何安装
#   -h, --help          显示帮助
#
# 链接策略：
#   PREFIX 在仓库内 → $BIN_DIR 下用相对软链（可随仓库整体搬移）；
#   PREFIX 在仓库外 → $BIN_DIR 下用绝对软链（PREFIX 移动后重跑脚本即可修复）；
#   --no-bin-link    → 不建链接，只把 $PREFIX/bin 加进 PATH。
#   想装回项目内：
#     --prefix "$PWD/openchamber" --bin-dir "$PWD/bin"
#
# 行为：
#   * 系统 node >= 24.14.0 且 npm 可用 → 直接使用，不下载；
#     否则下载 Node 到 $PREFIX/node（压缩包留在 download/）。
#   * 系统 opencode >= 2.0.20 → 直接使用，不安装；
#     否则安装 @opencode/cli 到 $PREFIX 并链到 bin/opencode。
#   * pnpm 优先用系统的（>= 10.4），否则用 npm 装到 $PREFIX；
#     无论哪种，store/cache 都落在 $PREFIX 内，不污染 ~/.local/share/pnpm。
#   * OpenChamber 数据默认放 $PREFIX/data（wrapper 里设置
#     OPENCHAMBER_DATA_DIR），不写 ~/.config/openchamber。
#   * 默认安装 oh-my-opencode-slim（CLI 放 $PREFIX/omp-cli），以 --no-tui
#     非交互方式写入 OpenCode 配置；安装后列出新增/更新的文件
#     （忽略 node_modules）。用 --no-omp 跳过。
#   * 幂等，可重复执行。
#
# 环境变量与数据路径（脚本结束时会再次打印）：
#   OPENCHAMBER_PREFIX  覆盖安装目录
#   OPENCHAMBER_DATA_DIR OpenChamber 运行数据（wrapper 默认 $PREFIX/data）
#   OPENCODE_CONFIG_DIR  OpenCode 配置（默认 ~/.config/opencode）
#   OPENCODE_DB          OpenCode 数据库（默认 ~/.local/share/opencode/opencode.db）
#   OPENCODE_HOST        外部 OpenCode server 地址，如 http://127.0.0.1:4096
#   OPENCODE_SKIP_START  设为 true 时 OpenChamber 不自行启动 OpenCode
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${OPENCHAMBER_PREFIX:-$HOME/.local/openchamber}"
BIN_DIR="${OPENCHAMBER_BIN_DIR:-$HOME/.local/bin}"
DL_DIR="$REPO_ROOT/download"
LINK_BINS=1
LINKED=""

# 版本阈值：Node 来自官方 install.sh；OpenCode 来自 OpenChamber compatibility.js
NODE_MIN="24.14.0"
NODE_VERSION="24.22.0"
OPENCODE_MIN="2.0.20"
PNPM_MIN="10.4.0"

PACKAGE="@openchamber/web"
PACKAGE_VERSION="latest"
OPENCODE_PACKAGE="@opencode/cli"
OPENCODE_VERSION="latest"
OC_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
WITH_OC_CONFIG=1
WITH_OMP=1
OMP_VERSION="latest"
OMP_PRESET="openai"
OMP_SKILLS="yes"
OMP_BG="no"
OMP_DRY=0
FORCE_NODE=0
FORCE_OPENCODE=0
CHECK_ONLY=0

usage() { sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)        PREFIX="${2:?--prefix 需要参数}"; shift 2 ;;
        --bin-dir)       BIN_DIR="${2:?--bin-dir 需要参数}"; shift 2 ;;
        --no-bin-link)   LINK_BINS=0; shift ;;
        --version)       PACKAGE_VERSION="${2:?--version 需要参数}"; shift 2 ;;
        --node-version)  NODE_VERSION="${2:?--node-version 需要参数}"; shift 2 ;;
        --opencode-version)
            OPENCODE_VERSION="${2:?--opencode-version 需要参数}"
            OPENCODE_VERSION="${OPENCODE_VERSION#v}"
            FORCE_OPENCODE=1
            shift 2 ;;
        --force-node)    FORCE_NODE=1; shift ;;
        --force-opencode) FORCE_OPENCODE=1; shift ;;
        --no-opencode-config) WITH_OC_CONFIG=0; shift ;;
        --no-omp)        WITH_OMP=0; shift ;;
        --omp-version)   OMP_VERSION="${2:?--omp-version 需要参数}"; shift 2 ;;
        --omp-preset)    OMP_PRESET="${2:?--omp-preset 需要参数}"; shift 2 ;;
        --omp-skills)    OMP_SKILLS="${2:?--omp-skills 需要参数}"; shift 2 ;;
        --omp-background-subagents) OMP_BG="${2:?--omp-background-subagents 需要参数}"; shift 2 ;;
        --omp-dry-run)   OMP_DRY=1; shift ;;
        --check)         CHECK_ONLY=1; shift ;;
        -h|--help)       usage ;;
        *) echo "未知选项: $1（用 --help 查看）" >&2; exit 1 ;;
    esac
done

case "$OMP_SKILLS" in
    yes|no|force) ;;
    *) die "--omp-skills 必须是 yes|no|force" ;;
esac
case "$OMP_BG" in
    yes|no) ;;
    *) die "--omp-background-subagents 必须是 yes|no" ;;
esac

case "$PREFIX" in
    /*) ;;
    *) PREFIX="$PWD/$PREFIX" ;;
esac
PREFIX="${PREFIX%/}"

case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$PWD/$BIN_DIR" ;;
esac
BIN_DIR="${BIN_DIR%/}"

case "$PREFIX" in
    "$REPO_ROOT"/*) PREFIX_INSIDE=1 ;;
    *) PREFIX_INSIDE=0 ;;
esac

log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "FATAL: $*" >&2; exit 1; }

# $1 >= $2
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

parse_version() {
    sed -nE 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1
}

arch_name() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

# --- 检测：node ---
SYS_NODE=0
SYS_NODE_VER=""
if [ "$FORCE_NODE" = 0 ] && command -v node >/dev/null 2>&1; then
    SYS_NODE_VER="$(node --version | sed 's/^v//')"
    if version_ge "$SYS_NODE_VER" "$NODE_MIN" && command -v npm >/dev/null 2>&1; then
        SYS_NODE=1
    fi
fi

# --- 检测：opencode ---
SYS_OPENCODE=0
SYS_OPENCODE_VER=""
if [ "$FORCE_OPENCODE" = 0 ] && command -v opencode >/dev/null 2>&1; then
    SYS_OPENCODE_VER="$(opencode --version 2>/dev/null | parse_version)"
    if [ -n "$SYS_OPENCODE_VER" ] && version_ge "$SYS_OPENCODE_VER" "$OPENCODE_MIN"; then
        SYS_OPENCODE=1
    fi
fi

# --- 检测：pnpm ---
SYS_PNPM=0
SYS_PNPM_VER=""
if command -v pnpm >/dev/null 2>&1; then
    SYS_PNPM_VER="$(pnpm --version 2>/dev/null | parse_version)"
    if [ -n "$SYS_PNPM_VER" ] && version_ge "$SYS_PNPM_VER" "$PNPM_MIN"; then
        SYS_PNPM=1
    fi
fi

if [ "$CHECK_ONLY" = 1 ]; then
    echo "安装目录: $PREFIX"
    if [ "$LINK_BINS" = 1 ]; then
        if [ "$PREFIX_INSIDE" = 1 ] && [ "$BIN_DIR" = "$REPO_ROOT/bin" ]; then
            echo "命令链接: $BIN_DIR（相对软链）"
        else
            echo "命令链接: $BIN_DIR（绝对软链）"
        fi
    else
        echo "命令链接: 不创建（使用 $PREFIX/bin）"
    fi
    echo "系统 node:     ${SYS_NODE_VER:-未安装}（要求 >= $NODE_MIN）→ $([ "$SYS_NODE" = 1 ] && echo 使用系统 || echo 安装到 prefix)"
    if [ "$FORCE_OPENCODE" = 1 ]; then
        echo "系统 opencode: ${SYS_OPENCODE_VER:-未安装}（已强制安装到 prefix，忽略系统版本）"
    else
        echo "系统 opencode: ${SYS_OPENCODE_VER:-未安装}（要求 >= $OPENCODE_MIN）→ $([ "$SYS_OPENCODE" = 1 ] && echo 使用系统 || echo 安装到 prefix)"
    fi
    echo "opencode 目标: $OPENCODE_VERSION"
    echo "系统 pnpm:     ${SYS_PNPM_VER:-未安装}（要求 >= $PNPM_MIN）→ $([ "$SYS_PNPM" = 1 ] && echo 使用系统 || echo 安装到 prefix)"
    if [ "$WITH_OC_CONFIG" = 1 ]; then
        echo "OpenCode 配置: 复制 $REPO_ROOT/config/opencode-config.json -> $OC_CONFIG_DIR/opencode.json"
    else
        echo "OpenCode 配置: 跳过（--no-opencode-config）"
    fi
    if [ "$WITH_OMP" = 1 ]; then
        echo "oh-my-opencode-slim: 安装（version=$OMP_VERSION, preset=$OMP_PRESET, skills=$OMP_SKILLS）"
        if [ -f "$REPO_ROOT/config/oh-my-opencode-slim.json" ]; then
            echo "OMP 配置模板: 复制 $REPO_ROOT/config/oh-my-opencode-slim.json -> $OC_CONFIG_DIR/oh-my-opencode-slim.json"
        fi
    else
        echo "oh-my-opencode-slim: 跳过（--no-omp）"
    fi
    exit 0
fi

command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v tar >/dev/null 2>&1 || die "需要 tar"

mkdir -p "$PREFIX" "$DL_DIR" "$PREFIX/cache"
[ "$LINK_BINS" = 1 ] && mkdir -p "$BIN_DIR"

# --- Node ---
if [ "$SYS_NODE" = 1 ]; then
    log "使用系统 node $(node --version)（>= $NODE_MIN）"
    NODE_BIN="$(command -v node)"
else
    NODE_DIR="$PREFIX/node"
    if [ -x "$NODE_DIR/bin/node" ]; then
        log "使用已有 $NODE_DIR/bin/node（$("$NODE_DIR/bin/node" --version)）"
    else
        log "系统 node 不可用或低于 $NODE_MIN，安装 Node $NODE_VERSION 到 $NODE_DIR"
        ARCH="$(arch_name)"
        TARBALL="node-v$NODE_VERSION-linux-$ARCH.tar.xz"
        mkdir -p "$NODE_DIR"
        if [ ! -f "$DL_DIR/$TARBALL" ]; then
            # 国内镜像优先，官方源兜底
            URLS="
https://mirrors.aliyun.com/nodejs-release/v$NODE_VERSION/$TARBALL
https://npmmirror.com/mirrors/node/v$NODE_VERSION/$TARBALL
https://nodejs.org/dist/v$NODE_VERSION/$TARBALL"
            NODE_BASE=""
            for url in $URLS; do
                if curl -fL --retry 3 --connect-timeout 20 -o "$DL_DIR/$TARBALL" "$url"; then
                    NODE_BASE="${url%/*}"
                    break
                fi
                rm -f "$DL_DIR/$TARBALL"
            done
            [ -f "$DL_DIR/$TARBALL" ] || die "Node 下载失败"
            if [ -n "$NODE_BASE" ] && curl -fsSL "$NODE_BASE/SHASUMS256.txt" -o "$DL_DIR/SHASUMS256.$NODE_VERSION.txt"; then
                ( cd "$DL_DIR" && grep "  $TARBALL\$" "SHASUMS256.$NODE_VERSION.txt" | sha256sum -c - >/dev/null ) \
                    || die "Node 压缩包校验失败"
                log "Node 校验通过 (SHA-256)"
            else
                warn "未能获取 Node SHASUMS256.txt，跳过校验"
            fi
        fi
        tar -xJf "$DL_DIR/$TARBALL" -C "$NODE_DIR" --strip-components=1
        "$NODE_DIR/bin/node" --version >/dev/null || die "Node 解压失败"
        log "Node 安装完成: $("$NODE_DIR/bin/node" --version)"
    fi
    export PATH="$NODE_DIR/bin:$PATH"
    NODE_BIN="$NODE_DIR/bin/node"
fi

# npm 12+ 默认拒绝拉取 registry 之外的 remote tarball（EALLOWREMOTE），
# 全局安装 pnpm/opencode 时需要显式放行；npm 11 及以下不认识该参数，故按版本加。
NPM_VER="$(npm --version 2>/dev/null || echo 0.0.0)"
ALLOW_REMOTE=""
if version_ge "$NPM_VER" "12.0.0"; then
    ALLOW_REMOTE="--allow-remote=all"
fi

# --- pnpm ---
if [ "$SYS_PNPM" = 1 ]; then
    log "使用系统 pnpm $SYS_PNPM_VER（store 仍指向 $PREFIX/pnpm-store）"
    PNPM_BIN="$(command -v pnpm)"
else
    if [ -x "$PREFIX/lib/node_modules/pnpm/bin/pnpm.cjs" ] && [ -x "$PREFIX/bin/pnpm" ]; then
        PNPM_BIN="$PREFIX/bin/pnpm"
        log "使用已有 $PNPM_BIN（$("$PNPM_BIN" --version)）"
    else
        log "安装 pnpm 到 $PREFIX"
        npm_config_cache="$PREFIX/cache/npm" \
        npm_config_update_notifier=false \
        npm_config_fund=false \
        npm_config_audit=false \
            npm install -g --prefix "$PREFIX" $ALLOW_REMOTE --allow-scripts=pnpm pnpm@latest >/dev/null
        PNPM_BIN="$PREFIX/bin/pnpm"
        "$PNPM_BIN" --version >/dev/null || die "pnpm 安装失败"
        log "pnpm 安装完成: $("$PNPM_BIN" --version)"
    fi
fi

# --- OpenCode ---
INSTALLED_OPENCODE=""
if [ "$SYS_OPENCODE" = 1 ]; then
    log "使用系统 opencode v$SYS_OPENCODE_VER（>= $OPENCODE_MIN）"
else
    INSTALLED_OPENCODE="$PREFIX/bin/opencode"
    REUSE_OPENCODE=0
    if [ -x "$INSTALLED_OPENCODE" ]; then
        CURRENT_OPENCODE_VER="$("$INSTALLED_OPENCODE" --version 2>/dev/null | parse_version)"
        if [ "$OPENCODE_VERSION" = "latest" ] || [ "$CURRENT_OPENCODE_VER" = "$OPENCODE_VERSION" ]; then
            REUSE_OPENCODE=1
        fi
    fi

    if [ "$REUSE_OPENCODE" = 1 ]; then
        log "使用已有 $INSTALLED_OPENCODE（$("$INSTALLED_OPENCODE" --version)）"
    else
        if [ "$OPENCODE_VERSION" = "latest" ]; then
            log "系统 opencode 不可用或低于 $OPENCODE_MIN，安装 $OPENCODE_PACKAGE@latest 到 $PREFIX"
        else
            log "安装指定版本 $OPENCODE_PACKAGE@$OPENCODE_VERSION 到 $PREFIX"
        fi
        npm_config_cache="$PREFIX/cache/npm" \
        npm_config_update_notifier=false \
        npm_config_fund=false \
        npm_config_audit=false \
            npm install -g --prefix "$PREFIX" $ALLOW_REMOTE --allow-scripts="$OPENCODE_PACKAGE" "$OPENCODE_PACKAGE@$OPENCODE_VERSION" >/dev/null
        [ -x "$INSTALLED_OPENCODE" ] || die "opencode 安装后 $INSTALLED_OPENCODE 不存在"
        log "opencode 安装完成: $("$INSTALLED_OPENCODE" --version)"
    fi
fi

# OMP 安装器通过 PATH 检查 opencode；把刚装到 prefix 的 opencode 加进 PATH
export PATH="$PREFIX/bin:$PATH"

# --- OpenChamber ---
APP_DIR="$PREFIX/app"
log "安装 $PACKAGE@$PACKAGE_VERSION 到 $APP_DIR"
mkdir -p "$APP_DIR"
if [ ! -f "$APP_DIR/package.json" ]; then
    printf '{\n  "name": "local-llama-openchamber",\n  "private": true\n}\n' > "$APP_DIR/package.json"
fi
printf 'store-dir=%s\n' "$PREFIX/pnpm-store" > "$APP_DIR/.npmrc"

# pnpm 10.4+ 默认拦截依赖构建脚本，需显式放行（官方 install.sh 同款）
ALLOW_BUILD=""
if version_ge "$("$PNPM_BIN" --version)" "10.4.0"; then
    ALLOW_BUILD="--allow-build=msgpackr-extract --allow-build=node-pty"
fi

(
    cd "$APP_DIR"
    XDG_CACHE_HOME="$PREFIX/cache" \
    npm_config_update_notifier=false \
        "$PNPM_BIN" add --store-dir "$PREFIX/pnpm-store" $ALLOW_BUILD "$PACKAGE@$PACKAGE_VERSION"
)

# 旧版本可能遗留的空目录（本项目不做 pnpm 全局安装，用不到）
if [ -d "$PREFIX/pnpm-home" ]; then
    rmdir "$PREFIX/pnpm-home" 2>/dev/null || true
fi

# wrapper：保证能找到 node，并把 OpenChamber 数据固定在 prefix 内
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/openchamber" <<EOF
#!/bin/sh
PREFIX="$PREFIX"
export PATH="\$PREFIX/bin:\$PATH"
export OPENCHAMBER_DATA_DIR="\${OPENCHAMBER_DATA_DIR:-$PREFIX/data}"
exec "\$PREFIX/app/node_modules/.bin/openchamber" "\$@"
EOF
chmod +x "$PREFIX/bin/openchamber"

# --- OpenCode 配置 ---
if [ "$WITH_OC_CONFIG" = 1 ]; then
    OC_CONFIG_SRC="$REPO_ROOT/config/opencode-config.json"
    if [ -f "$OC_CONFIG_SRC" ]; then
        mkdir -p "$OC_CONFIG_DIR"
        if [ -f "$OC_CONFIG_DIR/opencode.json" ] && ! cmp -s "$OC_CONFIG_SRC" "$OC_CONFIG_DIR/opencode.json"; then
            OC_BAK="$OC_CONFIG_DIR/opencode.json.bak.$(date +%Y%m%d%H%M%S)"
            cp -p "$OC_CONFIG_DIR/opencode.json" "$OC_BAK"
            log "已备份现有 OpenCode 配置: $OC_BAK"
        fi
        cp "$OC_CONFIG_SRC" "$OC_CONFIG_DIR/opencode.json"
        log "OpenCode 配置已写入: $OC_CONFIG_DIR/opencode.json"
        if [ -f "$OC_CONFIG_DIR/opencode.jsonc" ]; then
            warn "存在 $OC_CONFIG_DIR/opencode.jsonc（优先于 .json），如需生效请手动合并或移除"
        fi
    else
        warn "未找到 $OC_CONFIG_SRC，跳过 OpenCode 配置复制"
    fi
else
    log "跳过 OpenCode 配置复制（--no-opencode-config）"
fi

# --- oh-my-opencode-slim（OpenCode 配置/插件）---
if [ "$WITH_OMP" = 1 ]; then
    OMP_CLI_DIR="$PREFIX/omp-cli"
    OMP_ENTRY="$OMP_CLI_DIR/node_modules/oh-my-opencode-slim/dist/cli/index.js"

    log "安装 oh-my-opencode-slim@$OMP_VERSION 到 $OMP_CLI_DIR"
    mkdir -p "$OMP_CLI_DIR"
    if [ ! -f "$OMP_CLI_DIR/package.json" ]; then
        printf '{\n  "name": "omp-cli",\n  "private": true\n}\n' > "$OMP_CLI_DIR/package.json"
    fi
    (
        cd "$OMP_CLI_DIR"
        XDG_CACHE_HOME="$PREFIX/cache" \
        npm_config_update_notifier=false \
            "$PNPM_BIN" add --store-dir "$PREFIX/pnpm-store" \
                --allow-build=@ast-grep/cli --allow-build=msgpackr-extract \
                "oh-my-opencode-slim@$OMP_VERSION" >/dev/null
    )
    [ -f "$OMP_ENTRY" ] || die "oh-my-opencode-slim CLI 未找到：$OMP_ENTRY"

    mkdir -p "$OC_CONFIG_DIR"

    OMP_SUM="sha256sum"
    command -v sha256sum >/dev/null 2>&1 || OMP_SUM="shasum -a 256"
    OMP_BEFORE="$PREFIX/.omp-before.$$"
    OMP_AFTER="$PREFIX/.omp-after.$$"
    OMP_BEFORE_PATHS="$OMP_BEFORE.paths"
    OMP_AFTER_PATHS="$OMP_AFTER.paths"
    OMP_LIST="$PREFIX/.omp-list.$$"

    ( cd "$OC_CONFIG_DIR" && find . -type f ! -path '*/node_modules/*' ! -path '*.write-lock/*' -print0 \
        | sort -z > "$OMP_LIST" && if [ -s "$OMP_LIST" ]; then xargs -0 $OMP_SUM < "$OMP_LIST" | sort -k2; fi ) > "$OMP_BEFORE"
    awk '{print $2}' "$OMP_BEFORE" | sort > "$OMP_BEFORE_PATHS"

    # 以安装器自身的 help 为准决定是否传 --skills（v3 起内置 skills，不再有该参数）
    OMP_INSTALL_HELP="$("$NODE_BIN" "$OMP_ENTRY" install --help 2>&1 || true)"
    OMP_ARGS=(install --no-tui --companion=no --preset="$OMP_PRESET" --background-subagents="$OMP_BG")
    case "$OMP_INSTALL_HELP" in
        *--skills*) OMP_ARGS+=(--skills="$OMP_SKILLS") ;;
    esac
    [ "$OMP_DRY" = 1 ] && OMP_ARGS+=(--dry-run)

    log "写入 OpenCode 配置：$OC_CONFIG_DIR（preset=$OMP_PRESET, skills=$OMP_SKILLS, bg-subagents=$OMP_BG）"
    if ! OPENCODE_CONFIG_DIR="$OC_CONFIG_DIR" "$NODE_BIN" "$OMP_ENTRY" "${OMP_ARGS[@]}"; then
        rm -f "$OMP_BEFORE" "$OMP_AFTER" "$OMP_BEFORE_PATHS" "$OMP_AFTER_PATHS" "$OMP_LIST"
        die "oh-my-opencode-slim 安装失败"
    fi

    # 安装器生成 openai/opencode-go；用仓库模板补上 inherit-session 并设为默认
    if [ "$OMP_DRY" = 0 ] && [ -f "$REPO_ROOT/config/oh-my-opencode-slim.json" ]; then
        OMP_CFG_DST="$OC_CONFIG_DIR/oh-my-opencode-slim.json"
        if [ -f "$OMP_CFG_DST" ] && ! cmp -s "$REPO_ROOT/config/oh-my-opencode-slim.json" "$OMP_CFG_DST"; then
            cp -p "$OMP_CFG_DST" "$OMP_CFG_DST.bak.$(date +%Y%m%d%H%M%S)"
            log "已备份现有 OMP 配置: $OMP_CFG_DST.bak.*"
        fi
        cp "$REPO_ROOT/config/oh-my-opencode-slim.json" "$OMP_CFG_DST"
        log "OMP 配置模板已应用: $OMP_CFG_DST（active preset: inherit-session）"
    fi

    if [ "$OMP_DRY" = 1 ]; then
        log "oh-my-opencode-slim：dry-run，未写入文件"
    else
        ( cd "$OC_CONFIG_DIR" && find . -type f ! -path '*/node_modules/*' ! -path '*.write-lock/*' -print0 \
            | sort -z > "$OMP_LIST" && if [ -s "$OMP_LIST" ]; then xargs -0 $OMP_SUM < "$OMP_LIST" | sort -k2; fi ) > "$OMP_AFTER"
        awk '{print $2}' "$OMP_AFTER" | sort > "$OMP_AFTER_PATHS"

        echo
        echo "  oh-my-opencode-slim 变更（已忽略 node_modules / write-lock）："
        if [ -n "$(comm -13 "$OMP_BEFORE_PATHS" "$OMP_AFTER_PATHS")" ]; then
            echo "    新增文件："
            comm -13 "$OMP_BEFORE_PATHS" "$OMP_AFTER_PATHS" | sed 's#^\./##' | sed 's/^/      /'
        fi
        if [ -n "$(awk 'NR==FNR{h[$2]=$1;next} ($2 in h) && h[$2]!=$1 {print $2}' "$OMP_BEFORE" "$OMP_AFTER")" ]; then
            echo "    更新文件："
            awk 'NR==FNR{h[$2]=$1;next} ($2 in h) && h[$2]!=$1 {print $2}' "$OMP_BEFORE" "$OMP_AFTER" \
                | sed 's#^\./##' | sed 's/^/      /'
        fi

        OMP_PKG_DIR="$OMP_CLI_DIR/node_modules/oh-my-opencode-slim"
        if [ -d "$OMP_PKG_DIR/src/skills" ] \
            && { [ ! -d "$OC_CONFIG_DIR/skills" ] || [ -z "$(ls -A "$OC_CONFIG_DIR/skills" 2>/dev/null)" ]; }; then
            echo "    插件内置 skills（不落盘，由插件运行时注册）："
            ( cd "$OMP_PKG_DIR/src/skills" && ls -1d */ 2>/dev/null | sed 's#/$##' | sed 's/^/      /' )
        fi
        if [ -f "$OC_CONFIG_DIR/oh-my-opencode-slim.json" ]; then
            OMP_AGENTS="$("$NODE_BIN" -e "const c=require('$OC_CONFIG_DIR/oh-my-opencode-slim.json'); const p=(c.presets&&c.presets[c.preset])||{}; console.log(Object.keys(p).join(' '))" 2>/dev/null || true)"
            [ -n "$OMP_AGENTS" ] && echo "    内置 agents（preset=$OMP_PRESET）：$OMP_AGENTS"
        fi
        log "oh-my-opencode-slim 配置已写入；重启 OpenCode 后生效"
    fi
    rm -f "$OMP_BEFORE" "$OMP_AFTER" "$OMP_BEFORE_PATHS" "$OMP_AFTER_PATHS" "$OMP_LIST"
else
    log "跳过 oh-my-opencode-slim（--no-omp）"
fi

# --- 链接到 local-llama/bin ---
link_bin() {
    local name="$1" target="$2" rel
    if [ "$LINK_BINS" = 0 ]; then
        return 0
    fi
    if [ "$BIN_DIR" = "$REPO_ROOT/bin" ] && [ "${target#"$REPO_ROOT/"}" != "$target" ]; then
        rel="../${target#"$REPO_ROOT/"}"
    else
        rel="$target"
    fi
    ln -sfn "$rel" "$BIN_DIR/$name"
    LINKED="$LINKED $name"
}

link_bin openchamber "$PREFIX/bin/openchamber"
[ -n "$INSTALLED_OPENCODE" ] && link_bin opencode "$INSTALLED_OPENCODE"

# 只有 prefix 自带 node/pnpm 时才链出来，避免覆盖系统版本
if [ "$SYS_NODE" = 0 ]; then
    for t in node npm npx; do
        [ -e "$PREFIX/node/bin/$t" ] && link_bin "$t" "$PREFIX/node/bin/$t"
    done
fi
if [ "$SYS_PNPM" = 0 ]; then
    [ -e "$PREFIX/bin/pnpm" ] && link_bin pnpm "$PREFIX/bin/pnpm"
fi

if [ "$LINK_BINS" = 1 ]; then
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) warn "$BIN_DIR 不在 PATH 中；把 export PATH=\"$BIN_DIR:\$PATH\" 加入 shell 配置" ;;
    esac
fi

# --- 验证 ---
log "验证安装"
if [ "$LINK_BINS" = 1 ]; then
    OC_CMD="$BIN_DIR/openchamber"
else
    OC_CMD="$PREFIX/bin/openchamber"
fi
"$OC_CMD" --version >/dev/null || die "openchamber 无法运行"
OPENCHAMBER_VER="$("$OC_CMD" --version 2>/dev/null | head -n1)"

cat > "$PREFIX/.openchamber-prefix" <<EOF
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
prefix=$PREFIX
openchamber=$OPENCHAMBER_VER
node=$("$NODE_BIN" --version)
opencode=$([ -n "$INSTALLED_OPENCODE" ] && "$INSTALLED_OPENCODE" --version 2>/dev/null || echo "system v$SYS_OPENCODE_VER")
pnpm=$("$PNPM_BIN" --version)
EOF

echo
echo "==> 完成"
if [ "$LINK_BINS" = 1 ]; then
    if [ "$PREFIX_INSIDE" = 1 ] && [ "$BIN_DIR" = "$REPO_ROOT/bin" ]; then
        LINK_MODE="相对软链"
    else
        LINK_MODE="绝对软链"
    fi
    echo "    commands    : $BIN_DIR/{${LINKED# }}（$LINK_MODE）"
    echo "    openchamber : $BIN_DIR/openchamber -> $(readlink -f "$BIN_DIR/openchamber")"
else
    echo "    commands    : 未创建链接，请把 $PREFIX/bin 加入 PATH"
fi
echo "    version     : $OPENCHAMBER_VER"
echo "    prefix      : $PREFIX"
echo
echo "环境变量与数据路径："
echo "  OPENCHAMBER_DATA_DIR  $PREFIX/data          （wrapper 已默认设置）"
echo "  OpenChamber app       $APP_DIR"
if [ "$WITH_OMP" = 1 ]; then
    echo "  oh-my-opencode-slim   $PREFIX/omp-cli（安装器 + preset=$OMP_PRESET）"
fi
echo "  pnpm store            $PREFIX/pnpm-store"
echo "  npm/pnpm cache        $PREFIX/cache"
echo "  Node                  $NODE_BIN"
echo "  OpenCode 配置         ${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
echo "  OpenCode 数据库       ${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
echo "  OpenCode server       ${OPENCODE_HOST:-<未设置，OpenChamber 将自行管理>}"
echo
echo "使用："
if [ "$LINK_BINS" = 1 ]; then
    case ":$PATH:" in
        *":$BIN_DIR:"*) echo "  # $BIN_DIR 已在 PATH 中" ;;
        *) echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
    esac
else
    echo "  export PATH=\"$PREFIX/bin:\$PATH\""
fi
echo "  openchamber --help"
echo "  # 连接已有 opencode server："
echo "  OPENCODE_HOST=http://127.0.0.1:4096 OPENCODE_SKIP_START=true openchamber"
echo
if [ "$LINK_BINS" = 1 ]; then
    echo "卸载：rm -rf \"$PREFIX\"，再删除 $BIN_DIR 下对应软链"
else
    echo "卸载：rm -rf \"$PREFIX\""
fi
