#!/bin/bash
# ====================================================
# Project: Sing-box Elite Management System + Domo Installer
# Version: 2.2.7
#
# Menu (per your requirements):
#  1) Install/Update sing-box (APT repo, deps auto-check incl. sudo)
#  2) Clear config.json (reset to minimal template)
#  3) View config.json (sing-box format)
#  4) Core service sync (Reality/SS/TUIC)
#  5) Add/overwrite relay node
#  6) Delete relay node
#  7) Export client configs (Clash / Quantumult X)
#  8) Uninstall sing-box (keep /etc/sing-box/)
#
# Safety rule:
# - Any time we restart/enable/start sing-box, we ALWAYS run:
#     sing-box check -c /etc/sing-box/config.json
#   If check fails: print error and DO NOT restart/start/enable.
#
# Notes:
# - VLESS(TCP) + TUIC(UDP) share 443 OK.
# - Relay SS is fixed: port 8080 + 2022-blake3-aes-128-gcm.
# - Export does NOT mask secrets (per your preference).
# ====================================================

set -Eeuo pipefail

CONFIG_FILE="/etc/sing-box/config.json"
TEMP_FILE="/etc/sing-box/config.json.tmp"
SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"

# --- Legacy compatibility (<= V-1.10.2) ---
LEGACY_VLESS_TAG="vless-main-in"
LEGACY_VLESS_USER="direct-user"
NEW_VLESS_TAG="vless-reality-in"
NEW_VLESS_USER="vless-reality-user"

