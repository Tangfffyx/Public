#!/bin/bash
# ====================================================
# Project: Sing-box Elite Management System + Domo Installer
# Version: 1.11.1
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
  local json="$1"

  echo "$json" | jq '
    . as $cfg
    | def relay_users($c):
        [ $c.inbounds[]?
          | select(.tag=="vless-reality-in" or .tag=="vless-main-in")
          | .users[]?
          | select(.name | startswith("relay-"))
          | .name
        ];

      def desired_rules($rels):
        (
          [ {"auth_user":["vless-reality-user","tuic-user","vless-ws-user"],"outbound":"direct"} ]
          +
          [ $rels[] | {"auth_user":[.],"outbound":("out-to-" + (sub("^relay-";"")))} ]
        );

      (relay_users($cfg)) as $rels
      | (
          (
            desired_rules($rels)
            +
            (
              ($cfg.route.rules // [])
              | map(
                  if type != "object" then
                    .
                  else
                    if (.auth_user? == ["vless-reality-user","tuic-user","vless-ws-user"]) then
                      empty
                    elif ( ((.auth_user?[0] // "") | startswith("relay-"))
                           and ( ($rels | index((.auth_user?[0] // ""))) != null )
                           and ((.auth_user? | length) == 1) ) then
                      empty
                    else
                      .
                    end
                  end
                )
              | map(select(. != null))
            )
          ) as $all
          | (
              ([ $all[] | select(type=="object") ] | unique_by({auth_user, outbound}))
              + [ $all[] | select(type!="object") ]
            )
        ) as $final_rules
      | .route.rules = $final_rules
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
  maybe_migrate_legacy
  local conf; conf=$(cat "$CONFIG_FILE")

  while true; do
    clear
    echo -e "${B}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│              核心模块管理 (Install/Uninstall)     │${NC}"
    echo -e "${B}└──────────────────────────────────────────────────┘${NC}"

    local has_vless has_ss has_tuic has_ws
    has_vless=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-reality-in" or .tag == "vless-main-in")' >/dev/null 2>&1 && echo "true" || echo "false")
    has_ss=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "ss-in")' >/dev/null 2>&1 && echo "true" || echo "false")
    has_tuic=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "tuic-in")' >/dev/null 2>&1 && echo "true" || echo "false")
    has_ws=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-ws-in")' >/dev/null 2>&1 && echo "true" || echo "false")

    echo -e "${C}当前状态:${NC}"
    echo -e "  [1] vless-reality : $( [ "$has_vless" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [2] shadowsocks   : $( [ "$has_ss" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [3] tuic-v5       : $( [ "$has_tuic" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "  [4] vless-ws      : $( [ "$has_ws" = "true" ] && echo -e "${G}已安装${NC}" || echo -e "${Y}未安装${NC}" )"
    echo -e "${B}────────────────────────────────────────────────────${NC}"
    echo -e "  ${C}1.${NC} 安装模块"
    echo -e "  ${C}2.${NC} 卸载模块"
    echo -e "  ${R}0.${NC} 返回主菜单"
    echo -e "${B}────────────────────────────────────────────────────${NC}"
    read -r -p " 请选择操作: " act

    if [[ "${act:-}" == "0" ]]; then
      return 0
    fi

    # helper: parse "1+2+4" into unique list
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
      echo -e "\n${C}可选模块（多个用 + 连接，如 1+2+3+4）:${NC}"
      echo -e "  1) vless-reality"
      echo -e "  2) shadowsocks"
      echo -e "  3) tuic-v5"
      echo -e "  4) vless-ws"
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
            read -r -p " Private Key: " priv_key
            read -r -p " Short ID: " sid
            read -r -p " 目标域名 (默认: www.icloud.com): " sni; sni=${sni:-"www.icloud.com"}
            local uuid; uuid=$(sing-box generate uuid)

            local sid_json
            if [ -z "${sid:-}" ]; then
              sid_json="[]"
            else
              sid_json="[\"$sid\"]"
            fi

            local in_v
            in_v=$(jq -n --arg uuid "$uuid" --arg priv "$priv_key" --argjson sid "$sid_json" --arg sni "$sni" \
              '{
                "type":"vless",
                "tag":"vless-reality-in",
                "listen":"::",
                "listen_port":443,
                "users":[{"name":"vless-reality-user","uuid":$uuid,"flow":"xtls-rprx-vision"}],
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
            updated_json=$(echo "$updated_json" | jq --argjson v "$in_v" '.inbounds += [$v]')
            ;;
          2)
            if [ "$has_ss" = "true" ]; then
              echo -e " shadowsocks 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " shadowsocks 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " Shadowsocks 密码: " ss_p
            if [ -n "${ss_p:-}" ]; then
              local in_s
              in_s=$(jq -n --arg p "$ss_p" '{
                "type":"shadowsocks",
                "tag":"ss-in",
                "listen":"::",
                "listen_port":8080,
                "method":"aes-128-gcm",
                "password":$p
              }')
              updated_json=$(echo "$updated_json" | jq --argjson s "$in_s" '.inbounds += [$s]')
            else
              warn "密码为空，已跳过 shadowsocks 安装。"
            fi
            ;;
          3)
            if [ "$has_tuic" = "true" ]; then
              echo -e " tuic-v5 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " tuic-v5 模块: ${Y}未安装，开始安装...${NC}"
            read -r -p " TUIC 域名 (默认: www.icloud.com): " t_sni_in
            local t_sni=${t_sni_in:-"www.icloud.com"}
            local t_pass t_uuid
            t_pass=$(openssl rand -base64 12)
            t_uuid=$(sing-box generate uuid)

            openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
              -keyout /etc/sing-box/tuic.key -out /etc/sing-box/tuic.crt \
              -days 36500 -nodes -subj "/CN=$t_sni" &> /dev/null

            local in_t
            in_t=$(jq -n --arg uuid "$t_uuid" --arg p "$t_pass" --arg sni "$t_sni" '{
              "type":"tuic",
              "tag":"tuic-in",
              "listen":"::",
              "listen_port":443,
              "users":[{"name":"tuic-user","uuid":$uuid,"password":$p}],
              "congestion_control":"bbr",
              "tls":{
                "enabled":true,
                "server_name":$sni,
                "alpn":["h3"],
                "certificate_path":"/etc/sing-box/tuic.crt",
                "key_path":"/etc/sing-box/tuic.key"
              }
            }')
            updated_json=$(echo "$updated_json" | jq --argjson t "$in_t" '.inbounds += [$t]')
            ;;
          4)
            if [ "$has_ws" = "true" ]; then
              echo -e " vless-ws 模块: ${G}已安装${NC}"
              continue
            fi
            echo -e " vless-ws 模块: ${Y}未安装，开始安装...${NC}"
            local ws_port=80
            read -r -p " WS Path (默认: /Akaman): " ws_path_in
            local ws_path=${ws_path_in:-"/Akaman"}

            local ws_uuid
            ws_uuid=$(sing-box generate uuid)

            local in_w
            in_w=$(jq -n --arg uuid "$ws_uuid" --arg path "$ws_path" --argjson port "$ws_port" '{
              "type":"vless",
              "tag":"vless-ws-in",
              "listen":"::",
              "listen_port":$port,
              "users":[{"name":"vless-ws-user","uuid":$uuid}],
              "transport":{
                "type":"ws",
                "path":$path,
                "max_early_data":2048,
                "early_data_header_name":"Sec-WebSocket-Protocol"
              }
            }')
            updated_json=$(echo "$updated_json" | jq --argjson w "$in_w" '.inbounds += [$w]')
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
      # build installed list
      local installed_names=()
      local installed_ids=()

      if [ "$has_vless" = "true" ]; then installed_ids+=("1"); installed_names+=("vless-reality"); fi
      if [ "$has_ss" = "true" ]; then installed_ids+=("2"); installed_names+=("shadowsocks"); fi
      if [ "$has_tuic" = "true" ]; then installed_ids+=("3"); installed_names+=("tuic-v5"); fi
      if [ "$has_ws" = "true" ]; then installed_ids+=("4"); installed_names+=("vless-ws"); fi

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
            if [ "$has_vless" = "true" ]; then
              say "卸载 vless-reality..."
              updated_json=$(echo "$updated_json" | jq '
                .inbounds |= map(select(.tag != "vless-reality-in"))
                | .outbounds |= map(select((.tag // "") | startswith("out-to-") | not))
                | .route.rules |= ((. // []) | map(select(
                    (type!="object") or
                    ((.auth_user? // []) | length == 0) or
                    (((.auth_user?[0] // "") | startswith("relay-")) | not)
                  )))
              ')
            fi
            ;;
          2)
            if [ "$has_ss" = "true" ]; then
              say "卸载 shadowsocks..."
              updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select(.tag != "ss-in"))')
            fi
            ;;
          3)
            if [ "$has_tuic" = "true" ]; then
              say "卸载 tuic-v5..."
              updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select(.tag != "tuic-in"))')
            fi
            ;;
          4)
            if [ "$has_ws" = "true" ]; then
              say "卸载 vless-ws..."
              updated_json=$(echo "$updated_json" | jq '.inbounds |= map(select(.tag != "vless-ws-in"))')
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
    pause
  done
}

# ====================================================
# 5) Relay nodes manager (install/uninstall)
# ====================================================
manage_relay_nodes() {
  init_manager_env
  local conf; conf=$(cat "$CONFIG_FILE")

  while true; do
    clear
    echo -e "${B}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│                 中转节点管理 (Install/Uninstall)    │${NC}"
    echo -e "${B}└──────────────────────────────────────────────────┘${NC}"
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
        .inbounds[]? | select(.tag == "vless-reality-in" or .tag == "vless-main-in")
        | .users[]? | select(.name | startswith("relay-")) | .name
      ' | sed 's/relay-//')

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
            (.inbounds[] | select(.tag == "vless-reality-in" or .tag == "vless-main-in").users) |= map(select(.name != $u))
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

  if ! echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-reality-in" or .tag == "vless-main-in")' >/dev/null 2>&1; then
    err "未检测到 vless-reality 模块（vless-reality-in）。请先在选项4安装 vless-reality，再添加中转节点。"
    pause
    return 1
  fi

  echo -e "
${C}─── 添加/覆盖中转节点 ───${NC}"
  read -p " 落地标识 (如 sg01): " n; [ -z "${n:-}" ] && return
  read -p " 落地 IP 地址: " ip; [ -z "${ip:-}" ] && return
  read -p " 落地 SS 密码: " p; [ -z "${p:-}" ] && return

  local user="relay-$n"
  local out="out-to-$n"
  local uuid; uuid=$(sing-box generate uuid)

  local new_u new_o
  new_u=$(jq -n --arg name "$user" --arg uuid "$uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')
  new_o=$(jq -n --arg tag "$out" --arg addr "$ip" --arg key "$p" '{
    "type":"shadowsocks",
    "tag":$tag,
    "server":$addr,
    "server_port":8080,
    "method":"aes-128-gcm",
    "password":$key
  }')

  conf=$(echo "$conf" | jq --arg user "$user" '(.inbounds[] | select(.tag == "vless-reality-in" or .tag == "vless-main-in").users) |= map(select(.name != $user))')
  conf=$(echo "$conf" | jq --arg out "$out" '.outbounds |= map(select(.tag != $out))')

  local updated_json
  updated_json=$(echo "$conf" | jq --argjson u "$new_u" --argjson o "$new_o" '
    (.inbounds[] | select(.tag == "vless-reality-in" or .tag == "vless-main-in").users) += [$u]
    | .outbounds += [$o]
  ')

  updated_json=$(sync_managed_route_rules "$updated_json")
  atomic_save "$updated_json"
  pause
}

# ====================================================
# 6) Delete relay node
# ====================================================
del_relay_node() {
  init_manager_env
  local conf; conf=$(cat "$CONFIG_FILE")

  mapfile -t nodes < <(echo "$conf" | jq -r '
    .inbounds[]? | select(.tag == "vless-reality-in" or .tag == "vless-main-in")
    | .users[]? | select(.name | startswith("relay-")) | .name
  ' | sed 's/relay-//')

  if [ ${#nodes[@]} -eq 0 ]; then
    warn "暂无已配置的中转节点。"
    pause
    return
  fi

  echo -e "\n${R}─── 删除中转节点 ───${NC}"
  for i in "${!nodes[@]}"; do
    echo -e " [$(($i+1))] ${nodes[$i]}"
  done

  read -p " 请输入要删除的编号: " choice
  if [[ "${choice:-}" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#nodes[@]}" ]; then
    local target="${nodes[$(($choice-1))]}"
    local relay_user="relay-$target"
    local out="out-to-$target"

    local updated_json
    updated_json=$(echo "$conf" | jq --arg u "$relay_user" --arg o "$out" '
      (.inbounds[] | select(.tag == "vless-reality-in" or .tag == "vless-main-in").users) |= map(select(.name != $u))
      | .outbounds |= map(select(.tag != $o))
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

  # 需要 Reality Public Key 的场景：存在 Reality 直连或存在 relay 节点
  local need_pbk="false"
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in")' >/dev/null 2>&1; then
    need_pbk="true"
  fi
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .users[]? | select(.name | startswith("relay-"))' >/dev/null 2>&1; then
    need_pbk="true"
  fi

  local v_pbk="KEY_MISSING"
  if [ "$need_pbk" = "true" ]; then
    read -p " 请输入 Reality Public Key: " v_pbk
    v_pbk=${v_pbk:-"KEY_MISSING"}
  fi

  # VLESS Reality 公共参数
  local v_sni v_sid
  v_sni=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .tls.server_name // "www.icloud.com"')
  v_sid=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .tls.reality.short_id[0] // ""')

  local idx=1

  # 1) VLESS Reality 直连（vless-reality-user）
  local main_uuid
  main_uuid=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in") | .users[]? | select(.name=="vless-reality-user" or .name=="direct-user") | .uuid // empty')
  if [ -n "$main_uuid" ]; then
    echo -e "\n${W}[$idx] VLESS Reality 直连${NC}"
    echo -e " Clash:        - {name: ${host}-Reality, type: vless, server: $ip, port: 443, uuid: $main_uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $v_pbk, short-id: '$v_sid'}, client-fingerprint: chrome}"
    echo ""
    echo -e " Quantumult X: vless=$ip:443, method=none, password=$main_uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=${host}-Reality-Direct"
    idx=$((idx+1))
  fi

  # 2) TUIC V5 直连（tuic-user）
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="tuic-in")' >/dev/null 2>&1; then
    local t_u t_p t_s
    t_u=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].uuid')
    t_p=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].password')
    t_s=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .tls.server_name // "www.icloud.com"')

    echo -e "\n${W}[$idx] TUIC V5 直连${NC}"
    echo -e " Clash:        - {name: ${host}-tuic, type: tuic, server: $ip, port: 443, uuid: $t_u, password: $t_p, alpn: [h3], disable-sni: true, reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true, sni: $t_s}"
    idx=$((idx+1))
  fi

  # 3) VLESS-WS（仅 Clash）
  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-ws-in")' >/dev/null 2>&1; then
    local w_uuid w_port w_path
    w_uuid=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-ws-in") | .users[]? | select(.name=="vless-ws-user") | .uuid // empty')
    w_port=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-ws-in") | .listen_port // 80')
    w_path=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-ws-in") | .transport.path // "/Akaman"')
    # 按你的要求：路径后面默认加 ?ed=2048
    local w_path_ed="${w_path}?ed=2048"

    if [ -n "$w_uuid" ]; then
      echo -e "\n${W}[$idx] VLESS-WS 直连${NC}"
      echo -e " Clash:        - {name: ${host}-vless-ws, type: vless, server: $ip, port: $w_port, uuid: $w_uuid, udp: true, tls: false, network: ws, ws-opts: {path: \"$w_path_ed\"}}"
      idx=$((idx+1))
    fi
  fi

  # 4+) 落地节点（relay-*）
  mapfile -t relay_users < <(echo "$conf" | jq -r '
    .inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in")
    | .users[]? | select(.name | startswith("relay-")) | .name
  ')

  if [ ${#relay_users[@]} -gt 0 ]; then
    for ru in "${relay_users[@]}"; do
      local r_name r_uuid
      r_name="${ru#relay-}"
      r_uuid=$(echo "$conf" | jq -r --arg ru "$ru" '
        .inbounds[]? | select(.tag=="vless-reality-in" or .tag=="vless-main-in")
        | .users[]? | select(.name==$ru) | .uuid
      ')

      if [ -n "$r_uuid" ]; then
        echo -e "\n${W}[$idx] 落地 ${r_name}${NC}"
        echo -e " Clash:        - {name: ${host}-to-${r_name}, type: vless, server: $ip, port: 443, uuid: $r_uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $v_pbk, short-id: '$v_sid'}, client-fingerprint: chrome}"
        echo ""
        echo -e " Quantumult X: vless=$ip:443, method=none, password=$r_uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=${host}-to-${r_name}"
        idx=$((idx+1))
      fi
    done
  fi

  echo ""
  pause
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
    echo -e "${B}│     Sing-box Elite 管理系统 + Installer V-1.11.1 │${NC}"
    echo -e "${B}└──────────────────────────────────────────────────┘${NC}"
    echo -e "  ${C}1.${NC} 安装/更新 sing-box（APT 源，依赖检测+版本对比）"
    echo -e "  ${C}2.${NC} 清空/重置 config.json（最小模板）"
    echo -e "  ${C}3.${NC} 查看配置文件（sing-box format）"
    echo -e "  ${C}4.${NC} 核心模块管理 (安装/卸载：vless-reality/ss/tuic/vless-ws)"
    echo -e "  ${C}5.${NC} 中转节点管理 (安装/卸载)"
    echo -e "  ${C}6.${NC} 导出客户端配置 (Clash/Quantumult X)"
    echo -e "  ${C}7.${NC} 卸载 sing-box（保留 /etc/sing-box/ 配置）"
    echo -e "  ${R}q.${NC} 退出系统"
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
      q|Q) exit 0 ;;
      *) warn "无效输入：$opt"; sleep 1 ;;
    esac
  done
}

main_menu

main_menu
