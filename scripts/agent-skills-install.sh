#!/usr/bin/env bash
#
# agent-skills-install.sh
# 把上游技能仓库装到 OpenCode 全局技能目录。
#
# 做法：git 浅克隆到 ~/.local/agent-skills/<repo>，再 symlink 到
# ~/.config/opencode/skills/<skill>。因此 --update 只需 git pull，
# 可以随时切回上游历史，也不会在技能目录里堆积副本。
#
# 用法:
#   ./agent-skills-install.sh                 # 全部来源，各用默认分组
#   ./agent-skills-install.sh dd              # 只装 diagram-design
#   ./agent-skills-install.sh mp full         # 只装 mattpocock 全量 27 个
#   ./agent-skills-install.sh --check         # 只校验，不动文件
#
# 新增来源: 只在下面「来源注册表」里加一段，不需要改逻辑。
#
# 选项:
#   --only SRC        只处理指定来源，可重复
#   --group NAME      指定分组（相当于位置参数里的 base|stand|full 等）
#   --dest DIR        技能目录（默认 ~/.config/opencode/skills）
#   --copy            复制文件而不是 symlink
#   --force           目标已存在且不是 symlink 时删除重建
#   --dry-run         只打印计划，不联网、不写文件
#   --update          只更新已克隆的仓库（git pull）并修复失效链接
#   --uninstall       移除已选技能
#   --clean-agents    清掉 ~/.agents/skills 里 npx/skills CLI 装的同名副本
#   --check           校验已选技能是否落盘
#   --list            列出来源、分组与技能
#   -h, --help        显示帮助
#
# 两个上游均为 MIT 许可。
#
set -euo pipefail

CLONE_ROOT="${AGENT_SKILLS_CLONE_ROOT:-$HOME/.local/agent-skills}"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills"
# skills CLI / npx 装到这里的兼容源，旧副本会造成同名重复
LEGACY_DEST="$HOME/.agents/skills"

# ---------------------------------------------------------------------------
# 来源注册表 —— 新增来源只改这一段
#
#   SRC_ALL+=(<id>)            id 同时是命令行子命令名
#   SRC_REPO[<id>]             上游 owner/repo，仅用于展示
#   SRC_URL[<id>]              clone 地址
#   SRC_CLONE[<id>]            克隆目录
#   SRC_SUBDIR[<id>]           仓库内技能根目录
#   SRC_GROUPS[<id>]           分组名列表；单技能仓库给一个分组即可
#   SRC_DEFAULT_GROUP[<id>]    不带分组参数时用哪个
#   SKILLS_<id>_<group>=(...)  分组下的技能目录名
#   SRC_OLD[<id>]              可选，旧克隆位置，首次运行自动迁移
#   SRC_POST[<id>]             可选，安装后的额外提示
# ---------------------------------------------------------------------------

SRC_ALL=()

declare -A SRC_REPO=() SRC_URL=() SRC_CLONE=() SRC_SUBDIR=()
declare -A SRC_GROUPS=() SRC_DEFAULT_GROUP=() SRC_OLD=() SRC_POST=()

# --- mp: mattpocock/skills -------------------------------------------------
SRC_ALL+=(mp)
SRC_REPO[mp]="mattpocock/skills"
SRC_URL[mp]="${MP_SKILLS_REPO:-https://github.com/mattpocock/skills.git}"
SRC_CLONE[mp]="${MP_SKILLS_DIR:-$CLONE_ROOT/mattpocock-skills}"
SRC_SUBDIR[mp]="skills"
SRC_GROUPS[mp]="base stand full"
SRC_DEFAULT_GROUP[mp]="stand"
SRC_OLD[mp]="${XDG_DATA_HOME:-$HOME/.local/share}/mattpocock-skills"

# 分组数据只通过 group_names/group_count 的 nameref 读取
# shellcheck disable=SC2034
SKILLS_mp_base=(
  grilling
  domain-modeling
  grill-with-docs
  setup-matt-pocock-skills
  to-spec
  to-tickets
  implement
  tdd
  code-review
)

