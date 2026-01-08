#!/bin/bash

# ====================================================
# Project: Sing-box Elite Management System
# Version: 1.9.3 (Better prompts + "Quantumult X" label)
#
# Key behaviors (per your requirements):
# - VLESS (TCP) + TUIC (UDP) share port 443 OK
# - Validation: sing-box check -c /etc/sing-box/config.json
# - Relay SS is FIXED: port 8080 + aes-128-gcm
# - Export does NOT mask secrets
# - Routing logic:
#   * Option 1 ensures direct-user + tuic-user => direct (managed)
#   * Option 2 manages relay-* => out-to-* (managed)
#   * If config already has other rules, we do NOT touch them
#   * If managed rules exist, overwrite; if not, add
#   * Prevent duplicates via safe de-duplication (objects only)
# ====================================================

set -Eeuo pipefail

CONFIG_FILE="/etc/sing-box/config.json"
TEMP_FILE="/etc/sing-box/config.json.tmp"

# 颜色定义
B='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; NC='\033[0m'; W='\033[1;37m'

cleanup() { rm -f "$TEMP_FILE"; }
trap cleanup EXIT

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${R}[错误] 请使用 root 运行此脚本。${NC}"
    exit 1
  fi
}

install_pkg() {
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$pkg"
  else
    echo -e "${R}[错误] 未找到可用的包管理器(apt/dnf/yum)，请手动安装: $pkg${NC}"
    exit 1
  fi
}

get_public_ip() {
  local ip=""
  ip=$(curl -s4 --max-time 3 --connect-timeout 2 ifconfig.me 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 api.ipify.org 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 icanhazip.com 2>/dev/null | tr -d '\n' || true)
  [ -z "$ip" ] && ip="IP"
  echo "$ip"
}

init_env() {
  require_root

  if ! command -v jq >/dev/null 2>&1; then install_pkg jq; fi
  if ! command -v curl >/dev/null 2>&1; then install_pkg curl; fi
  if ! command -v openssl >/dev/null 2>&1; then install_pkg openssl; fi

  if ! command -v sing-box >/dev/null 2>&1; then
    echo -e "${R}[错误] 未找到 sing-box，请先安装后再运行。${NC}"
    exit 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${R}[错误] 未找到 systemctl（可能不是 systemd 系统），此脚本需要 systemd 管理 sing-box。${NC}"
    exit 1
  fi

  if [ ! -s "$CONFIG_FILE" ] || ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {"level": "info","timestamp": true},
  "inbounds": [],
  "outbounds": [{"type": "direct","tag": "direct"}],
  "route": {"rules": []}
}
EOF
  fi
}

atomic_save() {
  local json_data="$1"
  local backup="/etc/sing-box/config.json.bak.$(date +%Y%m%d_%H%M%S)"

  echo "$json_data" | jq . > "$TEMP_FILE" || {
    echo -e "${R}[失败] JSON 生成/格式化失败，未写入配置。${NC}"
    return 1
  }

  if ! sing-box check -c "$TEMP_FILE" >/dev/null 2>&1; then
    echo -e "${R}[失败] sing-box check 校验未通过，未写入配置。${NC}"
    sing-box check -c "$TEMP_FILE" 2>&1 | sed 's/^/  /'
    return 1
  fi

  if [ -f "$CONFIG_FILE" ]; then
    cp -a "$CONFIG_FILE" "$backup"
  fi

  mv -f "$TEMP_FILE" "$CONFIG_FILE"

  if systemctl restart sing-box; then
    echo -e "${G}[成功] 系统服务已重启并应用配置。${NC}"
    return 0
  else
    echo -e "${R}[失败] sing-box 重启失败，正在回滚到备份配置...${NC}"
    if [ -f "$backup" ]; then
      cp -a "$backup" "$CONFIG_FILE"
      if systemctl restart sing-box; then
        echo -e "${Y}[回滚成功] 已恢复到上一版配置并重启。${NC}"
      else
        echo -e "${R}[回滚失败] 请手动检查：systemctl status sing-box${NC}"
      fi
    else
      echo -e "${R}[回滚失败] 未找到备份文件：$backup${NC}"
    fi
    return 1
  fi
}