generate_random_alpha_path() {
  local s=""
  while [ ${#s} -lt 7 ]; do
    s="$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z' | head -c 7 || true)"
  done
  echo "/${s}"
}

normalize_ws_path() { # $1 raw
  local p="${1:-}"
  if [ -z "${p}" ]; then
    generate_random_alpha_path
    return 0
  fi
  [[ "$p" != /* ]] && p="/$p"
  echo "$p"
}


has_inbound_tag() { # $1 tag
  local t="$1"
  jq -e --arg t "$t" '.inbounds[]? | select(.tag==$t)' "$CONFIG_FILE" >/dev/null 2>&1
}

get_active_vless_tag() {
  if has_inbound_tag "$NEW_VLESS_TAG"; then echo "$NEW_VLESS_TAG"; return 0; fi
  if has_inbound_tag "$LEGACY_VLESS_TAG"; then echo "$LEGACY_VLESS_TAG"; return 0; fi
  echo ""
}

# Ask once when legacy found (optional migration). Safe: renames tag+user+managed rule.
maybe_migrate_legacy() {
  if has_inbound_tag "$NEW_VLESS_TAG"; then return 0; fi
  if ! has_inbound_tag "$LEGACY_VLESS_TAG"; then return 0; fi

  echo -e "${Y}[WARN] 检测到旧版本 vless-reality 节点（tag=$LEGACY_VLESS_TAG / user=$LEGACY_VLESS_USER）。${NC}"
  echo -e "${Y}是否迁移为新命名（tag=$NEW_VLESS_TAG / user=$NEW_VLESS_USER），以便后续管理一致？${NC}"
  read -r -p "输入 1 迁移，输入 0 跳过: " ans
  if [ "${ans:-0}" != "1" ]; then
    warn "已跳过迁移（脚本将尽量兼容旧命名）。"
    return 0
  fi

  local conf updated
  conf="$(cat "$CONFIG_FILE")"
  # 兜底：配置根若是 array，先包装为 object，避免后续访问 .route/.outbounds 崩溃
  conf=$(echo "$conf" | jq '
    if type=="array" then
      {"log":{"level":"info","timestamp":true},"inbounds":.,"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}
    else . end
    | .inbounds = (.inbounds // [])
    | .outbounds = (.outbounds // [])
    | .route = (.route // {"rules":[]})
    | .route.rules = (.route.rules // [])
  ')

  # rename inbound tag
  updated="$(echo "$conf" | jq '
    (.inbounds[]? | select(.tag=="vless-main-in") | .tag) = "vless-reality-in"
  ')"

  # rename legacy direct-user -> vless-reality-user
  updated="$(echo "$updated" | jq '
    (.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .users) |=
      (map(if (.name?=="direct-user") then (.name="vless-reality-user") else . end))
  ')"

  # update managed rule auth_user pair (if present)
  updated="$(echo "$updated" | jq '
    if type=="array" then {"log":{"level":"info","timestamp":true},"inbounds":.,"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}} else . end | .inbounds=(.inbounds//[]) | .outbounds=(.outbounds//[]) | .route=(.route//{"rules":[]}) | .route.rules=(.route.rules//[]) | 
    .route.rules |= ( (. // []) | map(
      if (type=="object" and .auth_user? == ["direct-user","tuic-user"]) then
        .auth_user = ["vless-reality-user","tuic-user"]
      else .
      end
    ))
  ')"

  # save & restart safely (atomic_save exists below)
  atomic_save "$updated" >/dev/null 2>&1 || true
  ok "迁移完成：已使用新命名（建议你再用导出/中转管理确认一次）。"
}

# ---------- UI ----------
B='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; NC='\033[0m'; W='\033[1;37m'

say()  { echo -e "${C}[INFO]${NC} $*"; }
ok()   { echo -e "${G}[ OK ]${NC} $*"; }
warn() { echo -e "${Y}[WARN]${NC} $*"; }
err()  { echo -e "${R}[ERR ]${NC} $*"; }

pause() { read -r -n 1 -p "按任意键返回..." || true; echo ""; }

ensure_sb_shortcut() {
  local target_script="/root/sing-box.sh"
  local shortcut="/usr/local/bin/sb"
  local remote_url="https://raw.githubusercontent.com/Tangfffyx/Public/main/Script/sing-box.sh"
  local current="${SCRIPT_SELF:-${BASH_SOURCE[0]:-$0}}"
  mkdir -p /usr/local/bin

  if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]] || [[ "$current" == /dev/fd/* ]] || [[ "$current" == /proc/self/fd/* ]]; then
    curl -Ls "$remote_url" -o "$target_script" || {
      warn "快捷命令 sb 安装失败：无法下载脚本到 $target_script"
      return 1
    }
  else
    current="$(readlink -f "$current" 2>/dev/null || echo "$current")"
    if [ "$current" != "$target_script" ]; then
      cp -f "$current" "$target_script" || {
        warn "快捷命令 sb 安装失败：无法复制脚本到 $target_script"
        return 1
      }
    fi
  fi

  chmod +x "$target_script" >/dev/null 2>&1 || true

  cat > "$shortcut" <<'EOF'
#!/usr/bin/env bash
bash /root/sing-box.sh
EOF
  chmod +x "$shortcut" >/dev/null 2>&1 || true
}

cleanup() { rm -f "$TEMP_FILE"; }
trap cleanup EXIT

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 运行此脚本。"
    exit 1
  fi
}

# ---------- OS / pkg helpers ----------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_status() {
  dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true
}

pkg_installed() {
  [ "$(pkg_status "$1")" = "installed" ]
}

apt_update_once() {
  local stamp="/tmp/.domo_apt_updated"
  if [ -f "$stamp" ]; then
    ok "apt-get update 已执行过（本次会话）。"
    return 0
  fi
  say "执行: apt-get update"
  apt-get update -y
  touch "$stamp"
  ok "apt 软件索引更新完成。"
}

install_pkg_apt() {
  local pkg="$1"
  if pkg_installed "$pkg"; then
    ok "依赖已存在: $pkg"
    return 0
  fi
  say "安装依赖: $pkg"
  apt_update_once
  apt-get install -y "$pkg"
  ok "已安装依赖: $pkg"
}

ensure_deps_for_installer() {
  require_root
  if ! has_cmd apt-get; then
    err "未找到 apt-get。本安装器按 Debian/Ubuntu APT 源方式设计。"
    err "如果你不是 Debian 系系统，请自行改造为 dnf/yum 或手动安装。"
    exit 1
  fi
  say "检查并安装必要依赖..."
  # per your requirement: even if you run as root, still auto-install sudo if missing
  install_pkg_apt sudo
  install_pkg_apt ca-certificates
  install_pkg_apt curl
  install_pkg_apt gnupg
  # manager deps
  install_pkg_apt jq
  install_pkg_apt openssl
  ok "依赖检查完成。"
}

ensure_sagernet_repo() {
  say "检查/配置 sing-box APT 源..."
  mkdir -p /etc/apt/keyrings
  ok "目录已就绪: /etc/apt/keyrings"

  if [ ! -f /etc/apt/keyrings/sagernet.asc ]; then
    say "下载 GPG key -> /etc/apt/keyrings/sagernet.asc"
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod a+r /etc/apt/keyrings/sagernet.asc
    ok "GPG key 已配置完成。"
  else
    ok "GPG key 已存在，跳过下载。"
  fi

  if [ ! -f /etc/apt/sources.list.d/sagernet.sources ]; then
    say "写入 APT 源文件 -> /etc/apt/sources.list.d/sagernet.sources"
    cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
    ok "APT 源文件已创建。"
  else
    ok "APT 源文件已存在，跳过写入。"
  fi

  say "执行: apt-get update（添加新源后强制刷新）"
  apt-get update -y
  ok "仓库配置完成（已刷新索引）。"
}

get_candidate_version() {
  apt-cache policy sing-box | awk '/Candidate:/ {print $2}' | head -n1
}

get_installed_version() {
  local st ver
  st="$(dpkg-query -W -f='${db:Status-Status}' sing-box 2>/dev/null || true)"
  ver="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  if [ "$st" = "installed" ] && [ -n "$ver" ]; then echo "$ver"; else echo ""; fi
}

show_versions() {
  local inst cand
  inst="$(get_installed_version)"
  cand="$(get_candidate_version)"
  echo -e "${W}──────── 版本信息 ────────${NC}"
  echo -e " Installed : ${inst:-<not installed>}"
  echo -e " Candidate : ${cand:-<none>}"
  echo -e "${W}──────────────────────────${NC}"
}

# ---------- sing-box config helpers ----------
ensure_min_config_exists() {
  if [ ! -s "$CONFIG_FILE" ] || ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
    warn "未发现有效配置，将写入最小模板: $CONFIG_FILE"
    mkdir -p /etc/sing-box
    cat > "$CONFIG_FILE" <<'EOF'
{
  "log": {"level": "info","timestamp": true},
  "inbounds": [],
  "outbounds": [{"type": "direct","tag": "direct"}],
  "route": {"rules": []}
}
EOF
  fi
}

check_config_or_print() {
  if ! has_cmd sing-box; then
    err "未找到 sing-box 命令。请先用选项1安装。"
    return 1
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    err "未找到配置文件：$CONFIG_FILE"
    return 1
  fi
  if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    ok "配置校验通过：sing-box check -c $CONFIG_FILE"
    return 0
  fi
  err "配置校验失败：sing-box check -c $CONFIG_FILE"
  sing-box check -c "$CONFIG_FILE" 2>&1 | sed 's/^/  /'
  return 1
}

restart_singbox_safe() {
  # Only restart if config passes
  if ! has_cmd systemctl; then
    err "未找到 systemctl（可能不是 systemd 系统）。"
    return 1
  fi
  if ! check_config_or_print; then
    err "已阻止重启：请先修复配置。"
    return 1
  fi
  say "重启服务：systemctl restart sing-box"
  systemctl restart sing-box
  ok "sing-box 已重启。"
}

enable_now_singbox_safe() {
  if ! has_cmd systemctl; then
    err "未找到 systemctl（可能不是 systemd 系统）。"
    return 1
  fi
  if ! check_config_or_print; then
    err "已阻止启动/自启：请先修复配置。"
    return 1
  fi
  say "启用自启并立即启动：systemctl enable --now sing-box"
  systemctl enable --now sing-box
  ok "sing-box 已启用自启并启动。"
}

atomic_save() {
  local json_data="$1" # <--- 修复点：先获取传入参数 $1

  # 安全兜底：只允许保存 object 根结构，避免误写成数组导致后续 jq 解析崩溃
  # 修复点：这里检查 $json_data 而不是未定义的 $json
  if [ -z "$json_data" ] || ! echo "$json_data" | jq -e 'type=="object"' >/dev/null 2>&1; then
    err "内部错误：即将写入的配置不是 JSON object，已拒绝写入（避免破坏 config.json）。"
    return 1
  fi

  local ts backup
  ts="$(date +%Y%m%d_%H%M%S)"
  backup="/etc/sing-box/config.json.bak.fail.$ts"
  local prev_tmp="/tmp/singbox_config_prev.$$"

  echo "$json_data" | jq . > "$TEMP_FILE" || {
    err "JSON 生成/格式化失败，未写入配置。"
    return 1
  }

  # Check the temp config using sing-box (more strict than jq)
  if ! has_cmd sing-box; then
    err "未找到 sing-box，无法校验配置。请先用选项1安装。"
    return 1
  fi
  if ! sing-box check -c "$TEMP_FILE" >/dev/null 2>&1; then
    err "sing-box check 校验未通过，未写入配置。"
    sing-box check -c "$TEMP_FILE" 2>&1 | sed 's/^/  /'
    return 1
  fi

  # Save previous config to a temporary file (NOT a persistent backup)
  if [ -f "$CONFIG_FILE" ]; then
    cp -a "$CONFIG_FILE" "$prev_tmp"
  else
    : > "$prev_tmp"
  fi

  mv -f "$TEMP_FILE" "$CONFIG_FILE"

  # Restart safely (check again on real path)
  if restart_singbox_safe; then
    rm -f "$prev_tmp" 2>/dev/null || true
    systemctl enable sing-box >/dev/null 2>&1 || true
    ok "配置已应用（成功重启）。"
    return 0
  fi

  err "重启失败或配置校验失败：正在回滚，并在失败时生成备份..."
  # Persist a backup ONLY on failure
  if [ -f "$prev_tmp" ] && [ -s "$prev_tmp" ]; then
    cp -a "$prev_tmp" "$backup"
    warn "已生成失败备份：$backup"
    cp -a "$prev_tmp" "$CONFIG_FILE"
  else
    # No previous config existed; keep the current file and still record a backup if possible
    cp -a "$CONFIG_FILE" "$backup" 2>/dev/null || true
    warn "无旧配置可回滚（首次写入失败）。已保存失败现场：$backup"
  fi
  rm -f "$prev_tmp" 2>/dev/null || true

  if restart_singbox_safe; then
    warn "回滚成功：已恢复到上一版配置并重启。"
  else
    err "回滚后仍无法重启，请手动检查：systemctl status sing-box"
  fi
  return 1
}

get_public_ip() {
  local ip=""
  ip=$(curl -s4 --max-time 3 --connect-timeout 2 ifconfig.me 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 api.ipify.org 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 icanhazip.com 2>/dev/null | tr -d '\n' || true)
  [ -z "$ip" ] && ip="IP"
  echo "$ip"
}

# ---------- Route rule management (from 1.9.3) ----------
sync_managed_route_rules() {
  local conf="$1"

  # 1. 强力修复：确保输入绝对是 Object，防止 jq 报错
  if echo "$conf" | jq -e 'type == "array"' >/dev/null 2>&1; then
    conf=$(echo "$conf" | jq '{
      "log": {"level": "info","timestamp": true},
      "inbounds": .,
      "outbounds": [{"type": "direct","tag": "direct"}],
      "route": {"rules": []}
    }')
  fi

  # 2. 补全缺失字段
  conf=$(echo "$conf" | jq '
    .inbounds = (.inbounds // []) |
    .outbounds = (.outbounds // []) |
    .route = (.route // {"rules":[]}) |
    .route.rules = (.route.rules // [])
  ')

  # 3. 获取所有“当前存活”的合法用户（包括中转用户）
  #    如果主节点被删了，它下面的中转用户这里就肯定抓不到了
  local valid_users_json
  valid_users_json=$(
    echo "$conf" | jq -r '.inbounds[]? | .users[]?.name // empty' 2>/dev/null | awk 'NF' | sort -u | jq -R . | jq -s 'sort | unique'
  )

  # 4. 获取核心用户（用于生成 direct 规则）
  local users_json
  users_json=$(
    echo "$conf" | jq -r '.inbounds[]? | .users[]?.name // empty' 2>/dev/null | awk 'NF' | grep -v -- '-to-' | grep -v -- '-realy-' | grep -v '^relay-' | sort -u | jq -R . | jq -s 'sort | unique'
  )

  # 5. 提取并清理中转规则 (Relay Rules) - 这是修复核心
  local relay_rules_json
  relay_rules_json=$(
    echo "$conf" | jq --argjson vu "$valid_users_json" '
      ([.inbounds[]? | .users[]?.name // empty] | unique) as $present
      | (.route.rules // [])
      # [关键修复] 第一步：先把所有 auth_user 统一转为数组，解决字符串残留问题
      | map(
          if (.auth_user? != null) and ((.auth_user|type)=="string") then
            .auth_user=[.auth_user]
          else .
          end
        )
      # 第二步：筛选出看起来像中转的规则
      | map(select(
          (type=="object")
          and (.auth_user? != null)
          and (any(.auth_user[]?; (type=="string") and ((contains("-to-") or contains("-realy-")) or startswith("relay-"))))
        ))
      # [关键修复] 第三步：生死簿点名。
      # 只要规则里的 auth_user 有任何一个不在 $present (存活名单) 里，这条规则就得死。
      | map(select(
          all(.auth_user[]?; ($present | index(.)) != null)
        ))
    ' 2>/dev/null
  )

  # 6. 如果所有核心用户都没了（比如卸载了所有节点），只保留活着的中转规则
  if echo "$users_json" | jq -e 'length==0' >/dev/null 2>&1; then
    echo "$conf" | jq --argjson rr "$relay_rules_json" '
      .route.rules = ($rr // [])
      | .route.rules |= unique_by((.outbound // "") + "|" + ((.auth_user // []) | sort | join(",")))
    '
    return 0
  fi

  # 7. 正常重组：Direct 规则 + 幸存的中转规则
  echo "$conf" | jq --argjson users "$users_json" --argjson rr "$relay_rules_json" '
    # 生成核心 Direct 规则
    [{"auth_user": $users, "outbound": "direct"}] as $core_rule
    
    # 合并
    | .route.rules = ($core_rule + ($rr // []))
    
    # 最终去重
    | .route.rules |= unique_by((.outbound // "") + "|" + ((.auth_user // []) | sort | join(",")))
  '
}

remove_relay_rule_safely() {
  local json="$1"
  local relay_user="$2"   # e.g. relay-sg01

  echo "$json" | jq --arg u "$relay_user" '
    if type=="array" then {"log":{"level":"info","timestamp":true},"inbounds":.,"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}} else . end | .inbounds=(.inbounds//[]) | .outbounds=(.outbounds//[]) | .route=(.route//{"rules":[]}) | .route.rules=(.route.rules//[]) | 
    .route.rules |= (
      (. // [])
      | map(
          if type != "object" then .
          else
            # auth_user may be string or array; remove any rule that targets this relay user
            if (
              (.auth_user? != null)
              and (
                ((.auth_user|type)=="string" and .auth_user==$u)
                or ((.auth_user|type)=="array" and (any(.auth_user[]?; .==$u)))
              )
            )
            then empty else . end
          end
        )
      | map(select(. != null))
    )
  '
}

# ---------- Manager init ----------
init_manager_env() {
  require_root
  if ! has_cmd jq; then err "未找到 jq，请先用选项1安装/更新（会自动装依赖）。"; exit 1; fi
  if ! has_cmd curl; then err "未找到 curl，请先用选项1安装/更新（会自动装依赖）。"; exit 1; fi
  if ! has_cmd openssl; then err "未找到 openssl，请先用选项1安装/更新（会自动装依赖）。"; exit 1; fi
  if ! has_cmd sing-box; then err "未找到 sing-box，请先用选项1安装。"; exit 1; fi
  if ! has_cmd systemctl; then err "未找到 systemctl（需要 systemd）。"; exit 1; fi

  ensure_min_config_exists
}

# ====================================================
# 1) Install/Update sing-box
# ====================================================
install_or_update_singbox() {
  clear
  echo -e "${B}┌──────────────────────────────────────────────┐${NC}"
  echo -e "${B}│        Sing-box Installer / Updater           │${NC}"
  echo -e "${B}└──────────────────────────────────────────────┘${NC}"

  ensure_deps_for_installer
  ensure_sagernet_repo

  show_versions
  local cand inst
  cand="$(get_candidate_version)"
  inst="$(get_installed_version)"

  if [ -z "${cand:-}" ] || [ "$cand" = "(none)" ]; then
    err "未获取到仓库 Candidate 版本。可能是网络/源不可用。"
    pause
    return 1
  fi

  if [ -z "${inst:-}" ]; then
    say "本机未安装 sing-box，将安装版本: $cand"
    apt-get install -y sing-box
    ok "sing-box 安装完成。"
  else
    if dpkg --compare-versions "$inst" lt "$cand"; then
      warn "检测到可更新：$inst  ->  $cand"
      say "执行升级: apt-get install --only-upgrade sing-box"
      apt-get install -y --only-upgrade sing-box
      ok "sing-box 升级完成。"
    else
      ok "已是最新版本：$inst（无需更新）"
    fi
  fi

  # Ensure config exists; if not, create minimal template but DO NOT force enable unless check passes.
  ensure_min_config_exists

  # Enable+start safely (checks config first)
  if has_cmd systemctl; then
    enable_now_singbox_safe || true
    say "当前服务状态："
    systemctl --no-pager -l status sing-box 2>/dev/null || true
  fi

  show_versions
  ensure_sb_shortcut
  ok "已创建脚本快捷键: sb"
  pause
}

# ====================================================
# 2) Clear config.json (reset)
# ====================================================
clear_config_json() {
  init_manager_env
  clear
  echo -e "${Y}─── 清空/重置配置文件 ───${NC}"

  echo -e "${Y}注意：该操作将清空当前 config.json。${NC}"
  read -r -p "输入 YES 确认继续，其它任意输入取消: " __cfm
  if [ "${__cfm:-}" != "YES" ]; then
    warn "已取消清空/重置。"
    pause
    return 0
  fi


  local ts backup prev_tmp
  ts="$(date +%Y%m%d_%H%M%S)"
  backup="/etc/sing-box/config.json.bak.fail.$ts"
  prev_tmp="/tmp/singbox_config_prev.clear.$$"

  # Save previous config to temp (not a persistent backup)
  if [ -f "$CONFIG_FILE" ]; then
    cp -a "$CONFIG_FILE" "$prev_tmp"
  else
    : > "$prev_tmp"
  fi

  cat > "$CONFIG_FILE" <<'EOF'
{
  "log": {"level": "info","timestamp": true},
  "inbounds": [],
  "outbounds": [{"type": "direct","tag": "direct"}],
  "route": {"rules": []}
}
EOF
  ok "已写入最小配置模板：$CONFIG_FILE"

  if restart_singbox_safe; then
    rm -f "$prev_tmp" 2>/dev/null || true
    ok "清空/重置完成（成功重启）。"
    pause
    return 0
  fi

  err "重启失败：正在回滚，并在失败时生成备份..."
  if [ -f "$prev_tmp" ] && [ -s "$prev_tmp" ]; then
    cp -a "$prev_tmp" "$backup"
    warn "已生成失败备份：$backup"
    cp -a "$prev_tmp" "$CONFIG_FILE"
    rm -f "$prev_tmp" 2>/dev/null || true
    restart_singbox_safe || true
  else
    cp -a "$CONFIG_FILE" "$backup" 2>/dev/null || true
    warn "无旧配置可回滚（首次写入失败）。已保存失败现场：$backup"
    rm -f "$prev_tmp" 2>/dev/null || true
  fi

  pause
}

# ====================================================
# 3) View config (format)
# ====================================================
view_config_formatted() {
  init_manager_env
  clear
  echo -e "${C}─── 查看格式化配置 (sing-box format) ───${NC}"
  echo ""
  sing-box format -c "$CONFIG_FILE" || {
    err "sing-box format 执行失败（可能配置不合法）。"
  }
  echo ""
  pause
}

# ====================================================
# 4) Core service sync
# ====================================================
sync_core_services() {
  init_manager_env
  local conf; conf=$(cat "$CONFIG_FILE")

  if echo "$conf" | jq -e 'type == "array"' >/dev/null 2>&1; then
    conf=$(echo "$conf" | jq '{
      "log": {"level": "info","timestamp": true},
      "inbounds": .,
      "outbounds": [{"type": "direct","tag": "direct"}],
      "route": {"rules": []}
    }')
  fi
  conf=$(echo "$conf" | jq '
    .inbounds = (.inbounds // []) |
    .outbounds = (.outbounds // []) |
    .route = (.route // {"rules":[]}) |
    .route.rules = (.route.rules // [])
  ')

  port_is_in_use() { # $1 json, $2 port, $3 exclude_tag
    local __json="$1"
    local __p="$2"
    local __ex="${3:-}"
    echo "$__json" | jq -e --arg p "$__p" --arg ex "$__ex" '
      .inbounds[]?
      | select((.listen_port? // empty | tostring) == $p)
      | select(($ex == "") or ((.tag // "") != $ex))
    ' >/dev/null 2>&1
  }

  while true; do
    clear
    echo -e "${B}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│                 核心模块管理 (Install/Uninstall)    │${NC}"
    echo -e "${B}└──────────────────────────────────────────────────┘${NC}"

    mapfile -t __relay_nodes < <(echo "$conf" | jq -r '(.inbounds[]? | (.users? // []))[]? | select((.name? // "") | startswith("relay-")) | .name' 2>/dev/null | sed 's/relay-//')
    if [ ${#__relay_nodes[@]} -eq 0 ]; then
      echo -e "${Y}当前暂无中转节点。${NC}"
    else
      echo -e "${C}当前已配置中转节点:${NC} ${G}${#__relay_nodes[@]} 个${NC}"
      for __n in "${__relay_nodes[@]}"; do
        echo -e "  - ${G}${__n}${NC}"
      done
    fi

    local has_vless has_anytls has_ss has_vmess_ws has_vless_ws has_tuic has_legacy_wstls ss_ports
    has_vless=$(echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vless-reality-[0-9]+-in$")) or (.tag=="vless-reality-in") or (.tag=="vless-main-in"))' >/dev/null 2>&1 && echo "true" || echo "false")
    has_anytls=$(echo "$conf" | jq -e '.inbounds[]? | select((.type=="anytls") or ((.tag//"")|test("^anytls-[0-9]+-in$")))' >/dev/null 2>&1 && echo "true" || echo "false")
    has_ss=$(echo "$conf" | jq -e '.inbounds[]? | select(.type=="shadowsocks") | select(((.tag//"")|test("^ss-[0-9]+-in$")) or ((.tag//"")|startswith("ss-in")))' >/dev/null 2>&1 && echo "true" || echo "false")
    ss_ports=$(echo "$conf" | jq -r '.inbounds[]? | select(.type=="shadowsocks") | select(((.tag//"")|test("^ss-[0-9]+-in$")) or ((.tag//"")|startswith("ss-in"))) | (.listen_port // 0)' 2>/dev/null | awk '$1>0' | sort -n -u | tr "
" " " | sed 's/[[:space:]]*$//')
    has_vmess_ws=$(echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vmess-ws-[0-9]+-in$")) or (.tag=="vmess-ws-in"))' >/dev/null 2>&1 && echo "true" || echo "false")
    has_vless_ws=$(echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vless-ws-[0-9]+-in$")) or (.tag=="vless-ws-in"))' >/dev/null 2>&1 && echo "true" || echo "false")
    has_legacy_wstls=$(echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vless-wstls-[0-9]+-in$")) or (.tag=="vless-ws-tls-in"))' >/dev/null 2>&1 && echo "true" || echo "false")
    has_tuic=$(echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^tuic-[0-9]+-in$")) or (.tag=="tuic-in"))' >/dev/null 2>&1 && echo "true" || echo "false")

    echo -e "${C}当前状态:${NC}"
    echo -e "  [1] vless-reality : $( [ "$has_vless" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [2] anytls        : $( [ "$has_anytls" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [3] shadowsocks   : $( [ "$has_ss" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    if [ "$has_ss" = "true" ] && [ -n "${ss_ports:-}" ]; then
      echo -e "      已安装 SS 端口: ${G}${ss_ports}${NC}"
    fi
    echo -e "  [4] vmess-ws      : $( [ "$has_vmess_ws" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [5] vless-ws      : $( [ "$has_vless_ws" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [6] tuic-v5       : $( [ "$has_tuic" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    if [ "$has_legacy_wstls" = "true" ]; then
      echo -e "      ${Y}检测到旧版 vless-ws-tls，已保留兼容识别${NC}"
    fi

    echo -e "${B}────────────────────────────────────────────────────${NC}"
    echo -e "  ${C}a.${NC} 安装"
    echo -e "  ${C}b.${NC} 卸载"
    echo -e "  ${R}0.${NC} 返回主菜单"
    echo -e "${B}────────────────────────────────────────────────────${NC}"
    read -r -p " 请选择操作: " act
    case "${act:-}" in
      a|A) act="1" ;;
      b|B) act="2" ;;
    esac
    if [[ "${act:-}" == "0" ]]; then
      return 0
    fi

    parse_plus() {
      local s="$1"
      local -A seen=()
      local out=()
      IFS='+' read -ra parts <<< "$s"
      for x in "${parts[@]}"; do
        x="$(echo "$x" | tr -d ' ')"
        [[ -z "$x" ]] && continue
        if [[ -z "${seen[$x]:-}" ]]; then
          out+=("$x")
          seen[$x]=1
        fi
      done
      printf "%s " "${out[@]}"
    }

    if [[ "${act:-}" == "1" ]]; then
      echo -e "
${C}可安装模块（多个用 + 连接，如 1+3+5）:${NC}"
      echo -e "  [1] vless-reality"
      echo -e "  [2] anytls"
      echo -e "  [3] shadowsocks"
      echo -e "  [4] vmess-ws"
      echo -e "  [5] vless-ws"
      echo -e "  [6] tuic-v5"
      read -r -p " 请输入要安装的模块编号: " sel
      local choices; choices="$(parse_plus "${sel:-}")"
      [ -z "${choices:-}" ] && { warn "未选择任何模块。"; pause; continue; }

      local updated_json="$conf"

      for c in $choices; do
        case "$c" in
          1)
            if [ "$has_vless" = "true" ]; then
              echo -e " vless-reality 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " vless-reality 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " 监听端口 (默认: 443): " v_port_in
            local v_port=${v_port_in:-"443"}
            while port_is_in_use "$updated_json" "${v_port}" ""; do
              warn "端口 ${v_port} 已被其它入站占用，请更换端口。"
              read -r -p " 监听端口: " v_port_in
              v_port=${v_port_in:-"443"}
            done
            read -r -p " Private Key: " v_priv
            read -r -p " Short ID: " v_sid
            read -r -p " SNI 域名 (默认: www.icloud.com): " v_sni_in
            local v_sni=${v_sni_in:-"www.icloud.com"}
            local v_uuid v_tag in_v sid_json
            v_uuid=$(sing-box generate uuid)
            if [ -z "${v_sid:-}" ]; then sid_json="[]"; else sid_json="["$v_sid"]"; fi
            v_tag="vless-reality-${v_port}-in"
            in_v=$(jq -n --arg uuid "$v_uuid" --arg tag "$v_tag" --arg sni "$v_sni" --arg priv "$v_priv" --argjson sid "$sid_json" --argjson port "$v_port" '{
              "type":"vless",
              "tag":$tag,
              "listen":"::",
              "listen_port":$port,
              "users":[{"name":$tag,"uuid":$uuid,"flow":"xtls-rprx-vision"}],
              "tls":{
                "enabled":true,
                "server_name":$sni,
                "reality":{
                  "enabled":true,
                  "handshake":{"server":$sni,"server_port":443},
                  "private_key":$priv,
                  "short_id":$sid
                }
              }
            }')
            updated_json=$(echo "$updated_json" | jq --arg t "$v_tag" '.inbounds |= map(select(.tag != $t))')
            updated_json=$(echo "$updated_json" | jq --argjson x "$in_v" '.inbounds += [$x]')
            ;;
          2)
            if [ "$has_anytls" = "true" ]; then
              echo -e " anytls 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " anytls 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " AnyTLS 端口 (默认: 443): " a_port_in
            local a_port=${a_port_in:-"443"}
            while port_is_in_use "$updated_json" "${a_port}" ""; do
              warn "端口 ${a_port} 已被其它入站占用，请更换端口。"
              read -r -p " 监听端口: " a_port_in
              a_port=${a_port_in:-"443"}
            done
            read -r -p " AnyTLS 域名 (默认: www.icloud.com): " a_sni_in
            local a_sni=${a_sni_in:-"www.icloud.com"}
            local a_pass a_tag in_a
            a_pass=$(openssl rand -base64 16)
            openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/sing-box/anytls.key -out /etc/sing-box/anytls.crt -days 36500 -nodes -subj "/CN=${a_sni}" &> /dev/null || true
            a_tag="anytls-${a_port}-in"
            in_a=$(jq -n --arg pass "$a_pass" --arg tag "$a_tag" --arg sni "$a_sni" --argjson port "$a_port" '{
              "type":"anytls",
              "tag":$tag,
              "listen":"::",
              "listen_port":$port,
              "users":[{"name":$tag,"password":$pass}],
              "padding_scheme":[],
              "tls":{"enabled":true,"server_name":$sni,"certificate_path":"/etc/sing-box/anytls.crt","key_path":"/etc/sing-box/anytls.key","alpn":["h2","http/1.1"]}
            }')
            updated_json=$(echo "$updated_json" | jq --arg t "$a_tag" '.inbounds |= map(select(.tag != $t))')
            updated_json=$(echo "$updated_json" | jq --argjson x "$in_a" '.inbounds += [$x]')
            ;;
          3)
            if [ "$has_ss" = "true" ]; then
              echo -e " shadowsocks 模块: ${G}已安装${NC}（可继续添加/覆盖 user）"
              if [ -n "${ss_ports:-}" ]; then echo -e "  已安装 SS 端口: ${G}${ss_ports}${NC}"; fi
            else
              echo -e " shadowsocks 模块: ${Y}未安装，开始安装...${NC}"
            fi

            read -r -p " Shadowsocks 监听端口 (默认: 8080): " ss_port_in
            local ss_port=${ss_port_in:-"8080"}
            if echo "$updated_json" | jq -e --arg p "$ss_port" '
              .inbounds[]?
              | select((.listen_port? // empty | tostring) == $p)
              | select(.type != "shadowsocks")
            ' >/dev/null 2>&1; then
              while true; do
                warn "端口 ${ss_port} 已被其它协议占用，请更换端口。"
                read -r -p " Shadowsocks 监听端口: " ss_port_in
                ss_port=${ss_port_in:-"8080"}
                if ! echo "$updated_json" | jq -e --arg p "$ss_port" '
                  .inbounds[]?
                  | select((.listen_port? // empty | tostring) == $p)
                  | select(.type != "shadowsocks")
                ' >/dev/null 2>&1; then
                  break
                fi
              done
            fi

            local ss_server_p ss_user_p ss_tag new_ss_user
            ss_server_p=$(openssl rand -base64 16)
            ss_user_p=$(openssl rand -base64 16)
            ok "已生成 Shadowsocks 2022 密码（server/user）。"
            ss_tag="ss-${ss_port}-in"
            new_ss_user=$(jq -n --arg name "$ss_tag" --arg p "$ss_user_p" '{"name":$name,"password":$p}')

            updated_json=$(echo "$updated_json" | jq --argjson u "$new_ss_user" --arg port "$ss_port" --arg tag "$ss_tag" --arg sp "$ss_server_p" '
              def is_ss_candidate: ( .type=="shadowsocks" and ((.listen_port|tostring) == $port) and ( ((.tag//"")|startswith("ss-in")) or ((.tag//"")|test("^ss-[0-9]+-in$")) ) );
              if (.inbounds | any(is_ss_candidate)) then
                .inbounds |= map(
                  if is_ss_candidate then
                    .tag = $tag | .listen = "::" | .listen_port = ($port|tonumber) | .method = "2022-blake3-aes-128-gcm" | .password = (.password // $sp) | del(.multiplex) | .users = [$u]
                  else . end
                )
              elif (.inbounds | any(.tag==$tag)) then
                .inbounds |= map(
                  if .tag==$tag then
                    .listen = "::" | .listen_port = ($port|tonumber) | .method = "2022-blake3-aes-128-gcm" | del(.multiplex) | .users = [$u]
                  else . end
                )
              else
                .inbounds += [{"type":"shadowsocks","tag":$tag,"listen":"::","listen_port":($port|tonumber),"method":"2022-blake3-aes-128-gcm","password":$sp,"users":[ $u ]}]
              end
            ')
            ;;
          4)
            if [ "$has_vmess_ws" = "true" ]; then
              echo -e " vmess-ws 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " vmess-ws 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " 监听地址 (默认: 127.0.0.1): " vmess_listen_in
            local vmess_listen=${vmess_listen_in:-"127.0.0.1"}
            read -r -p " 监听端口 (默认: 8001): " vmess_port_in
            local vmess_port=${vmess_port_in:-"8001"}
            while port_is_in_use "$updated_json" "${vmess_port}" ""; do
              warn "端口 ${vmess_port} 已被其它入站占用，请更换端口。"
              read -r -p " 监听端口: " vmess_port_in
              vmess_port=${vmess_port_in:-"8001"}
            done
            read -r -p " WS Path (回车随机生成 7 位字母路径): " vmess_path_in
            local vmess_path; vmess_path=$(normalize_ws_path "${vmess_path_in:-}")
            local vmess_uuid vmess_tag in_vmess
            vmess_uuid=$(sing-box generate uuid)
            vmess_tag="vmess-ws-${vmess_port}-in"
            in_vmess=$(jq -n --arg uuid "$vmess_uuid" --arg tag "$vmess_tag" --arg listen "$vmess_listen" --arg path "$vmess_path" --argjson port "$vmess_port" '{
              "type":"vmess",
              "tag":$tag,
              "listen":$listen,
              "listen_port":$port,
              "users":[{"name":$tag,"uuid":$uuid,"alterId":0}],
              "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
            }')
            updated_json=$(echo "$updated_json" | jq --arg t "$vmess_tag" '.inbounds |= map(select(.tag != $t))')
            updated_json=$(echo "$updated_json" | jq --argjson x "$in_vmess" '.inbounds += [$x]')
            ;;
          5)
            if [ "$has_vless_ws" = "true" ]; then
              echo -e " vless-ws 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " vless-ws 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " 监听地址 (默认: 127.0.0.1): " ws_listen_in
            local ws_listen=${ws_listen_in:-"127.0.0.1"}
            read -r -p " 监听端口 (默认: 8001): " ws_port_in
            local ws_port=${ws_port_in:-"8001"}
            while port_is_in_use "$updated_json" "${ws_port}" ""; do
              warn "端口 ${ws_port} 已被其它入站占用，请更换端口。"
              read -r -p " 监听端口: " ws_port_in
              ws_port=${ws_port_in:-"8001"}
            done
            read -r -p " WS Path (回车随机生成 7 位字母路径): " ws_path_in
            local ws_path; ws_path=$(normalize_ws_path "${ws_path_in:-}")
            local ws_uuid ws_tag in_w
            ws_uuid=$(sing-box generate uuid)
            ws_tag="vless-ws-${ws_port}-in"
            in_w=$(jq -n --arg uuid "$ws_uuid" --arg tag "$ws_tag" --arg listen "$ws_listen" --arg path "$ws_path" --argjson port "$ws_port" '{
              "type":"vless",
              "tag":$tag,
              "listen":$listen,
              "listen_port":$port,
              "users":[{"name":$tag,"uuid":$uuid}],
              "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
            }')
            updated_json=$(echo "$updated_json" | jq --arg t "$ws_tag" '.inbounds |= map(select(.tag != $t))')
            updated_json=$(echo "$updated_json" | jq --argjson x "$in_w" '.inbounds += [$x]')
            ;;
          6)
            if [ "$has_tuic" = "true" ]; then
              echo -e " tuic-v5 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " tuic-v5 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " TUIC 端口 (默认: 443): " t_port_in
            local t_port=${t_port_in:-"443"}
            while echo "$updated_json" | jq -e --arg p "$t_port" '.inbounds[]? | select(.type=="tuic" and ((.listen_port? // empty | tostring) == $p))' >/dev/null 2>&1; do
              warn "端口 ${t_port} 已被其它 TUIC 入站占用，请更换端口。"
              read -r -p " 端口: " t_port_in
              t_port=${t_port_in:-"443"}
            done
            read -r -p " TUIC 域名 (默认: www.icloud.com): " t_sni_in
            local t_sni=${t_sni_in:-"www.icloud.com"}
            local t_pass t_uuid t_tag in_t
            t_pass=$(openssl rand -base64 12)
            t_uuid=$(sing-box generate uuid)
            openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/sing-box/tuic.key -out /etc/sing-box/tuic.crt -days 36500 -nodes -subj "/CN=${t_sni}" &> /dev/null || true
            t_tag="tuic-${t_port}-in"
            in_t=$(jq -n --arg uuid "$t_uuid" --arg pass "$t_pass" --arg tag "$t_tag" --arg sni "$t_sni" --argjson port "$t_port" '{
              "type":"tuic",
              "tag":$tag,
              "listen":"::",
              "listen_port":$port,
              "users":[{"name":$tag,"uuid":$uuid,"password":$pass}],
              "tls":{"enabled":true,"server_name":$sni,"alpn":["h3"],"certificate_path":"/etc/sing-box/tuic.crt","key_path":"/etc/sing-box/tuic.key"},
              "congestion_control":"bbr"
            }')
            updated_json=$(echo "$updated_json" | jq --arg t "$t_tag" '.inbounds |= map(select(.tag != $t))')
            updated_json=$(echo "$updated_json" | jq --argjson x "$in_t" '.inbounds += [$x]')
            ;;
          *)
            warn "忽略无效模块编号：$c"
            ;;
        esac
      done

      updated_json=$(sync_managed_route_rules "$updated_json")
      atomic_save "$updated_json" || true
      conf=$(cat "$CONFIG_FILE")
      pause
      continue
    fi

    if [[ "${act:-}" == "2" ]]; then
      local installed_ids=() installed_names=()
      [ "$has_vless" = "true" ] && { installed_ids+=("1"); installed_names+=("vless-reality"); }
      [ "$has_anytls" = "true" ] && { installed_ids+=("2"); installed_names+=("anytls"); }
      [ "$has_ss" = "true" ] && { installed_ids+=("3"); installed_names+=("shadowsocks"); }
      [ "$has_vmess_ws" = "true" ] && { installed_ids+=("4"); installed_names+=("vmess-ws"); }
      [ "$has_vless_ws" = "true" ] && { installed_ids+=("5"); installed_names+=("vless-ws"); }
      [ "$has_tuic" = "true" ] && { installed_ids+=("6"); installed_names+=("tuic-v5"); }

      if [ ${#installed_ids[@]} -eq 0 ] && [ "$has_legacy_wstls" != "true" ]; then
        warn "当前没有可卸载的核心模块。"
        pause
        continue
      fi

      echo -e "
${R}已安装的核心模块如下（多个用 + 连接，如 1+2）:${NC}"
      local i
      for i in "${!installed_ids[@]}"; do
        echo -e " [${installed_ids[$i]}] ${installed_names[$i]}"
      done
      if [ "$has_legacy_wstls" = "true" ] && [ "$has_vless_ws" != "true" ]; then
        echo -e " [5] vless-ws ${Y}(兼容卸载旧版 vless-ws-tls)${NC}"
      fi

      read -r -p " 请输入要卸载的模块编号: " sel
      local choices; choices="$(parse_plus "${sel:-}")"
      [ -z "${choices:-}" ] && { warn "未选择任何模块。"; pause; continue; }

      local updated_json="$conf"
      for c in $choices; do
        case "$c" in
          1) [ "$has_vless" = "true" ] && { say "卸载 vless-reality..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select((((.tag//"")|test("^vless-reality-[0-9]+-in$")) or (.tag=="vless-reality-in") or (.tag=="vless-main-in")) | not))'); } ;;
          2) [ "$has_anytls" = "true" ] && { say "卸载 anytls..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select((((.type=="anytls") or ((.tag//"")|test("^anytls-[0-9]+-in$"))) | not))'); } ;;
          3) [ "$has_ss" = "true" ] && { say "卸载 shadowsocks..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select(((.type=="shadowsocks") | not)))'); } ;;
          4) [ "$has_vmess_ws" = "true" ] && { say "卸载 vmess-ws..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select((((.tag//"")|test("^vmess-ws-[0-9]+-in$")) or (.tag=="vmess-ws-in")) | not))'); } ;;
          5) { say "卸载 vless-ws（含旧版 vless-ws-tls 兼容清理）..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select((((.tag//"")|test("^vless-ws-[0-9]+-in$")) or (.tag=="vless-ws-in") or ((.tag//"")|test("^vless-wstls-[0-9]+-in$")) or (.tag=="vless-ws-tls-in")) | not))'); } ;;
          6) [ "$has_tuic" = "true" ] && { say "卸载 tuic-v5..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select((((.tag//"")|test("^tuic-[0-9]+-in$")) or (.tag=="tuic-in")) | not))'); } ;;
          *) warn "忽略无效模块编号：$c" ;;
        esac
      done

      updated_json=$(sync_managed_route_rules "$updated_json")
      atomic_save "$updated_json" || true
      conf=$(cat "$CONFIG_FILE")
      pause
      continue
    fi

    warn "无效输入：$act"
    pause
  done
}


# ====================================================
# 5) Add/overwrite relay node
# ====================================================
add_relay_node() {
  init_manager_env
  local conf; conf=$(cat "$CONFIG_FILE")

  echo -e "
${C}─── 添加/覆盖中转节点 ───${NC}"
  echo -e " 主入站协议："
  echo -e "  ${C}1.${NC} vless-reality"
  echo -e "  ${C}2.${NC} anytls"
  echo -e "  ${C}3.${NC} shadowsocks"
  echo -e "  ${C}4.${NC} vmess-ws"
  echo -e "  ${C}5.${NC} vless-ws"
  while true; do
    read -r -p " 请选择: " in_choice
    case "${in_choice:-}" in
      "") return 0 ;;
      1|2|3|4|5) break ;;
      *) warn "无效选择，请输入 1/2/3/4/5，或直接回车返回上一级。" ;;
    esac
  done

  local relay_in_tag="" relay_proto="" relay_port="0"

  case "$in_choice" in
    1)
      relay_in_tag=$(echo "$conf" | jq -r '
        ( .inbounds[]? | select((.tag//"")|test("^vless-reality-[0-9]+-in$")) | .tag ) ,
        ( .inbounds[]? | select(.tag=="vless-reality-in") | .tag ) ,
        ( .inbounds[]? | select(.tag=="vless-main-in") | .tag )
      ' 2>/dev/null | head -n1)
      [ -z "${relay_in_tag:-}" ] && { err "未检测到 vless-reality 入站。请先在选项4安装 vless-reality。"; pause; return 1; }
      relay_proto="vless-reality"
      ;;
    2)
      local any_candidates_json any_count
      any_candidates_json=$(echo "$conf" | jq -c '[.inbounds[]? | select((.type=="anytls") or ((.tag//"")|test("^anytls-[0-9]+-in$"))) | {tag:(.tag//""), port:(.listen_port//0)}]' 2>/dev/null)
      any_count=$(echo "$any_candidates_json" | jq -r 'length' 2>/dev/null || echo "0")
      [ "${any_count:-0}" -le 0 ] && { err "未检测到 anytls 入站。请先在选项4安装 anytls。"; pause; return 1; }
      if [ "${any_count:-0}" -eq 1 ]; then
        relay_in_tag=$(echo "$any_candidates_json" | jq -r '.[0].tag')
      else
        echo -e "
${C}检测到多个 AnyTLS 入站端口，请选择一个作为中转主入站：${NC}"
        local i
        for i in $(seq 0 $((any_count-1))); do
          echo -e "  [$(($i+1))] $(echo "$any_candidates_json" | jq -r ".[$i].tag")  (port=$(echo "$any_candidates_json" | jq -r ".[$i].port"))"
        done
        local pick
        read -r -p " 请输入编号: " pick
        if [[ ! "${pick:-}" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$any_count" ]; then err "无效选择。"; pause; return 1; fi
        relay_in_tag=$(echo "$any_candidates_json" | jq -r ".[$(($pick-1))].tag")
      fi
      relay_proto="anytls"
      ;;
    3)
      local ss_candidates_json ss_count
      ss_candidates_json=$(echo "$conf" | jq -c '[.inbounds[]? | select(.type=="shadowsocks") | select(((.tag//"")|test("^ss-[0-9]+-in$")) or ((.tag//"")|startswith("ss-in"))) | {tag:(.tag//""), port:(.listen_port//0), method:(.method//"aes-128-gcm")}]' 2>/dev/null)
      ss_count=$(echo "$ss_candidates_json" | jq -r 'length' 2>/dev/null || echo "0")
      [ "${ss_count:-0}" -le 0 ] && { err "未检测到本机 SS 入站。请先在选项4创建 SS 节点。"; pause; return 1; }
      if [ "${ss_count:-0}" -eq 1 ]; then
        relay_in_tag=$(echo "$ss_candidates_json" | jq -r '.[0].tag')
      else
        echo -e "
${C}检测到多个 SS 入站端口，请选择一个作为中转主入站：${NC}"
        local i
        for i in $(seq 0 $((ss_count-1))); do
          echo -e "  [$(($i+1))] $(echo "$ss_candidates_json" | jq -r ".[$i].tag")  (port=$(echo "$ss_candidates_json" | jq -r ".[$i].port"), method=$(echo "$ss_candidates_json" | jq -r ".[$i].method"))"
        done
        local pick
        read -r -p " 请输入编号: " pick
        if [[ ! "${pick:-}" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$ss_count" ]; then err "无效选择。"; pause; return 1; fi
        relay_in_tag=$(echo "$ss_candidates_json" | jq -r ".[$(($pick-1))].tag")
      fi
      relay_proto="ss"
      ;;
    4)
      local vmess_candidates_json vmess_count
      vmess_candidates_json=$(echo "$conf" | jq -c '[.inbounds[]? | select(((.tag//"")|test("^vmess-ws-[0-9]+-in$")) or (.tag=="vmess-ws-in")) | {tag:(.tag//""), port:(.listen_port//0), path:(.transport.path // "/")}]' 2>/dev/null)
      vmess_count=$(echo "$vmess_candidates_json" | jq -r 'length' 2>/dev/null || echo "0")
      [ "${vmess_count:-0}" -le 0 ] && { err "未检测到 vmess-ws 入站。请先在选项4安装 vmess-ws。"; pause; return 1; }
      if [ "${vmess_count:-0}" -eq 1 ]; then
        relay_in_tag=$(echo "$vmess_candidates_json" | jq -r '.[0].tag')
      else
        echo -e "
${C}检测到多个 vmess-ws 入站端口，请选择一个作为中转主入站：${NC}"
        local i
        for i in $(seq 0 $((vmess_count-1))); do
          echo -e "  [$(($i+1))] $(echo "$vmess_candidates_json" | jq -r ".[$i].tag")  (port=$(echo "$vmess_candidates_json" | jq -r ".[$i].port"), path=$(echo "$vmess_candidates_json" | jq -r ".[$i].path"))"
        done
        local pick
        read -r -p " 请输入编号: " pick
        if [[ ! "${pick:-}" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$vmess_count" ]; then err "无效选择。"; pause; return 1; fi
        relay_in_tag=$(echo "$vmess_candidates_json" | jq -r ".[$(($pick-1))].tag")
      fi
      relay_proto="vmess-ws"
      ;;
    5)
      local ws_candidates_json ws_count
      ws_candidates_json=$(echo "$conf" | jq -c '[.inbounds[]? | select(((.tag//"")|test("^vless-ws-[0-9]+-in$")) or (.tag=="vless-ws-in")) | {tag:(.tag//""), port:(.listen_port//0), path:(.transport.path // "/")}]' 2>/dev/null)
      ws_count=$(echo "$ws_candidates_json" | jq -r 'length' 2>/dev/null || echo "0")
      [ "${ws_count:-0}" -le 0 ] && { err "未检测到 vless-ws 入站。请先在选项4安装 vless-ws。"; pause; return 1; }
      if [ "${ws_count:-0}" -eq 1 ]; then
        relay_in_tag=$(echo "$ws_candidates_json" | jq -r '.[0].tag')
      else
        echo -e "
${C}检测到多个 vless-ws 入站端口，请选择一个作为中转主入站：${NC}"
        local i
        for i in $(seq 0 $((ws_count-1))); do
          echo -e "  [$(($i+1))] $(echo "$ws_candidates_json" | jq -r ".[$i].tag")  (port=$(echo "$ws_candidates_json" | jq -r ".[$i].port"), path=$(echo "$ws_candidates_json" | jq -r ".[$i].path"))"
        done
        local pick
        read -r -p " 请输入编号: " pick
        if [[ ! "${pick:-}" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$ws_count" ]; then err "无效选择。"; pause; return 1; fi
        relay_in_tag=$(echo "$ws_candidates_json" | jq -r ".[$(($pick-1))].tag")
      fi
      relay_proto="vless-ws"
      ;;
  esac

  relay_port=$(echo "$conf" | jq -r --arg tag "$relay_in_tag" '.inbounds[]? | select(.tag==$tag) | .listen_port // empty' 2>/dev/null | head -n1)
  [ -z "${relay_port:-}" ] && relay_port="0"

  echo -e "
${C}─── 添加/覆盖中转节点 ───${NC}"
  read -r -p " 落地标识 (如 sg01): " land; [ -z "${land:-}" ] && return 1
  read -r -p " 落地 IP 地址: " ip; [ -z "${ip:-}" ] && return 1
  read -r -p " 落地 SS 2022 密钥（回车随机生成）: " pw
  if [ -z "${pw:-}" ]; then
    local pw_server pw_user
    pw_server=$(openssl rand -base64 16)
    pw_user=$(openssl rand -base64 16)
    pw="${pw_server}:${pw_user}"
    ok "已生成落地 SS 2022 密钥（server:user）。"
  else
    local pw_server pw_user
    pw_server="${pw%%:*}"
    pw_user=""
    if [[ "$pw" == *:* ]]; then pw_user="${pw#*:}"; fi
    if ! echo "$pw_server" | base64 -d >/dev/null 2>&1; then
      warn "server 密钥不是合法 Base64，已为你生成新的 server Base64 密钥。"
      pw_server=$(openssl rand -base64 16)
    fi
    if [ -n "${pw_user:-}" ]; then
      if ! echo "$pw_user" | base64 -d >/dev/null 2>&1; then
        warn "user 密钥不是合法 Base64，已为你生成新的 user Base64 密钥。"
        pw_user=$(openssl rand -base64 16)
      fi
      pw="${pw_server}:${pw_user}"
    else
      pw="${pw_server}"
    fi
  fi

  local land_id="$land"
  local user out uuid new_u new_o updated_json
  user="${relay_proto}-${relay_port}-to-${land_id}"
  out="out-to-${land_id}"
  uuid=$(sing-box generate uuid)

  if [ "$relay_proto" = "ss" ]; then
    local relay_ss_pass
    relay_ss_pass=$(openssl rand -base64 16)
    new_u=$(jq -n --arg name "$user" --arg pass "$relay_ss_pass" '{"name":$name,"password":$pass}')
  elif [ "$relay_proto" = "vless-reality" ]; then
    new_u=$(jq -n --arg name "$user" --arg uuid "$uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')
  elif [ "$relay_proto" = "anytls" ]; then
    local relay_any_pass
    relay_any_pass=$(openssl rand -base64 16)
    new_u=$(jq -n --arg name "$user" --arg pass "$relay_any_pass" '{"name":$name,"password":$pass}')
  elif [ "$relay_proto" = "vmess-ws" ]; then
    new_u=$(jq -n --arg name "$user" --arg uuid "$uuid" '{"name":$name,"uuid":$uuid,"alterId":0}')
  else
    new_u=$(jq -n --arg name "$user" --arg uuid "$uuid" '{"name":$name,"uuid":$uuid}')
  fi

  new_o=$(jq -n --arg tag "$out" --arg addr "$ip" --arg key "$pw" '{
    "type":"shadowsocks","tag":$tag,"server":$addr,"server_port":8080,
    "method":"2022-blake3-aes-128-gcm","password":$key
  }')

  updated_json=$(echo "$conf" | jq --arg user "$user" '(.inbounds[]? | select(.users?!=null).users) |= (map(select((.name? // "") != $user)))')
  updated_json=$(echo "$updated_json" | jq --arg out "$out" '.outbounds |= map(select(.tag != $out))')
  updated_json=$(remove_relay_rule_safely "$updated_json" "$user")
  updated_json=$(echo "$updated_json" | jq --argjson u "$new_u" --arg relayTag "$relay_in_tag" '(.inbounds[] | select(.tag == $relayTag).users) += [$u]')
  updated_json=$(echo "$updated_json" | jq --argjson o "$new_o" '.outbounds += [$o]')
  local new_r
  new_r=$(jq -n --arg user "$user" --arg out "$out" '{"auth_user":[$user],"outbound":$out}')
  updated_json=$(echo "$updated_json" | jq --argjson r "$new_r" 'if type=="array" then {"log":{"level":"info","timestamp":true},"inbounds":.,"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}} else . end | .inbounds=(.inbounds//[]) | .outbounds=(.outbounds//[]) | .route=(.route//{"rules":[]}) | .route.rules=(.route.rules//[]) | .route.rules = [$r] + (.route.rules // [])')
  updated_json=$(sync_managed_route_rules "$updated_json")
  atomic_save "$updated_json"
}


manage_relay_nodes() {
  while true; do
    clear
    local conf
    conf=$(cat "$CONFIG_FILE" 2>/dev/null || echo '{}')

    echo -e "\n${C}─── 中转节点管理 ───${NC}"

    mapfile -t __relay_nodes < <(
      echo "$conf" | jq -r '(.inbounds[]? | (.users? // []))[]? | .name // empty' 2>/dev/null \
        | grep -E -- '(-to-|^relay-)' | sort -u || true
    )
    if [ ${#__relay_nodes[@]} -eq 0 ]; then
      echo -e " ${Y}当前未安装中转节点。${NC}"
    else
      echo -e " ${C}当前已安装中转节点：${NC}"
      local __n
      for __n in "${__relay_nodes[@]}"; do
        echo -e "   - ${G}${__n}${NC}"
      done
    fi

    echo
    echo -e "  ${C}1.${NC} 添加/覆盖"
    echo -e "  ${C}2.${NC} 删除"
    echo -e "  ${R}0.${NC} 返回主菜单"
    echo -e "${B}────────────────────────────────────────────────────${NC}"
    read -r -p " 请选择操作: " act
    case "${act:-}" in
      1) add_relay_node || true ;;
      2) del_relay_node || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}


# ====================================================
# 6) Delete relay node
# ====================================================
del_relay_node() {
  init_manager_env
  local conf; conf=$(cat "$CONFIG_FILE")

  mapfile -t nodes < <(
    echo "$conf" | jq -r '(.inbounds[]? | (.users? // []))[]? | .name // empty' 2>/dev/null \
      | grep -E -- '(-to-|^relay-)' | sort -u || true
  )

  if [ ${#nodes[@]} -eq 0 ]; then
    warn "暂无已配置的中转节点。"
    pause
    return 0
  fi

  echo -e "\n${R}─── 删除中转节点 ───${NC}"
  for i in "${!nodes[@]}"; do
    echo -e " [$(($i+1))] ${nodes[$i]}"
  done
  read -r -p " 请输入要删除的编号（支持 1+2+3，回车返回）: " choice
  [ -z "${choice:-}" ] && return 0

  if ! [[ "$choice" =~ ^[0-9]+([+][0-9]+)*$ ]]; then
    err "输入格式无效。"
    pause
    return 1
  fi

  local -a picks=()
  local part
  IFS='+' read -r -a picks <<< "$choice"

  local updated_json="$conf"
  local seen=" "
  for part in "${picks[@]}"; do
    if ! [[ "$part" =~ ^[0-9]+$ ]] || [ "$part" -lt 1 ] || [ "$part" -gt "${#nodes[@]}" ]; then
      err "编号 ${part} 超出范围。"
      pause
      return 1
    fi
    case "$seen" in
      *" $part "*) continue ;;
      *) seen="${seen}${part} " ;;
    esac

    local relay_user="${nodes[$(($part-1))]}"
    local land="${relay_user##*-}"
    local out="out-to-$land"

    updated_json=$(echo "$updated_json" | jq --arg u "$relay_user" --arg o "$out" '
      (.inbounds[]? | select(.users? != null).users) |= (map(select((.name? // "") != $u)))
      | .outbounds |= map(select((.tag // "") != $o))
    ')

    updated_json=$(remove_relay_rule_safely "$updated_json" "$relay_user")
  done

  updated_json=$(sync_managed_route_rules "$updated_json")
  atomic_save "$updated_json"
  pause
  return 0
}

# ====================================================
# 7) Export client configs
# ====================================================
export_configs() {
  init_manager_env
  clear
  local conf; conf=$(cat "$CONFIG_FILE")
  local ip; ip=$(get_public_ip)

  echo -e "
${C}─── 节点配置导出 ───${NC}"

  norm_core_tag() { # $1 inbound_tag, $2 listen_port
    local t="$1"; local p="$2"
    case "$t" in
      vless-main-in|vless-reality-in) echo "vless-reality-${p}-in" ;;
      vless-ws-tls-in|vless-wstls-${p}-in) echo "vless-ws-tls-${p}-in" ;;
      vless-ws-in|vless-ws-${p}-in) echo "vless-ws-tls-${p}-in" ;;
      vmess-ws-in|vmess-ws-${p}-in) echo "vmess-ws-tls-${p}-in" ;;
      tuic-in|tuic-${p}-in) echo "tuic-${p}-in" ;;
      ss-in|ss-in-*|ss-${p}-in) echo "ss-${p}-in" ;;
      *) echo "$t" ;;
    esac
  }

  local v_pbk="PUBLIC_KEY_MISSING"
  if echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vless-reality-[0-9]+-in$")) or (.tag=="vless-reality-in") or (.tag=="vless-main-in"))' >/dev/null 2>&1; then
    read -r -p " 请输入 Reality Public Key (默认: PUBLIC_KEY_MISSING): " v_pbk_in
    v_pbk=${v_pbk_in:-"PUBLIC_KEY_MISSING"}
  fi

  local ws_tls_domain="example.com"
  if echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vless-wstls-[0-9]+-in$")) or (.tag=="vless-ws-tls-in") or ((.tag//"")|test("^vless-ws-[0-9]+-in$")) or (.tag=="vless-ws-in"))' >/dev/null 2>&1; then
    read -r -p " 请输入 vless-ws-tls 域名 (SNI/Host，默认: example.com): " ws_tls_domain_in
    ws_tls_domain=${ws_tls_domain_in:-"example.com"}
  fi
  local ws_tls_public_port=443

  local vmess_ws_domain="example.com"
  if echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vmess-ws-[0-9]+-in$")) or (.tag=="vmess-ws-in"))' >/dev/null 2>&1; then
    read -r -p " 请输入 vmess-ws-tls 域名 (SNI/Host，默认: example.com): " vmess_ws_domain_in
    vmess_ws_domain=${vmess_ws_domain_in:-"example.com"}
  fi
  local vmess_ws_public_port=443

  # -------- vless-ws-tls direct + relay (兼容旧版 vless-wstls + 新版 vless-ws) --------
  if echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vless-wstls-[0-9]+-in$")) or (.tag=="vless-ws-tls-in") or ((.tag//"")|test("^vless-ws-[0-9]+-in$")) or (.tag=="vless-ws-in"))' >/dev/null 2>&1; then
    echo "$conf" | jq -c '
      .inbounds[]?
      | select(((.tag//"")|test("^vless-wstls-[0-9]+-in$")) or (.tag=="vless-ws-tls-in") or ((.tag//"")|test("^vless-ws-[0-9]+-in$")) or (.tag=="vless-ws-in"))
      | {tag:(.tag//""), port:(.listen_port//0), path:(.transport.path // "/"), users:(.users // [])}
    ' | while read -r inbound; do
      local in_tag in_port core_tag path
      in_tag=$(echo "$inbound" | jq -r '.tag')
      in_port=$(echo "$inbound" | jq -r '.port')
      core_tag=$(norm_core_tag "$in_tag" "$in_port")
      path=$(echo "$inbound" | jq -r '.path')
      echo "$inbound" | jq -c '.users[]?' | while read -r u; do
        local uname uuid out_tag
        uname=$(echo "$u" | jq -r '.name // empty')
        uuid=$(echo "$u" | jq -r '.uuid // empty')
        [ -z "${uuid:-}" ] && continue
        if [ "${uname:-}" = "${in_tag:-}" ] || [ "${uname:-}" = "${core_tag:-}" ] || [ "${uname:-}" = "vless-ws-tls-in" ] || [ "${uname:-}" = "vless-ws-in" ]; then
          out_tag="${core_tag}"
        else
          out_tag="${uname}"
        fi
        echo -e "\n${W}[${out_tag}]${NC}"
        echo -e " Clash: - {name: ${out_tag}, type: vless, server: $ip, port: ${ws_tls_public_port}, uuid: ${uuid}, udp: true, tls: true, network: ws, servername: ${ws_tls_domain}, ws-opts: {path: \"${path}\", headers: {Host: ${ws_tls_domain}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}}"
        echo ""
        echo -e " Quantumult X: vless=$ip:${ws_tls_public_port},method=none,password=${uuid},obfs=wss,obfs-host=${ws_tls_domain},obfs-uri=${path}?ed=2048,fast-open=false,udp-relay=true,tag=${out_tag}"
      done
    done
  fi

  # -------- vmess-ws-tls direct + relay --------
  if echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vmess-ws-[0-9]+-in$")) or (.tag=="vmess-ws-in"))' >/dev/null 2>&1; then
    echo "$conf" | jq -c '
      .inbounds[]?
      | select(((.tag//"")|test("^vmess-ws-[0-9]+-in$")) or (.tag=="vmess-ws-in"))
      | {tag:(.tag//""), port:(.listen_port//0), path:(.transport.path // "/"), users:(.users // [])}
    ' | while read -r inbound; do
      local in_tag in_port core_tag path
      in_tag=$(echo "$inbound" | jq -r '.tag')
      in_port=$(echo "$inbound" | jq -r '.port')
      core_tag=$(norm_core_tag "$in_tag" "$in_port")
      path=$(echo "$inbound" | jq -r '.path')
      echo "$inbound" | jq -c '.users[]?' | while read -r u; do
        local uname uuid out_tag
        uname=$(echo "$u" | jq -r '.name // empty')
        uuid=$(echo "$u" | jq -r '.uuid // empty')
        [ -z "${uuid:-}" ] && continue
        if [ "${uname:-}" = "${in_tag:-}" ] || [ "${uname:-}" = "${core_tag:-}" ] || [ "${uname:-}" = "vmess-ws-in" ]; then
          out_tag="${core_tag}"
        else
          out_tag="${uname}"
        fi
        echo -e "\n${W}[${out_tag}]${NC}"
        echo -e " Clash: - {name: ${out_tag}, type: vmess, server: $ip, port: ${vmess_ws_public_port}, uuid: ${uuid}, alterId: 0, cipher: auto, udp: true, tls: true, network: ws, servername: ${vmess_ws_domain}, ws-opts: {path: \"${path}\", headers: {Host: ${vmess_ws_domain}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}}"
        echo ""
        echo -e " Quantumult X: vmess=$ip:${vmess_ws_public_port}, method=chacha20-poly1305, password=${uuid}, obfs=wss, obfs-host=${vmess_ws_domain}, obfs-uri=${path}?ed=2048, fast-open=false, udp-relay=true, tag=${out_tag}"
        echo ""
        echo -e " Surge: ${out_tag} = vmess, ${ip}, ${vmess_ws_public_port}, username=${uuid}, tls=true, vmess-aead=true, ws=true, ws-path=${path}?ed=2048, sni=${vmess_ws_domain}, ws-headers=Host:${vmess_ws_domain}, skip-cert-verify=false, udp-relay=true, tfo=false"
      done
    done
  fi

  # -------- tuic direct --------
  if echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^tuic-[0-9]+-in$")) or (.tag=="tuic-in"))' >/dev/null 2>&1; then
    local in_tag in_port tag uuid pass sni
    in_tag=$(echo "$conf" | jq -r '.inbounds[]? | select(((.tag//"")|test("^tuic-[0-9]+-in$")) or (.tag=="tuic-in")) | .tag' | head -n1)
    in_port=$(echo "$conf" | jq -r --arg t "$in_tag" '.inbounds[]? | select(.tag==$t) | .listen_port' | head -n1)
    tag=$(norm_core_tag "$in_tag" "$in_port")
    uuid=$(echo "$conf" | jq -r --arg t "$in_tag" '.inbounds[] | select(.tag==$t) | .users[0].uuid' | head -n1)
    pass=$(echo "$conf" | jq -r --arg t "$in_tag" '.inbounds[] | select(.tag==$t) | .users[0].password' | head -n1)
    sni=$(echo "$conf" | jq -r --arg t "$in_tag" '.inbounds[] | select(.tag==$t) | .tls.server_name // "www.icloud.com"' | head -n1)

    echo -e "
${W}[${tag}]${NC}"
    echo -e " Clash: - {name: ${tag}, type: tuic, server: $ip, port: $in_port, uuid: $uuid, password: $pass, alpn: [h3], disable-sni: false, reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true, sni: $sni}"
    echo ""
    echo -e " Surge: tuic-v5 = tuic-v5, ${ip}, ${in_port}, password=${pass}, sni=${sni}, uuid=${uuid}, alpn=h3, ecn=true"
  fi

  # -------- anytls direct + relay --------
  if echo "$conf" | jq -e '.inbounds[]? | select((.type=="anytls") or ((.tag//"")|test("^anytls-[0-9]+-in$")))' >/dev/null 2>&1; then
    echo "$conf" | jq -c '
      .inbounds[]?
      | select((.type=="anytls") or ((.tag//"")|test("^anytls-[0-9]+-in$")))
      | {tag:(.tag//""), port:(.listen_port//0), sni:(.tls.server_name // "www.icloud.com"), users:(.users // [])}
    ' | while read -r inbound; do
      local in_tag in_port sni core_tag
      in_tag=$(echo "$inbound" | jq -r '.tag')
      in_port=$(echo "$inbound" | jq -r '.port')
      sni=$(echo "$inbound" | jq -r '.sni')
      core_tag="anytls-${in_port}-in"
      echo "$inbound" | jq -c '.users[]?' | while read -r u; do
        local pass uname out_tag
        uname=$(echo "$u" | jq -r '.name // empty')
        pass=$(echo "$u" | jq -r '.password // empty')
        [ -z "${pass:-}" ] && continue
        if [ -z "${uname:-}" ] || [ "${uname:-}" = "${in_tag:-}" ] || [ "${uname:-}" = "${core_tag:-}" ]; then
          out_tag="${core_tag}"
        else
          out_tag="${uname}"
        fi
        echo -e "
${W}[${out_tag}]${NC}"
        echo -e " Clash: - {name: ${out_tag}, type: anytls, server: $ip, port: ${in_port}, password: "${pass}", client-fingerprint: chrome, udp: true, sni: "${sni}", alpn: [h2, http/1.1], skip-cert-verify: true}"
        echo ""
        echo -e " Surge: ${out_tag} = anytls, ${ip}, ${in_port}, password=${pass}, skip-cert-verify=true, sni=${sni}"
      done
    done
  fi

  # -------- vless-reality direct + relay --------
  if echo "$conf" | jq -e '.inbounds[]? | select(((.tag//"")|test("^vless-reality-[0-9]+-in$")) or (.tag=="vless-reality-in") or (.tag=="vless-main-in"))' >/dev/null 2>&1; then
    echo "$conf" | jq -c '
      .inbounds[]?
      | select(((.tag//"")|test("^vless-reality-[0-9]+-in$")) or (.tag=="vless-reality-in") or (.tag=="vless-main-in"))
      | {tag:(.tag//""), port:(.listen_port//0), sni:(.tls.server_name // "www.icloud.com"), sid:(.tls.reality.short_id[0] // ""), users:(.users // [])}
    ' | while read -r inbound; do
      local in_tag in_port core_tag sni sid
      in_tag=$(echo "$inbound" | jq -r '.tag')
      in_port=$(echo "$inbound" | jq -r '.port')
      core_tag=$(norm_core_tag "$in_tag" "$in_port")
      sni=$(echo "$inbound" | jq -r '.sni')
      sid=$(echo "$inbound" | jq -r '.sid')
      echo "$inbound" | jq -c '.users[]?' | while read -r u; do
        local uname uuid flow out_tag
        uname=$(echo "$u" | jq -r '.name // empty')
        uuid=$(echo "$u" | jq -r '.uuid // empty')
        flow=$(echo "$u" | jq -r '.flow // "xtls-rprx-vision"')
        [ -z "${uuid:-}" ] && continue
        if [ -z "${uname:-}" ] || [ "${uname:-}" = "${in_tag:-}" ] || [ "${uname:-}" = "${core_tag:-}" ] || [ "${uname:-}" = "vless-reality-user" ] || [ "${uname:-}" = "direct-user" ]; then
          out_tag="${core_tag}"
        else
          out_tag="${uname}"
        fi
        echo -e "
${W}[${out_tag}]${NC}"
        echo -e " Clash: - {name: ${out_tag}, type: vless, server: $ip, port: $in_port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: ${flow}, servername: $sni, reality-opts: {public-key: $v_pbk, short-id: '$sid'}, client-fingerprint: chrome}"
        echo ""
        echo -e " Quantumult X: vless=$ip:$in_port, method=none, password=$uuid, obfs=over-tls, obfs-host=$sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$sid, vless-flow=${flow}, udp-relay=true, tag=${out_tag}"
      done
    done
  fi

  # -------- shadowsocks direct + relay --------
  if echo "$conf" | jq -e '.inbounds[]? | select(.type=="shadowsocks") | select(((.tag//"")|test("^ss-[0-9]+-in$")) or ((.tag//"")|startswith("ss-in")))' >/dev/null 2>&1; then
    echo "$conf" | jq -c '
      .inbounds[]?
      | select(.type=="shadowsocks")
      | select(((.tag//"")|test("^ss-[0-9]+-in$")) or ((.tag//"")|startswith("ss-in")))
      | {tag:(.tag//""), port:(.listen_port//0), sp:(.password // ""), users:(if .users? then .users elif .password? then [{"name":(.tag//"default"),"password":.password}] else [] end), method:(.method//"2022-blake3-aes-128-gcm")}
    ' | while read -r inbound; do
      local in_tag in_port method core_tag sp
      in_tag=$(echo "$inbound" | jq -r '.tag')
      in_port=$(echo "$inbound" | jq -r '.port')
      method=$(echo "$inbound" | jq -r '.method')
      core_tag=$(norm_core_tag "$in_tag" "$in_port")
      sp=$(echo "$inbound" | jq -r '.sp // ""')
      echo "$inbound" | jq -c '.users[]?' | while read -r u; do
        local uname pass out_tag pw_out
        uname=$(echo "$u" | jq -r '.name // empty')
        pass=$(echo "$u" | jq -r '.password // empty')
        [ -z "${pass:-}" ] && continue
        if [ -z "${uname:-}" ] || [ "${uname:-}" = "${in_tag:-}" ] || [ "${uname:-}" = "${core_tag:-}" ]; then
          out_tag="${core_tag}"
        else
          out_tag="${uname}"
        fi
        if [ -n "${sp:-}" ] && [ "${sp}" != "null" ] && [ "${sp}" != "${pass}" ]; then pw_out="${sp}:${pass}"; else pw_out="${pass}"; fi
        echo -e "
${W}[${out_tag}]${NC}"
        echo -e " Clash: - {name: "${out_tag}", type: ss, server: $ip, port: ${in_port}, cipher: ${method}, password: "${pw_out}", udp: true}"
        echo ""
        echo -e " Quantumult X: shadowsocks=$ip:${in_port}, method=${method}, password=${pw_out}, udp-relay=true, tag=${out_tag}"
        echo ""
        echo -e " Surge: ${out_tag} = ss, ${ip}, ${in_port}, encrypt-method=${method}, password=${pw_out}, udp-relay=true"
      done
    done
  fi

  echo ""
  read -n 1 -p "按任意键返回主菜单..."
}


# ====================================================
# 7) One-click sync system time (chrony/chronyc)
# ====================================================
sync_system_time_chrony() {
  require_root
  clear
  echo -e "${R}─── 一键同步系统时间 ───${NC}"

  say "步骤 1/5：检查 chrony 是否安装"
  if ! has_cmd chronyc; then
    warn "未检测到 chrony，开始安装..."
    apt_update_once
    apt-get install -y chrony || { err "chrony 安装失败。"; pause; return 1; }
    ok "chrony 安装完成。"
  else
    ok "已检测到 chrony。"
  fi

  say "步骤 2/5：关闭 systemd-timesyncd（如存在）"
  systemctl stop systemd-timesyncd >/dev/null 2>&1 || true
  systemctl disable systemd-timesyncd >/dev/null 2>&1 || true
  ok "已尝试关闭 systemd-timesyncd。"

  say "步骤 3/5：检查并修复 chrony 服务状态"
  if chronyc tracking >/dev/null 2>&1 && [ "$(systemctl is-active chrony 2>/dev/null)" = "active" ]; then
    ok "chrony 已正常运行，且 systemd 状态正常。"
  else
    warn "检测到 chrony 未运行或 systemd 状态异常，开始重建服务状态..."
    systemctl stop chrony >/dev/null 2>&1 || true
    pkill -9 chronyd >/dev/null 2>&1 || true
    rm -f /run/chrony/chronyd.pid >/dev/null 2>&1 || true
    systemctl reset-failed chrony >/dev/null 2>&1 || true
    systemctl start chrony >/dev/null 2>&1 || true
    sleep 2
    if [ "$(systemctl is-active chrony 2>/dev/null)" = "active" ]; then
      ok "chrony 服务已正常启动，systemd 状态已恢复。"
    else
      err "chrony 启动后 systemd 状态仍异常。"
      systemctl status chrony --no-pager -l || true
      pause
      return 1
    fi
  fi

  say "步骤 4/5：设置 chrony 开机自启"
  systemctl enable chrony >/dev/null 2>&1 || true
  ok "chrony 已设置为开机自启。"

  say "步骤 5/5：执行一次强制时间同步"
  chronyc -a makestep >/dev/null 2>&1 || true
  ok "时间同步完成。"

  echo
  systemctl status chrony --no-pager -l || true
  echo
  pause
}

# ====================================================
# 8) Uninstall sing-box (keep /etc/sing-box/)
# ====================================================
uninstall_singbox_keep_config() {
  require_root
  clear
  echo -e "${R}─── 卸载 sing-box（保留 /etc/sing-box/ 配置）───${NC}"

  echo -e "${Y}注意：该操作将卸载 sing-box 程序包（配置目录 /etc/sing-box/ 保留）。${NC}"
  read -r -p "输入 YES 确认继续，其它任意输入取消: " __cfm
  if [ "${__cfm:-}" != "YES" ]; then
    warn "已取消卸载。"
    pause
    return 0
  fi


  if ! has_cmd apt-get; then
    err "未找到 apt-get，本卸载流程按 APT 包管理设计。"
    pause
    return 1
  fi

  if has_cmd systemctl; then
    say "停止服务（如存在）：systemctl stop sing-box"
    systemctl stop sing-box >/dev/null 2>&1 || true
    ok "已尝试停止 sing-box 服务。"
  fi

  if pkg_installed sing-box || pkg_installed sing-box-beta; then
    say "执行卸载（remove，不 purge）："
    pkg_installed sing-box && apt-get remove -y sing-box || true
    pkg_installed sing-box-beta && apt-get remove -y sing-box-beta || true
    ok "卸载流程完成（配置保留）。"
  else
    warn "未检测到 sing-box/sing-box-beta 已安装，无需卸载。"
  fi

  if [ -d /etc/sing-box ]; then
    ok "配置目录仍存在：/etc/sing-box（符合你的要求）"
  else
    warn "未找到 /etc/sing-box（可能你之前手动删除过）。"
  fi

  pause
}

# ---------- Menu ----------
main_menu() {
  ensure_sb_shortcut
  while true; do
    clear
    echo -e "${B}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│     Sing-box Elite 管理系统 + Installer V-2.2.7  │${NC}"
    echo -e "${B}└──────────────────────────────────────────────────┘${NC}"
    echo -e "  ${C}1.${NC} 安装/更新 sing-box"
    echo -e "  ${C}2.${NC} 清空/重置 config.json"
    echo -e "  ${C}3.${NC} 查看配置文件"
    echo -e "  ${C}4.${NC} 核心模块管理"
    echo -e "  ${C}5.${NC} 中转节点管理"
    echo -e "  ${C}6.${NC} 导出客户端配置"
    echo -e "  ${C}7.${NC} 一键同步系统时间"
    echo -e "  ${C}8.${NC} 卸载 sing-box"
    echo -e "  ${R}0.${NC} 退出系统"
    echo -e "${B}────────────────────────────────────────────────────${NC}"
    read -r -p " 请选择操作指令: " opt
    case "${opt:-}" in
      1) install_or_update_singbox ;;
      2) clear_config_json ;;
      3) view_config_formatted ;;
      4) sync_core_services ;;
      5) manage_relay_nodes ;;
      6) export_configs ;;
      7) sync_system_time_chrony ;;
      8) uninstall_singbox_keep_config ;;
      0|q|Q) exit 0 ;;
      *) warn "无效输入：$opt"; sleep 1 ;;
    esac
  done
}

main_menu