# shellcheck disable=SC2034
SKILLS_mp_stand=(
  "${SKILLS_mp_base[@]}"
  codebase-design
  prototype
  research
  diagnosing-bugs
  pr
  handoff
  improve-codebase-architecture
  writing-for-agents
)

# shellcheck disable=SC2034
SKILLS_mp_full=(
  # engineering (20)
  ask-matt
  code-review
  codebase-design
  diagnosing-bugs
  domain-modeling
  grill-with-docs
  implement-spec
  implement
  improve-codebase-architecture
  pr
  prototype
  research
  retro
  setup-matt-pocock-skills
  tdd
  to-spec
  to-tickets
  triage
  wayfinder
  wizard
  # productivity (7)
  grill-me
  grilling
  handoff
  teach
  to-questionnaire
  wait-what
  writing-for-agents
)

SRC_POST[mp]="在业务仓库根目录运行一次 @setup-matt-pocock-skills，把 tracker/文档/ADR 固定下来"

# --- dd: cathrynlavery/diagram-design --------------------------------------
SRC_ALL+=(dd)
SRC_REPO[dd]="cathrynlavery/diagram-design"
SRC_URL[dd]="${DD_SKILLS_REPO:-https://github.com/cathrynlavery/diagram-design.git}"
SRC_CLONE[dd]="${DD_SKILLS_DIR:-$CLONE_ROOT/diagram-design}"
SRC_SUBDIR[dd]="skills"
SRC_GROUPS[dd]="all"
SRC_DEFAULT_GROUP[dd]="all"
SRC_OLD[dd]="${XDG_DATA_HOME:-$HOME/.local/share}/diagram-design-skills"

# shellcheck disable=SC2034
SKILLS_dd_all=(diagram-design)

SRC_POST[dd]="首次使用会先问品牌样式；导出 PNG 需 pip install playwright && playwright install chromium"

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

