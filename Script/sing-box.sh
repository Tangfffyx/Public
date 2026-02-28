#!/bin/bash
# ====================================================
# Project: Sing-box Elite Management System + Domo Installer
# Version: 1.13.3
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
# - Relay SS is fixed: port 8080 + aes-128-gcm.
# - Export does NOT mask secrets (per your preference).
# ====================================================

set -Eeuo pipefail

CONFIG_FILE="/etc/sing-box/config.json"
TEMP_FILE="/etc/sing-box/config.json.tmp"

# --- Legacy compatibility (<= V-1.10.2) ---
LEGACY_VLESS_TAG="vless-main-in"
LEGACY_VLESS_USER="direct-user"
NEW_VLESS_TAG="vless-reality-in"
NEW_VLESS_USER="vless-reality-user"

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
  local json_data="$1"
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
  # Ensure ONE managed "direct" rule exists for our core users, and keep existing relay-* rules.
  # Also de-duplicate by (outbound + sorted auth_user) signature.
  local conf="$1"

  local users=()

  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-ws-tls-in")' >/dev/null 2>&1; then
    users+=("vless-ws-tls-user")
  fi
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-ws-in")' >/dev/null 2>&1; then
    users+=("vless-ws-user")
  fi
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="tuic-in")' >/dev/null 2>&1; then
    users+=("tuic-user")
  fi
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in")' >/dev/null 2>&1; then
    users+=("vless-reality-user")
  fi

  # If no core users, just keep relay rules and return
  if [ ${#users[@]} -eq 0 ]; then
    echo "$conf" | jq '
      .route.rules = ((.route.rules // []) | map(select(
        (type=="object")
        and ((.auth_user? // []) | length > 0)
        and (((.auth_user?[0] // "") | startswith("relay-")))
      )))
      | .route.rules = ((.route.rules // []) | unique_by((.outbound // "") + "|" + ((.auth_user // []) | sort | join(","))))
    '
    return 0
  fi

  local users_json
  users_json=$(printf '%s\n' "${users[@]}" | jq -R . | jq -s 'sort | unique')

  echo "$conf" | jq --argjson users "$users_json" '
    .route.rules = ((.route.rules // []) | map(select(
      (type=="object")
      and ((.auth_user? // []) | length > 0)
      and (((.auth_user?[0] // "") | startswith("relay-")))
    )))
    | .route.rules = ([{"auth_user": $users, "outbound": "direct"}] + .route.rules)
    | .route.rules = ((.route.rules // []) | unique_by((.outbound // "") + "|" + ((.auth_user // []) | sort | join(","))))
  '
}

remove_relay_rule_safely() {
  local json="$1"
  local relay_user="$2"   # e.g. relay-sg01

  echo "$json" | jq --arg u "$relay_user" '
    .route.rules |= (
      (. // [])
      | map(
          if type != "object" then .
          else
            if (.auth_user? == [$u]) then empty else . end
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
  pause
}

# ====================================================
# 2) Clear config.json (reset)
# ====================================================
clear_config_json() {
  init_manager_env
  clear
  echo -e "${Y}─── 清空/重置配置文件 ───${NC}"

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
  gen_random_high_port() {
    # 5-digit port: 10000-65535
    echo $(( (RANDOM % 55536) + 10000 ))
  }


  while true; do
    clear
    echo -e "${B}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│                 核心模块管理 (Install/Uninstall)    │${NC}"
    echo -e "${B}└──────────────────────────────────────────────────┘${NC}"

    # 中转节点状态展示
    mapfile -t __relay_nodes < <(echo "$conf" | jq -r '(.inbounds[]? | (.users? // []))[]? | select((.name? // "") | startswith("relay-")) | .name' 2>/dev/null | sed 's/relay-//')
    if [ ${#__relay_nodes[@]} -eq 0 ]; then
        echo -e "${Y}当前暂无中转节点。${NC}"
    else
        echo -e "${C}当前已配置中转节点:${NC} ${G}${#__relay_nodes[@]} 个${NC}"
        for __n in "${__relay_nodes[@]}"; do
            echo -e "  - ${G}${__n}${NC}"
        done
    fi

    local has_wstls has_ws has_ss has_tuic has_vless
    has_wstls=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-ws-tls-in")' >/dev/null 2>&1 && echo "true" || echo "false")
    has_ws=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-ws-in")' >/dev/null 2>&1 && echo "true" || echo "false")
    has_ss=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "ss-in")' >/dev/null 2>&1 && echo "true" || echo "false")
    has_tuic=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "tuic-in")' >/dev/null 2>&1 && echo "true" || echo "false")
    has_vless=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-reality-in" or .tag == "vless-main-in")' >/dev/null 2>&1 && echo "true" || echo "false")

    echo -e "${C}当前状态:${NC}"
    echo -e "  [1] vless-ws-tls  : $( [ "$has_wstls" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [2] vless-ws      : $( [ "$has_ws" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [3] shadowsocks   : $( [ "$has_ss" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [4] tuic-v5       : $( [ "$has_tuic" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [5] vless-reality : $( [ "$has_vless" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"

    echo -e "${B}────────────────────────────────────────────────────${NC}"
    echo -e "  ${C}1.${NC} 安装核心模块"
    echo -e "  ${C}2.${NC} 卸载核心模块"
    echo -e "  ${R}0.${NC} 返回主菜单"
    echo -e "${B}────────────────────────────────────────────────────${NC}"
    read -r -p " 请选择操作: " act
    if [[ "${act:-}" == "0" ]]; then
      return 0
    fi

    # helper: parse "1+2+3" -> unique list
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
      echo -e "\n${C}可安装模块（多个用 + 连接，如 1+3+5）:${NC}"
      echo -e "  [1] vless-ws-tls"
      echo -e "  [2] vless-ws"
      echo -e "  [3] shadowsocks"
      echo -e "  [4] tuic-v5"
      echo -e "  [5] vless-reality"
      read -r -p " 请输入要安装的模块编号: " sel
      local choices; choices="$(parse_plus "${sel:-}")"
      [ -z "${choices:-}" ] && { warn "未选择任何模块。"; pause; continue; }

      local updated_json="$conf"

      for c in $choices; do
        case "$c" in
          1)
            if [ "$has_wstls" = "true" ]; then
              echo -e " vless-ws-tls 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " vless-ws-tls 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " 端口 (默认: 8001): " wstls_port_in
            local wstls_port=${wstls_port_in:-"8001"}
            read -r -p " WS Path (默认: /Akaman): " wstls_path_in
            local wstls_path=${wstls_path_in:-"/Akaman"}

            local wstls_uuid; wstls_uuid=$(sing-box generate uuid)
            local in_wstls
            in_wstls=$(jq -n --arg uuid "$wstls_uuid" --arg path "$wstls_path" --argjson port "$wstls_port" '{
              "type":"vless",
              "tag":"vless-ws-tls-in",
              "listen":"127.0.0.1",
              "listen_port":$port,
              "users":[{"name":"vless-ws-tls-user","uuid":$uuid}],
              "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
            }')
            updated_json=$(echo "$updated_json" | jq --argjson x "$in_wstls" '.inbounds += [$x]')
            ;;
          2)
            if [ "$has_ws" = "true" ]; then
              echo -e " vless-ws 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " vless-ws 模块: ${Y}未安装，开始安装...${NC}"
            local def_port; def_port=45678
            read -r -p " 端口 (默认: ${def_port}): " ws_port_in
            local ws_port=${ws_port_in:-"$def_port"}
            read -r -p " WS Path (默认: /Akaman): " ws_path_in
            local ws_path=${ws_path_in:-"/Akaman"}

            local ws_uuid; ws_uuid=$(sing-box generate uuid)
            local in_w
            in_w=$(jq -n --arg uuid "$ws_uuid" --arg path "$ws_path" --argjson port "$ws_port" '{
              "type":"vless",
              "tag":"vless-ws-in",
              "listen":"::",
              "listen_port":$port,
              "users":[{"name":"vless-ws-user","uuid":$uuid}],
              "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
            }')
            updated_json=$(echo "$updated_json" | jq --argjson w "$in_w" '.inbounds += [$w]')
            ;;
          3)
            if [ "$has_ss" = "true" ]; then
              echo -e " shadowsocks 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " shadowsocks 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " Shadowsocks 密码: " ss_p
            [ -z "${ss_p:-}" ] && { warn "未输入密码，跳过 shadowsocks 安装。"; continue; }
            local in_s
            in_s=$(jq -n --arg p "$ss_p" '{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":8080,"method":"aes-128-gcm","password":$p,"multiplex":{"enabled":true}}')
            updated_json=$(echo "$updated_json" | jq --argjson s "$in_s" '.inbounds += [$s]')
            ;;
          4)
            if [ "$has_tuic" = "true" ]; then
              echo -e " tuic-v5 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " tuic-v5 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " TUIC 端口 (默认: 8443): " t_port_in
            local t_port=${t_port_in:-"8443"}
            read -r -p " TUIC 域名 (默认: www.icloud.com): " t_sni_in
            local t_sni=${t_sni_in:-"www.icloud.com"}
            local t_pass; t_pass=$(openssl rand -base64 12)

            openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
              -keyout /etc/sing-box/tuic.key -out /etc/sing-box/tuic.crt \
              -days 36500 -nodes -subj "/CN=$t_sni" &> /dev/null || true

            local base_uuid
            base_uuid=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .users[]? | select(.name=="vless-reality-user" or .name=="direct-user") | .uuid' 2>/dev/null | head -n1)
            [ -z "${base_uuid:-}" ] && base_uuid=$(sing-box generate uuid)

            local in_t
            in_t=$(jq -n --arg uuid "$base_uuid" --arg p "$t_pass" --arg sni "$t_sni" --argjson port "$t_port" '{
              "type":"tuic","tag":"tuic-in","listen":"::","listen_port":$port,
              "users":[{"name":"tuic-user","uuid":$uuid,"password":$p}],
              "congestion_control":"bbr",
              "tls":{"enabled":true,"server_name":$sni,"alpn":["h3"],"certificate_path":"/etc/sing-box/tuic.crt","key_path":"/etc/sing-box/tuic.key"}
            }')
            updated_json=$(echo "$updated_json" | jq --argjson t "$in_t" '.inbounds += [$t]')
            ;;
          5)
            if [ "$has_vless" = "true" ]; then
              echo -e " vless-reality 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " vless-reality 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " 端口 (默认: 443): " v_port_in
            local v_port=${v_port_in:-"443"}
            read -r -p " Private Key: " priv_key
            read -r -p " Short ID: " sid
            read -r -p " 目标域名 (默认: www.icloud.com): " sni
            sni=${sni:-"www.icloud.com"}
            local uuid; uuid=$(sing-box generate uuid)

            local sid_json
            if [ -z "${sid:-}" ]; then sid_json="[]"; else sid_json="[\"$sid\"]"; fi

            local in_v
            in_v=$(jq -n --arg uuid "$uuid" --arg priv "$priv_key" --argjson sid "$sid_json" --arg sni "$sni" --argjson port "$v_port" '{
              "type":"vless",
              "tag":"vless-reality-in",
              "listen":"::",
              "listen_port":$port,
              "users":[{"name":"vless-reality-user","uuid":$uuid,"flow":"xtls-rprx-vision"}],
              "tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":$sid}}
            }')
            updated_json=$(echo "$updated_json" | jq --argjson v "$in_v" '.inbounds += [$v]')
            ;;
          *)
            warn "未知选项：$c"
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
      local installed_names=()
      local installed_ids=()

      if [ "$has_wstls" = "true" ]; then installed_ids+=("1"); installed_names+=("vless-ws-tls"); fi
      if [ "$has_ws" = "true" ]; then installed_ids+=("2"); installed_names+=("vless-ws"); fi
      if [ "$has_ss" = "true" ]; then installed_ids+=("3"); installed_names+=("shadowsocks"); fi
      if [ "$has_tuic" = "true" ]; then installed_ids+=("4"); installed_names+=("tuic-v5"); fi
      if [ "$has_vless" = "true" ]; then installed_ids+=("5"); installed_names+=("vless-reality"); fi

      if [ ${#installed_ids[@]} -eq 0 ]; then
        warn "暂无已安装的核心模块。"
        pause
        continue
      fi

      echo -e "\n${R}已安装模块如下（多个用 + 连接，如 1+3）:${NC}"
      for i in "${!installed_ids[@]}"; do
        echo -e "  [${installed_ids[$i]}] ${installed_names[$i]}"
      done
      read -r -p " 请输入要卸载的模块编号: " sel
      local choices; choices="$(parse_plus "${sel:-}")"
      [ -z "${choices:-}" ] && { warn "未选择任何模块。"; pause; continue; }

      local updated_json="$conf"
      for c in $choices; do
        case "$c" in
          1)
            [ "$has_wstls" = "true" ] && { say "卸载 vless-ws-tls..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select(.tag != "vless-ws-tls-in"))'); }
            ;;
          2)
            [ "$has_ws" = "true" ] && { say "卸载 vless-ws..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select(.tag != "vless-ws-in"))'); }
            ;;
          3)
            [ "$has_ss" = "true" ] && { say "卸载 shadowsocks..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select(.tag != "ss-in"))'); }
            ;;
          4)
            [ "$has_tuic" = "true" ] && { say "卸载 tuic-v5..."; updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select(.tag != "tuic-in"))'); }
            ;;
          5)
            if [ "$has_vless" = "true" ]; then
              say "卸载 vless-reality..."
              updated_json=$(echo "$updated_json" | jq '
                .inbounds |= map(select(.tag != "vless-reality-in" and .tag != "vless-main-in"))
                | .outbounds |= map(select((.tag // "") | startswith("out-to-") | not))
                | .route.rules |= ((. // []) | map(select(
                    (type!="object") or
                    ((.auth_user? // []) | length == 0) or
                    (((.auth_user?[0] // "") | startswith("relay-")) | not)
                  )))
              ')
            fi
            ;;
          *)
            warn "未知选项：$c"
            ;;
        esac
      done

      updated_json=$(sync_managed_route_rules "$updated_json")
      atomic_save "$updated_json" || true
      conf=$(cat "$CONFIG_FILE")
      pause
      continue
    fi

    warn "无效输入：$act"
    sleep 1
  done
}

# ====================================================
# 5) Relay nodes manager (install/uninstall)
# ====================================================
manage_relay_nodes() {
  init_manager_env
  local conf; conf=$(cat "$CONFIG_FILE")

  while true; do
    conf=$(cat "$CONFIG_FILE")
    clear
    echo -e "${B}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│                 中转节点管理 (Install/Uninstall)    │${NC}"
    echo -e "${B}└──────────────────────────────────────────────────┘${NC}"
    # 中转节点状态展示
    mapfile -t __relay_nodes < <(echo "$conf" | jq -r '(.inbounds[]? | (.users? // []))[]? | select((.name? // "") | startswith("relay-")) | .name' 2>/dev/null | sed 's/relay-//')
    if [ ${#__relay_nodes[@]} -eq 0 ]; then
      echo -e "${Y}当前暂无中转节点。${NC}"
    else
      echo -e "${C}当前已配置中转节点:${NC} ${G}${#__relay_nodes[@]} 个${NC}"
      for __n in "${__relay_nodes[@]}"; do
        echo -e "  - ${G}${__n}${NC}"
      done
    fi
    echo -e "  ${C}1.${NC} 安装/覆盖中转节点"
    echo -e "  ${C}2.${NC} 卸载中转节点"
    echo -e "  ${R}0.${NC} 返回主菜单"
    echo -e "${B}────────────────────────────────────────────────────${NC}"
    read -r -p " 请选择操作: " act
    if [[ "${act:-}" == "0" ]]; then
      return 0
    fi

    # helper
    parse_plus() {
      local s="$1"
      local -A seen=()
      local out=()
      IFS='+' read -r -a parts <<< "$s"
      for p in "${parts[@]}"; do
        p="${p// /}"
        [[ -z "$p" ]] && continue
        if [[ "$p" =~ ^[0-9]+$ ]]; then
          if [ -z "${seen[$p]+x}" ]; then
            seen[$p]=1
            out+=("$p")
          fi
        fi
      done
      echo "${out[@]}"
    }

    if [[ "${act:-}" == "1" ]]; then
      # reuse existing add logic (single add per run)
      add_relay_node
      conf=$(cat "$CONFIG_FILE")
      continue
    fi

    if [[ "${act:-}" == "2" ]]; then
      conf=$(cat "$CONFIG_FILE")
      mapfile -t nodes < <(echo "$conf" | jq -r '
        (.inbounds[]? | (.users? // []))[]?
        | select((.name? // "") | startswith("relay-"))
        | .name
      ' 2>/dev/null | sed 's/relay-//')

      if [ ${#nodes[@]} -eq 0 ]; then
        warn "暂无已配置的中转节点。"
        pause
        continue
      fi

      echo -e "\n${R}已配置的中转节点如下（多个用 + 连接，如 1+2）:${NC}"
      for i in "${!nodes[@]}"; do
        echo -e " [$(($i+1))] ${nodes[$i]}"
      done

      read -r -p " 请输入要卸载的编号: " sel
      local choices; choices="$(parse_plus "${sel:-}")"
      [ -z "${choices:-}" ] && { warn "未选择任何节点。"; pause; continue; }

      local updated_json="$conf"

      for c in $choices; do
        if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#nodes[@]}" ]; then
          local target="${nodes[$(($c-1))]}"
          local relay_user="relay-$target"
          local out="out-to-$target"

          updated_json=$(echo "$updated_json" | jq --arg u "$relay_user" --arg o "$out" '
            .inbounds |= map(
              if (.users? != null) then
                .users |= (map(select((.name? // "") != $u)))
              else
                .
              end
            )
            | .outbounds |= map(select(.tag != $o))
          ')
          updated_json=$(remove_relay_rule_safely "$updated_json" "$relay_user")
        else
          warn "忽略无效编号：$c"
        fi
      done

      updated_json=$(sync_managed_route_rules "$updated_json")
      atomic_save "$updated_json" || true
      pause
      conf=$(cat "$CONFIG_FILE")
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
  # 选择中转主入站协议（默认：vless-reality）
  local has_wstls="false"
  local has_reality="false"
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-ws-tls-in")' >/dev/null 2>&1; then
    has_wstls="true"
  fi
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-reality-in" or .tag == "vless-main-in")' >/dev/null 2>&1; then
    has_reality="true"
  fi

  echo -e "\n${C}─── 添加/覆盖中转节点 ───${NC}"
  echo -e " 主入站协议："
  echo -e "  ${C}1.${NC} vless-reality（默认）"
  echo -e "  ${C}2.${NC} vless-ws-tls"
  read -r -p " 请选择 (1/2，默认 1): " in_choice
  in_choice=${in_choice:-"1"}

  local relay_in_tag=""
  case "$in_choice" in
    1)
      if [ "$has_reality" != "true" ]; then
        err "未检测到 vless-reality 入站（vless-reality-in / vless-main-in）。请先在选项4安装 vless-reality。"
        pause
        return 1
      fi
      if echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-reality-in")' >/dev/null 2>&1; then
        relay_in_tag="vless-reality-in"
      else
        relay_in_tag="vless-main-in"
      fi
      ;;
    2)
      if [ "$has_wstls" != "true" ]; then
        err "未检测到 vless-ws-tls 入站（vless-ws-tls-in）。请先在选项4安装 vless-ws-tls。"
        pause
        return 1
      fi
      relay_in_tag="vless-ws-tls-in"
      ;;
    *)
      warn "无效选择，已默认使用 vless-reality。"
      if [ "$has_reality" != "true" ]; then
        err "未检测到 vless-reality 入站（vless-reality-in / vless-main-in）。请先在选项4安装 vless-reality。"
        pause
        return 1
      fi
      if echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-reality-in")' >/dev/null 2>&1; then
        relay_in_tag="vless-reality-in"
      else
        relay_in_tag="vless-main-in"
      fi
      ;;
  esac

  echo -e "
${C}─── 添加/覆盖中转节点 ───${NC}"
  read -r -p " 落地标识 (如 sg01): " n; [ -z "$n" ] && return
  read -r -p " 落地 IP 地址: " ip; [ -z "$ip" ] && return
  read -r -p " 落地 SS 密码: " p; [ -z "$p" ] && return

  local user="relay-$n"
  local out="out-to-$n"
  local uuid; uuid=$(sing-box generate uuid)


  # 若同名中转已存在，将从旧主入站迁移到本次选择的主入站
  local old_tags=""
  old_tags=$(echo "$conf" | jq -r --arg user "$user" '.inbounds[]? | select((.users? // []) | any(.name == $user)) | .tag' 2>/dev/null | tr '
' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')
  if [ -n "$old_tags" ] && ! echo " $old_tags " | grep -q " $relay_in_tag "; then
    warn "检测到 ${user} 已存在于 [$old_tags]，将迁移到 [$relay_in_tag]。"
  fi

  local new_u new_o
  if [ "$relay_in_tag" = "vless-reality-in" ] || [ "$relay_in_tag" = "vless-main-in" ]; then
    new_u=$(jq -n --arg name "$user" --arg uuid "$uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')
  else
    new_u=$(jq -n --arg name "$user" --arg uuid "$uuid" '{"name":$name,"uuid":$uuid}')
  fi
  new_o=$(jq -n --arg tag "$out" --arg addr "$ip" --arg key "$p" '{"type":"shadowsocks","tag":$tag,"server":$addr,"server_port":8080,"method":"aes-128-gcm","password":$key,"multiplex":{"enabled":true}}')

  # Remove same relay user from both new/legacy relay inbounds (avoid duplicates)
  conf=$(echo "$conf" | jq --arg user "$user" '
    (.inbounds[]? | select(.tag=="vless-ws-tls-in").users) |= (map(select(.name != $user)))
    | (.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in").users) |= (map(select(.name != $user)))
  ')

  # Remove outbound (overwrite)
  conf=$(echo "$conf" | jq --arg out "$out" '.outbounds |= map(select(.tag != $out))')

  # Remove existing relay route rule(s)
  local updated_json
  updated_json=$(remove_relay_rule_safely "$conf" "$user")

  # Add user into preferred inbound (ws-tls if exists, else legacy)
  updated_json=$(echo "$updated_json" | jq --argjson u "$new_u" --arg relayTag "$relay_in_tag" '
    (.inbounds[] | select(.tag == $relayTag).users) += [$u]
  ')

  # Add outbound
  updated_json=$(echo "$updated_json" | jq --argjson o "$new_o" '.outbounds += [$o]')

  # Add relay rule on TOP (will be deduped later)
  local new_r
  new_r=$(jq -n --arg user "$user" --arg out "$out" '{"auth_user":[$user],"outbound":$out}')
  updated_json=$(echo "$updated_json" | jq --argjson r "$new_r" '.route.rules = [$r] + (.route.rules // [])')

  updated_json=$(sync_managed_route_rules "$updated_json")
  atomic_save "$updated_json"
}

# ====================================================
# 6) Delete relay node
# ====================================================
del_relay_node() {
  init_manager_env
  local conf; conf=$(cat "$CONFIG_FILE")

  # Robust: find relay-* users from ANY inbound that has users[]
  mapfile -t nodes < <(echo "$conf" | jq -r '
    (.inbounds[]? | (.users? // []))[]?
    | select((.name? // "") | startswith("relay-"))
    | .name
  ' 2>/dev/null | sed 's/relay-//')

  if [ ${#nodes[@]} -eq 0 ]; then
    warn "暂无已配置的中转节点。"
    pause
    return
  fi

  echo -e "\n${R}─── 删除中转节点 ───${NC}"
  for i in "${!nodes[@]}"; do
    echo -e " [$(($i+1))] ${nodes[$i]}"
  done
  read -r -p " 请输入要删除的编号: " choice

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#nodes[@]}" ]; then
    local target="${nodes[$(($choice-1))]}"
    local relay_user="relay-$target"
    local out="out-to-$target"

    local updated_json
    updated_json=$(echo "$conf" | jq --arg u "$relay_user" --arg o "$out" '
      # remove relay user from ANY inbound users array
      (.inbounds[]? | select(.users? != null).users) |= (map(select((.name? // "") != $u)))
      | .outbounds |= map(select((.tag // "") != $o))
    ')

    updated_json=$(remove_relay_rule_safely "$updated_json" "$relay_user")
    updated_json=$(sync_managed_route_rules "$updated_json")
    atomic_save "$updated_json"
  fi

  pause
}

# ====================================================
# 7) Export client configs
# ====================================================
export_configs() {
  init_manager_env
  clear
  local conf; conf=$(cat "$CONFIG_FILE")
  local ip; ip=$(get_public_ip)
  local host; host=$(hostname)

  echo -e "\n${C}─── 节点配置导出 ───${NC}"
  # 按需提示：仅当模块存在时才要求输入；不输入则使用占位符
  local v_pbk="PUBLIC_KEY_MISSING"
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in")' >/dev/null 2>&1; then
    read -r -p " 请输入 Reality Public Key (默认: PUBLIC_KEY_MISSING): " v_pbk_in
    v_pbk=${v_pbk_in:-"PUBLIC_KEY_MISSING"}
  fi

  local wstls_domain="example.com"
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-ws-tls-in")' >/dev/null 2>&1; then
    read -r -p " 请输入 vless-ws-tls 域名 (SNI/Host，默认: example.com): " wstls_domain_in
    wstls_domain=${wstls_domain_in:-"example.com"}
  fi
  local wstls_port=443

  # 1) vless-ws-tls direct
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-ws-tls-in")' >/dev/null 2>&1; then
    local wstls_uuid wstls_path
    wstls_uuid=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .users[]? | select(.name=="vless-ws-tls-user") | .uuid' | head -n1)
    wstls_path=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .transport.path // "/Akaman"' | head -n1)

    echo -e "\n${W}[VLESS-WS-TLS 直连]${NC}"
    echo -e " Clash: - {name: ${host}-vless-wss, type: vless, server: $ip, port: ${wstls_port}, uuid: ${wstls_uuid}, udp: true, tls: true, network: ws, servername: ${wstls_domain}, ws-opts: {path: \"${wstls_path}\", headers: {Host: ${wstls_domain}}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}"
    echo ""
    echo -e " Quantumult X: vless=$ip:${wstls_port},method=none,password=${wstls_uuid},obfs=wss,obfs-host=${wstls_domain},obfs-uri=${wstls_path}?ed=2048,fast-open=false,udp-relay=true,tag=${host}-vless-wss"
  fi

  # 2) vless-ws direct (Clash only)
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-ws-in")' >/dev/null 2>&1; then
    local ws_uuid ws_path
    ws_uuid=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-ws-in") | .users[]? | select(.name=="vless-ws-user") | .uuid' | head -n1)
    ws_path=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-ws-in") | .transport.path // "/Akaman"' | head -n1)
    local ws_port
    ws_port=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-ws-in") | .listen_port' | head -n1)

    echo -e "\n${W}[VLESS-WS 直连]${NC}"
    echo -e " Clash: - {name: ${host}-vless-ws, type: vless, server: $ip, port: ${ws_port}, uuid: ${ws_uuid}, udp: true, tls: false, network: ws, ws-opts: {path: \"${ws_path}?ed=2048\"}}"
    echo ""
    echo -e " Quantumult X: vless=$ip:443,method=none,password=${ws_uuid},obfs=wss,obfs-host=example.com,obfs-uri=${ws_path}?ed=2048,fast-open=false,udp-relay=true,tag=${host}-vless-wss"
  fi

  # 3) TUIC direct
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="tuic-in")' >/dev/null 2>&1; then
    local t_u t_p t_s
    t_u=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].uuid')
    t_p=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].password')
    t_s=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .tls.server_name // "www.icloud.com"')
    local t_port
    t_port=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .listen_port' | head -n1)

    echo -e "\n${W}[TUIC V5 直连]${NC}"
    echo -e " Clash: - {name: ${host}-tuic, type: tuic, server: $ip, port: $t_port, uuid: $t_u, password: $t_p, alpn: [h3], disable-sni: false, reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true, sni: $t_s}"
  fi

  # 4) VLESS Reality direct
  local v_sni v_sid main_uuid
  v_sni=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .tls.server_name // "www.icloud.com"' | head -n1)
  v_sid=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .tls.reality.short_id[0] // ""' | head -n1)
  main_uuid=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .users[]? | select(.name=="vless-reality-user" or .name=="direct-user") | .uuid // empty' | head -n1)

  local v_port
  v_port=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .listen_port' | head -n1)

  if [ -n "${main_uuid:-}" ]; then
    echo -e "\n${W}[VLESS Reality 直连]${NC}"
    echo -e " Clash: - {name: ${host}-reality, type: vless, server: $ip, port: $v_port, uuid: $main_uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $v_pbk, short-id: '$v_sid'}, client-fingerprint: chrome}"
    echo ""
    echo -e " Quantumult X: vless=$ip:$v_port, method=none, password=$main_uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=${host}-reality"
  fi

  # Relays: robustly discover relay-* users from ANY inbound users[]
  if echo "$conf" | jq -e '(.inbounds[]? | (.users? // []))[]? | select((.name? // "") | startswith("relay-"))' >/dev/null 2>&1; then
    local wstls_path="/Akaman"
    if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-ws-tls-in")' >/dev/null 2>&1; then
      wstls_path=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-ws-tls-in") | .transport.path // "/Akaman"' | head -n1)
    fi

    echo "$conf" | jq -c '(.inbounds[]? | (.users? // []))[]? | select((.name? // "") | startswith("relay-"))' | while read -r u; do
      local r_full r_name r_uuid
      r_full=$(echo "$u" | jq -r '.name')
      r_name=$(echo "$r_full" | sed 's/relay-//')
      r_uuid=$(echo "$u" | jq -r '.uuid')

      # 判断该落地用户当前挂载在哪个主入站（用于导出对应协议）
      local in_reality="false"
      if echo "$conf" | jq -e --arg user "$r_full" '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | (.users? // [])[]? | select(.name==$user)' >/dev/null 2>&1; then
        in_reality="true"
      fi

      echo -e "
${W}[落地 ${r_name}]${NC}"

      if [ "$in_reality" = "true" ]; then
        echo -e " Clash: - {name: ${host}-to-${r_name}, type: vless, server: $ip, port: ${v_port}, uuid: $r_uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $v_pbk, short-id: '$v_sid'}, client-fingerprint: chrome}"
    echo ""
      echo -e " Quantumult X: vless=$ip:${v_port}, method=none, password=$r_uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=${host}-to-${r_name}"
      else
        echo -e " Clash: - {name: ${host}-to-${r_name}, type: vless, server: $ip, port: ${wstls_port}, uuid: $r_uuid, udp: true, tls: true, network: ws, servername: ${wstls_domain}, ws-opts: {path: \"${wstls_path}\", headers: {Host: ${wstls_domain}}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}"
        echo ""
        echo -e " Quantumult X: vless=${wstls_domain}:${wstls_port}, method=none, password=$r_uuid, obfs=wss, obfs-uri=${wstls_path}?ed=2048, fast-open=false, udp-relay=true, tag=${host}-to-${r_name}"
      fi
    done
  fi

  echo ""
  read -n 1 -p "按任意键返回主菜单..."
}

# ====================================================
# 8) Uninstall sing-box (keep /etc/sing-box/)
# ====================================================
uninstall_singbox_keep_config() {
  require_root
  clear
  echo -e "${R}─── 卸载 sing-box（保留 /etc/sing-box/ 配置）───${NC}"

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
  while true; do
    clear
    echo -e "${B}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│     Sing-box Elite 管理系统 + Installer V-1.13.3 │${NC}"
    echo -e "${B}└──────────────────────────────────────────────────┘${NC}"
    echo -e "  ${C}1.${NC} 安装/更新 sing-box（APT 源，依赖检测+版本对比）"
    echo -e "  ${C}2.${NC} 清空/重置 config.json（最小模板）"
    echo -e "  ${C}3.${NC} 查看配置文件（sing-box format）"
    echo -e "  ${C}4.${NC} 核心模块管理 (安装/卸载：vless-reality/ss/tuic/vless-ws)"
    echo -e "  ${C}5.${NC} 中转节点管理 (安装/卸载)"
    echo -e "  ${C}6.${NC} 导出客户端配置 (Clash/Quantumult X)"
    echo -e "  ${C}7.${NC} 卸载 sing-box（保留 /etc/sing-box/ 配置）"
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
      7) uninstall_singbox_keep_config ;;
      0|q|Q) exit 0 ;;
      *) warn "无效输入：$opt"; sleep 1 ;;
    esac
  done
}

main_menu