# --- 托管路由规则同步：仅覆盖 direct-user/tuic-user 与 relay-* 对应规则，不动其它，并去重 ---
sync_managed_route_rules() {
  local json="$1"

  echo "$json" | jq '
    . as $cfg
    | def relay_users($c):
        [ $c.inbounds[]?
          | select(.tag=="vless-main-in")
          | .users[]?
          | select(.name | startswith("relay-"))
          | .name
        ];

      def desired_rules($rels):
        (
          [ {"auth_user":["direct-user","tuic-user"],"outbound":"direct"} ]
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
                    if (.auth_user? == ["direct-user","tuic-user"]) then
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

# --- 删除某个 relay 的 route 规则（即使 relay 用户已删，也要把遗留规则删掉），并且对脏 rules 做类型保护 ---
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

# --- 1. 核心同步 ---
sync_core_services() {
  init_env
  local conf; conf=$(cat "$CONFIG_FILE")

  local has_vless has_ss has_tuic
  has_vless=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-main-in")' >/dev/null 2>&1 && echo "true" || echo "false")
  has_ss=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "ss-in")' >/dev/null 2>&1 && echo "true" || echo "false")
  has_tuic=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "tuic-in")' >/dev/null 2>&1 && echo "true" || echo "false")

  local updated_json="$conf"
  local uuid sni

  echo -e "\n${C}─── 核心入站协议同步 ───${NC}"

  if [ "$has_vless" == "true" ]; then
    echo -e " Reality 模块:       ${G}已配置${NC}"
    uuid=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-main-in") | .users[] | select(.name=="direct-user") | .uuid // empty')
    sni=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="vless-main-in") | .tls.server_name // "www.icloud.com"')
  else
    echo -e " Reality 模块:       ${Y}未配置${NC}"
    read -p " Private Key: " priv_key
    read -p " Short ID: " sid
    read -p " 目标域名 (默认: www.icloud.com): " sni; sni=${sni:-"www.icloud.com"}
    uuid=$(sing-box generate uuid)

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
        "tag":"vless-main-in",
        "listen":"::",
        "listen_port":443,
        "users":[{"name":"direct-user","uuid":$uuid,"flow":"xtls-rprx-vision"}],
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
  fi

  # 1.9.3: 在输入前明确提示 SS/TUIC 是否已配置
  if [ "$has_ss" == "true" ]; then
    echo -e " Shadowsocks 模块:   ${G}已配置${NC}"
  else
    echo -e " Shadowsocks 模块:   ${Y}未配置${NC}"
    read -p " Shadowsocks 密码: " ss_p
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
    fi
  fi

  if [ "$has_tuic" == "true" ]; then
    echo -e " TUIC V5 模块:       ${G}已配置${NC}"
  else
    echo -e " TUIC V5 模块:       ${Y}未配置${NC}"
    read -p " TUIC 域名 (默认: www.icloud.com): " t_sni_in
    local t_sni=${t_sni_in:-"www.icloud.com"}
    local t_pass
    t_pass=$(openssl rand -base64 12)

    openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout /etc/sing-box/tuic.key -out /etc/sing-box/tuic.crt \
      -days 36500 -nodes -subj "/CN=$t_sni" &> /dev/null

    local in_t
    in_t=$(jq -n --arg uuid "$uuid" --arg p "$t_pass" --arg sni "$t_sni" '{
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
  fi

  # 托管路由规则：仅维护 direct-user/tuic-user + relay-* 对应规则，其他不动，且去重
  updated_json=$(sync_managed_route_rules "$updated_json")

  atomic_save "$updated_json"
  read -n 1 -p "按任意键返回..."
}