die()  { printf '错误: %s\n' "$*" >&2; exit 1; }
warn() { printf '提示: %s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*"; }

# 分组数据访问（nameref 关在函数里，避免跨迭代残留）
group_names() {
  local -n ref="SKILLS_${1}_${2}"
  printf '%s\n' "${ref[@]}"
}
group_count() {
  local -n ref="SKILLS_${1}_${2}"
  printf '%s' "${#ref[@]}"
}

# 分组名是否存在于任一来源
is_group() {
  local g="$1" s
  for s in "${SRC_ALL[@]}"; do
    [[ " ${SRC_GROUPS[$s]} " == *" $g "* ]] && return 0
  done
  return 1
}

list_all() {
  local src g n names
  info "目标目录: $DEST"
  info "克隆根目录: $CLONE_ROOT"
  for src in "${SRC_ALL[@]}"; do
    printf '\n%s  %s\n' "$src" "${SRC_REPO[$src]}"
    printf '    克隆: %s\n' "${SRC_CLONE[$src]}"
    for g in ${SRC_GROUPS[$src]}; do
      n="$(group_count "$src" "$g")"
      names="$(group_names "$src" "$g" | tr '\n' ' ')"
      if [[ "$g" == "${SRC_DEFAULT_GROUP[$src]}" ]]; then
        printf '    %-6s %2d 个（默认）\n           %s\n' "$g" "$n" "$names"
      else
        printf '    %-6s %2d 个\n           %s\n' "$g" "$n" "$names"
      fi
    done
  done
}

usage() {
  cat <<'EOF'
用法: agent-skills-install.sh [来源...] [分组...] [选项]

来源（位置参数写 id 即可，等同 --only id）:
EOF
  local src g
  for src in "${SRC_ALL[@]}"; do
    printf '  %-4s %s\n' "$src" "${SRC_REPO[$src]}"
    for g in ${SRC_GROUPS[$src]}; do
      printf '         %-6s %2d 个%s\n' "$g" "$(group_count "$src" "$g")" \
        "$([[ "$g" == "${SRC_DEFAULT_GROUP[$src]}" ]] && printf '（默认）' || true)"
    done
  done
  cat <<'EOF'

选项:
  --only SRC        只处理指定来源，可重复
  --group NAME      指定分组
  --dest DIR        技能目录（默认 ~/.config/opencode/skills）
  --copy            复制文件而不是 symlink
  --force           目标已存在且不是 symlink 时删除重建
  --dry-run         只打印计划，不联网、不写文件
  --update          只更新已克隆的仓库（git pull）并修复失效链接
  --uninstall       移除已选技能
  --clean-agents    清掉 ~/.agents/skills 里 npx/skills CLI 装的同名副本
  --check           校验已选技能是否落盘
  --list            列出来源、分组与技能
  -h, --help        显示帮助

安装位置:
  技能   ~/.config/opencode/skills/<name>   （symlink）
  克隆   ~/.local/agent-skills/<repo>       （git --depth 1）
EOF
}

# 每个分组内不允许重名（上游改名/手滑时早失败）
validate_registry() {
  local src g dupes
  for src in "${SRC_ALL[@]}"; do
    for g in ${SRC_GROUPS[$src]}; do
      [[ "$(group_count "$src" "$g")" -gt 0 ]] || die "${src}/${g} 分组为空"
      dupes="$(group_names "$src" "$g" | sort | uniq -d)"
      [[ -z "$dupes" ]] || die "${src}/${g} 分组有重复: $dupes"
    done
  done
}

# 校验技能之间的显式依赖，只警告不阻断（只涉及 mp，闲置时无副作用）
check_deps() {
  local -A have=()
  local s
  for s in "${selected_names[@]}"; do have["$s"]=1; done

  need() { [[ -n "${have[$1]:-}" ]] || warn "已选 $2，但缺少它依赖的 $1"; }

  [[ -n "${have[grill-with-docs]:-}" ]] && { need grilling grill-with-docs; need domain-modeling grill-with-docs; }
  [[ -n "${have[grill-me]:-}" ]]       && need grilling grill-me
  [[ -n "${have[implement]:-}" ]]      && { need tdd implement; need code-review implement; }
  [[ -n "${have[to-spec]:-}" ]]        && need setup-matt-pocock-skills to-spec
  [[ -n "${have[to-tickets]:-}" ]]     && need setup-matt-pocock-skills to-tickets
  [[ -n "${have[retro]:-}" ]]          && need writing-for-agents retro
  [[ -n "${have[improve-codebase-architecture]:-}" ]] && need grilling improve-codebase-architecture
  [[ -n "${have[wayfinder]:-}" ]]      && need grilling wayfinder
  [[ -n "${have[triage]:-}" ]]         && need grilling triage
  return 0
}

# 在克隆里定位技能目录，输出绝对路径
find_skill_dir() {
  local src="$1" name="$2" root md
  root="${SRC_CLONE[$src]}/${SRC_SUBDIR[$src]}"
  [[ -d "$root" ]] || return 1
  md="$(find "$root" -type f -path "*/$name/SKILL.md" -print -quit 2>/dev/null || true)"
  [[ -n "$md" ]] || return 1
  printf '%s' "$(dirname "$md")"
}

ensure_clone() {
  local src="$1" dir url old
  dir="${SRC_CLONE[$1]}"
  url="${SRC_URL[$1]}"
  old="${SRC_OLD[$1]:-}"
  if [[ -n "$old" && ! -e "$dir" && -d "$old" ]]; then
    info "迁移旧克隆 $old -> $dir"
    mkdir -p "$(dirname "$dir")"
    mv "$old" "$dir"
  fi
  if [[ -d "$dir/.git" ]]; then
    if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
      warn "$dir 有本地修改，跳过 pull"
    else
      info "更新 $dir"
      git -C "$dir" pull --ff-only --depth 1 || warn "pull 失败，继续用当前 checkout"
    fi
  else
    if [[ -e "$dir" ]]; then
      die "$dir 已存在但不是 git 仓库（移走或设置 SRC_CLONE 变量后再试）"
    fi
    info "克隆 ${SRC_REPO[$src]} -> $dir"
    mkdir -p "$(dirname "$dir")"
    GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$url" "$dir" \
      || { rm -rf "$dir"; die "clone 失败（网络？）: $url"; }
  fi
}

link_skill() {
  local name="$1" src="${selected_src[$1]}" path target
  path="$(find_skill_dir "$src" "$name")" \
    || die "${SRC_REPO[$src]} 里找不到技能: $name"

  target="$DEST/$name"
  if [[ -e "$target" && ! -L "$target" ]]; then
    if [[ "$force" == 1 ]]; then
      rm -rf "$target"
    else
      die "$target 已存在且不是 symlink（加 --force 覆盖）"
    fi
  fi

  if [[ "$copy" == 1 ]]; then
    rm -rf "$target"
    cp -R "$path" "$target"
    printf '  %-24s copy  %s\n' "$name" "$path"
  else
    ln -sfn "$path" "$target"
    printf '  %-24s link  %s\n' "$name" "$path"
  fi
}

verify_skills() {
  local name missing=()
  for name in "${selected_names[@]}"; do
    [[ -f "$DEST/$name/SKILL.md" ]] || missing+=("$name")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "以下技能未正确落盘: ${missing[*]}（检查 ${DEST}）"
  fi
}

legacy_dupes() {
  local name hits=()
  for name in "${selected_names[@]}"; do
    [[ -e "$LEGACY_DEST/$name" || -L "$LEGACY_DEST/$name" ]] && hits+=("$name")
  done
  if [[ "${#hits[@]}" -gt 0 ]]; then
    warn "$LEGACY_DEST 里还有同名旧副本，OpenCode 可能读到旧版本: ${hits[*]}"
    warn "清理: $0 --clean-agents"
  fi
}

clean_agents() {
  local name target n=0
  for name in "${selected_names[@]}"; do
    target="$LEGACY_DEST/$name"
    if [[ -L "$target" ]]; then
      rm -f "$target"
      printf '  清理旧链接 %s\n' "$target"
      n=$((n + 1))
    elif [[ -d "$target" ]]; then
      rm -rf "$target"
      printf '  清理旧副本 %s\n' "$target"
      n=$((n + 1))
    fi
  done
  if [[ "$n" -gt 0 ]]; then info "已清理 $n 个旧副本"; fi
  return 0
}

summary() {
  local src
  info "已就绪: ${#selected_names[@]} 个技能，目录 $DEST"
  printf '\n下一步:\n'
  printf '  1. 新开一个 OpenCode 会话（当前会话不会刷新技能列表）\n'
  printf '  2. 输入 @%s 确认能加载\n' "${selected_names[0]}"
  for src in "${chosen_sources[@]}"; do
    if [[ -n "${SRC_POST[$src]:-}" ]]; then
      printf '  · %s\n' "${SRC_POST[$src]}"
    fi
  done
  printf '\n更新: %s --update\n' "$0"
  printf '移除: %s --uninstall\n' "$0"
}

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------

force=0
copy=0
dry=0
do_update=0
do_uninstall=0
do_check=0
do_clean=0
declare -a chosen_sources=() bare_groups=()
declare -A chosen_group=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)         chosen_sources+=("${2:?--only 需要一个来源 id}"); shift 2 ;;
    --group)        bare_groups+=("${2:?--group 需要一个分组名}"); shift 2 ;;
    --dest)         DEST="${2:?--dest 需要一个目录}"; shift 2 ;;
    --copy)         copy=1; shift ;;
    --force)        force=1; shift ;;
    --dry-run)      dry=1; shift ;;
    --update)       do_update=1; shift ;;
    --uninstall)    do_uninstall=1; shift ;;
    --clean-agents) do_clean=1; shift ;;
    --check)        do_check=1; shift ;;
    --npx)          warn "--npx 已弃用：安装目录固定为 ${DEST}，改用 git + symlink"; shift ;;
    --list)         list_all; exit 0 ;;
    -h|--help)      usage; exit 0 ;;
    --*)            die "未知参数: $1（用 --help 查看用法）" ;;
    *)
      if [[ -n "${SRC_REPO[$1]:-}" ]]; then
        chosen_sources+=("$1"); shift
      elif is_group "$1"; then
        bare_groups+=("$1"); shift
      else
        die "未知参数: $1（既不是来源也不是分组，用 --list 查看）"
      fi
      ;;
  esac
done

validate_registry

[[ "${#chosen_sources[@]}" -gt 0 ]] || chosen_sources=("${SRC_ALL[@]}")

for s in "${chosen_sources[@]}"; do
  [[ -n "${SRC_REPO[${s}]:-}" ]] || die "未知来源: ${s}（可选 ${SRC_ALL[*]}）"
done

for g in "${bare_groups[@]}"; do
  matched=0
  for s in "${chosen_sources[@]}"; do
    if [[ " ${SRC_GROUPS[$s]} " == *" $g "* ]]; then
      chosen_group["$s"]="$g"
      matched=1
    fi
  done
  [[ "$matched" == 1 ]] || die "分组 $g 不在所选来源里（可选: $(for s in "${chosen_sources[@]}"; do printf '%s ' ${SRC_GROUPS[$s]}; done)）"
done

# ---------------------------------------------------------------------------
# 组装选择集（保留顺序，记录来源）
# ---------------------------------------------------------------------------

selected_names=()
declare -A selected_src=()

pick() {
  local src="$1" name
  shift
  for name in "$@"; do
    [[ -n "${selected_src[$name]:-}" ]] && continue
    selected_src["$name"]="$src"
    selected_names+=("$name")
  done
}

for src in "${chosen_sources[@]}"; do
  g="${chosen_group[$src]:-${SRC_DEFAULT_GROUP[$src]}}"
  mapfile -t group_skills < <(group_names "$src" "$g")
  pick "$src" "${group_skills[@]}"