# --- 2. 添加/覆盖中转节点 ---
add_relay_node() {
  init_env
  local conf; conf=$(cat "$CONFIG_FILE")

  echo -e "\n${C}─── 添加/覆盖中转节点 ───${NC}"
  read -p " 落地标识 (如 sg01): " n; [ -z "${n:-}" ] && return
  read -p " 落地 IP 地址: " ip; [ -z "${ip:-}" ] && return
  read -p " 落地 SS 密码: " p; [ -z "${p:-}" ] && return

  local user="relay-$n"
  local out="out-to-$n"
  local uuid; uuid=$(sing-box generate uuid)

  local new_u new_o
  new_u=$(jq -n --arg name "$user" --arg uuid "$uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')
  # 固定 8080 + aes-128-gcm（按你的需求写死）
  new_o=$(jq -n --arg tag "$out" --arg addr "$ip" --arg key "$p" '{
    "type":"shadowsocks",
    "tag":$tag,
    "server":$addr,
    "server_port":8080,
    "method":"aes-128-gcm",
    "password":$key
  }')

  # 清理同名 user/outbound（route 由托管函数统一生成，避免重复）
  conf=$(echo "$conf" | jq --arg user "$user" '(.inbounds[] | select(.tag == "vless-main-in").users) |= map(select(.name != $user))')
  conf=$(echo "$conf" | jq --arg out "$out" '.outbounds |= map(select(.tag != $out))')

  # 追加 user + outbound（不在这里手动加 route.rules，避免双重生成导致重复）
  local updated_json
  updated_json=$(echo "$conf" | jq --argjson u "$new_u" --argjson o "$new_o" '
    (.inbounds[] | select(.tag == "vless-main-in").users) += [$u]
    | .outbounds += [$o]
  ')

  # 托管规则同步（会覆盖/补全 relay 路由，且去重，不动其它）
  updated_json=$(sync_managed_route_rules "$updated_json")

  atomic_save "$updated_json"
  read -n 1 -p "按任意键返回..."
}

# --- 3. 删除中转节点 ---
del_relay_node() {
  init_env
  local conf; conf=$(cat "$CONFIG_FILE")

  mapfile -t nodes < <(echo "$conf" | jq -r '
    .inbounds[]? | select(.tag == "vless-main-in")
    | .users[]? | select(.name | startswith("relay-")) | .name
  ' | sed 's/relay-//')

  if [ ${#nodes[@]} -eq 0 ]; then
    echo -e "${Y}暂无已配置的中转节点。${NC}"
    sleep 1
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
      (.inbounds[] | select(.tag == "vless-main-in").users) |= map(select(.name != $u))
      | .outbounds |= map(select(.tag != $o))
    ')

    # 即使 relay 用户已删，也要把遗留的 route 规则删掉（安全处理脏 rules）
    updated_json=$(remove_relay_rule_safely "$updated_json" "$relay_user")

    # 再同步托管规则：删除 relay 后，对应托管规则会自动消失；其他规则不动，并去重
    updated_json=$(sync_managed_route_rules "$updated_json")

    atomic_save "$updated_json"
  fi

  read -n 1 -p "按任意键返回..."
}

# --- 4. 导出配置 (从 TUIC 节点读取 SNI) ---
export_configs() {
  clear
  local conf; conf=$(cat "$CONFIG_FILE")
  local ip; ip=$(get_public_ip)
  local host; host=$(hostname)

  echo -e "\n${C}─── 节点配置导出 ───${NC}"
  read -p " 请输入 Reality Public Key: " v_pbk; v_pbk=${v_pbk:-"KEY_MISSING"}

  local v_sni v_sid main_uuid
  v_sni=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-main-in") | .tls.server_name // "www.icloud.com"')
  v_sid=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-main-in") | .tls.reality.short_id[0] // ""')
  main_uuid=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-main-in") | .users[]? | select(.name=="direct-user") | .uuid // empty')

  if [ -n "$main_uuid" ]; then
    echo -e "\n${W}[VLESS Reality]${NC}"
    echo -e " Clash:        - {name: ${host}-Reality, type: vless, server: $ip, port: 443, uuid: $main_uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $v_pbk, short-id: '$v_sid'}, client-fingerprint: chrome}"
    echo ""
    echo -e " Quantumult X: vless=$ip:443, method=none, password=$main_uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=${host}-Reality"
  fi

  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="tuic-in")' >/dev/null 2>&1; then
    local t_u t_p t_s
    t_u=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].uuid')
    t_p=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].password')
    t_s=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .tls.server_name // "www.icloud.com"')

    echo -e "\n${W}[TUIC V5]${NC}"
    echo -e " Clash:        - {name: ${host}-TUIC, type: tuic, server: $ip, port: 443, uuid: $t_u, password: $t_p, alpn: [h3], disable-sni: true, reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true, sni: $t_s}"
  fi

  if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-main-in") | .users[]? | select(.name | startswith("relay-"))' >/dev/null 2>&1; then
    echo -e "\n${W}[Tunnel Relays]${NC}"
    echo "$conf" | jq -c '.inbounds[]? | select(.tag=="vless-main-in") | .users[]? | select(.name | startswith("relay-"))' \
      | while read -r u; do
        local r_name r_uuid
        r_name=$(echo "$u" | jq -r '.name' | sed 's/relay-//')
        r_uuid=$(echo "$u" | jq -r '.uuid')

        echo -e " Clash:        - {name: ${host}-to-${r_name}, type: vless, server: $ip, port: 443, uuid: $r_uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $v_pbk, short-id: '$v_sid'}, client-fingerprint: chrome}"
        echo ""
        echo -e " Quantumult X: vless=$ip:443, method=none, password=$r_uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=${host}-to-${r_name}"
      done
  fi

  echo ""
  read -n 1 -p "按任意键返回主菜单..."
}

while true; do
  clear
  echo -e "${B}┌──────────────────────────────────────────────────┐${NC}"
  echo -e "${B}│          Sing-box Elite 管理系统 V-1.9.3         │${NC}"
  echo -e "${B}└──────────────────────────────────────────────────┘${NC}"
  echo -e "  ${C}1.${NC} 核心服务同步 (Reality/SS/TUIC)"
  echo -e "  ${C}2.${NC} 添加或覆盖中转节点"
  echo -e "  ${C}3.${NC} 删除现有中转节点"
  echo -e "  ${C}4.${NC} 导出客户端配置 (Clash/Quantumult X)"
  echo -e "  ${R}q.${NC} 退出系统"
  echo -e "${B}────────────────────────────────────────────────────${NC}"
  read -p " 请选择操作指令: " opt
  case "${opt:-}" in
    1) sync_core_services ;;
    2) add_relay_node ;;
    3) del_relay_node ;;
    4) export_configs ;;
    q) exit 0 ;;
  esac
done