done

info "来源: ${chosen_sources[*]}（共 ${#selected_names[@]} 个技能）"
info "目标: $DEST$( [[ "$copy" == 1 ]] && printf '（copy）' || printf '（symlink）' )"

# ---------------------------------------------------------------------------
# dry-run
# ---------------------------------------------------------------------------

if [[ "$dry" == 1 ]]; then
  printf '\n计划:\n'
  for name in "${selected_names[@]}"; do
    src="${selected_src[$name]}"
    printf '  %-28s %-10s %s\n' "$name" "$src" "${SRC_CLONE[$src]}"
  done
  if [[ "$do_uninstall" == 1 ]]; then
    printf '\n计划移除: %s\n' "${selected_names[*]}"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------

if [[ "$do_check" == 1 ]]; then
  verify_skills
  info "校验通过: ${#selected_names[@]} 个技能都在 $DEST"
  legacy_dupes
  exit 0
fi

# ---------------------------------------------------------------------------
# 更新
# ---------------------------------------------------------------------------

if [[ "$do_update" == 1 ]]; then
  for src in "${chosen_sources[@]}"; do
    [[ -d "${SRC_CLONE[$src]}/.git" ]] || die "还没克隆过: ${SRC_CLONE[$src]}（先运行一次安装）"
    ensure_clone "$src"
  done
  # 上游可能改名或挪目录，重新指向一次
  for name in "${selected_names[@]}"; do
    target="$DEST/$name"
    if [[ -L "$target" || ! -e "$target" ]]; then
      link_skill "$name"
    fi
  done
  verify_skills
  info "更新完成"
  exit 0
fi

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------

if [[ "$do_uninstall" == 1 ]]; then
  removed=0
  for name in "${selected_names[@]}"; do
    target="$DEST/$name"
    if [[ -L "$target" ]]; then
      rm -f "$target"
      printf '  移除链接 %s\n' "$target"
      removed=$((removed + 1))
    elif [[ -d "$target" ]]; then
      rm -rf "$target"
      printf '  移除目录 %s\n' "$target"
      removed=$((removed + 1))
    fi
  done
  if [[ "$do_clean" == 1 ]]; then clean_agents; fi
  info "移除 $removed 个，克隆目录仍保留（$0 --list 查看位置）"
  exit 0
fi

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------

for src in "${chosen_sources[@]}"; do
  ensure_clone "$src"
done

mkdir -p "$DEST"
for name in "${selected_names[@]}"; do
  link_skill "$name"
done

verify_skills
if [[ "$do_clean" == 1 ]]; then clean_agents; fi
legacy_dupes
summary
