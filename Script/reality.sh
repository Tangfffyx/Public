#!/bin/bash

# ====================================================
# Project: Sing-box Elite Management System
# Version: 1.8.5 (Prompt & Default Value Update)
# ====================================================

CONFIG_FILE="/etc/sing-box/config.json"
TEMP_FILE="/etc/sing-box/config.json.tmp"

# 颜色定义
B='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; NC='\033[0m'; W='\033[1;37m'

init_env() {
    if ! command -v jq &> /dev/null; then
        apt-get update && apt-get install -y jq || yum install -y jq
    fi
    if [ ! -s "$CONFIG_FILE" ] || ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
        cat > "$CONFIG_FILE" <<EOF
{
  "log": {"level": "info","timestamp": true},
  "inbounds": [],
  "outbounds": [{"type": "direct","tag": "direct"}],
  "route": {"rules": [],"final": "direct"}
}
EOF
    fi
}

atomic_save() {
    local json_data="$1"
    echo "$json_data" | jq . > "$TEMP_FILE" || return 1
    mv -f "$TEMP_FILE" "$CONFIG_FILE"
    systemctl restart sing-box && echo -e "${G}[成功] 系统服务已重启并应用配置。${NC}"
}

# --- 1. 核心同步 ---
sync_core_services() {
    init_env; local conf=$(cat "$CONFIG_FILE")
    local has_vless=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "vless-main-in")' >/dev/null && echo "true" || echo "false")
    local has_ss=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "ss-in")' >/dev/null && echo "true" || echo "false")
    local has_tuic=$(echo "$conf" | jq -e '.inbounds[]? | select(.tag == "tuic-in")' >/dev/null && echo "true" || echo "false")
    local updated_json="$conf"

    echo -e "\n${C}─── 核心入站协议同步 ───${NC}"
    
    if [ "$has_vless" == "true" ]; then
        echo -e " Reality 模块: ${G}已激活${NC}"
        uuid=$(echo "$conf" | jq -r '.inbounds[] | select(.tag == "vless-main-in") | .users[0].uuid')
        sni=$(echo "$conf" | jq -r '.inbounds[] | select(.tag == "vless-main-in") | .tls.server_name')
    else
        echo -e " Reality 模块: ${Y}未配置${NC}"
        read -p " Private Key: " priv_key
        read -p " Short ID: " sid
        read -p " 目标域名 (默认: www.icloud.com): " sni; sni=${sni:-"www.icloud.com"}
        uuid=$(sing-box generate uuid)
        [ -z "$sid" ] && sid_json="[]" || sid_json="[\"$sid\"]"
        in_v=$(jq -n --arg uuid "$uuid" --arg priv "$priv_key" --argjson sid "$sid_json" --arg sni "$sni" '{"type":"vless","tag":"vless-main-in","listen":"::","listen_port":443,"users":[{"name":"direct-user","uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":$sid}}}')
        updated_json=$(echo "$updated_json" | jq --argjson v "$in_v" '.inbounds += [$v]')
    fi

    if [ "$has_ss" == "true" ]; then echo -e " Shadowsocks:  ${G}已激活${NC}"; else
        read -p " Shadowsocks 密码: " ss_p
        [ -n "$ss_p" ] && in_s=$(jq -n --arg p "$ss_p" '{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":8080,"method":"aes-128-gcm","password":$p}') && updated_json=$(echo "$updated_json" | jq --argjson s "$in_s" '.inbounds += [$s]')
    fi

    if [ "$has_tuic" == "true" ]; then echo -e " TUIC V5:      ${G}激活${NC}"; else
        read -p " TUIC 域名 (默认: www.icloud.com): " t_sni_in; t_sni=${t_sni_in:-"www.icloud.com"}
        t_pass=$(openssl rand -base64 12)
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout /etc/sing-box/tuic.key -out /etc/sing-box/tuic.crt -days 3650 -subj "/CN=$t_sni" &> /dev/null
        in_t=$(jq -n --arg uuid "$uuid" --arg p "$t_pass" --arg t_sni "$t_sni" '{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":443,"users":[{"name":"tuic-user","uuid":$uuid,"password":$p}],"congestion_control":"bbr","zero_rtt_handshake":false,"tls":{"enabled":true,"server_name":$t_sni,"alpn":["h3"],"certificate_path":"/etc/sing-box/tuic.crt","key_path":"/etc/sing-box/tuic.key"}}')
        updated_json=$(echo "$updated_json" | jq --argjson t "$in_t" '.inbounds += [$t]')
    fi

    updated_json=$(echo "$updated_json" | jq '.route.rules = [{"auth_user": ["direct-user", "tuic-user"], "action": "route", "outbound": "direct"}] + [ .route.rules[]? | select(.auth_user != null and ( .auth_user | any(startswith("relay-")) )) ]')
    atomic_save "$updated_json"; read -n 1 -p "按任意键返回..."
}

# --- 2. 添加/覆盖中转 ---
add_relay_node() {
    init_env; local conf=$(cat "$CONFIG_FILE")
    echo -e "\n${C}─── 添加/覆盖中转节点 ───${NC}"
    read -p " 落地标识 (如 sg01): " n; [ -z "$n" ] && return
    read -p " 落地 IP 地址: " ip; [ -z "$ip" ] && return
    read -p " 落地 SS 密码: " p; [ -z "$p" ] && return
    
    local user="relay-$n"; local out="out-to-$n"; local uuid=$(sing-box generate uuid)
    new_u=$(jq -n --arg name "$user" --arg uuid "$uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')
    new_o=$(jq -n --arg tag "$out" --arg addr "$ip" --arg key "$p" '{"type":"shadowsocks","tag":$tag,"server":$addr,"server_port":8080,"method":"aes-128-gcm","password":$key}')
    new_r=$(jq -n --arg user "$user" --arg out "$out" '{"auth_user":[$user],"action":"route","outbound":$out}')
    
    conf=$(echo "$conf" | jq --arg user "$user" '(.inbounds[] | select(.tag == "vless-main-in").users) |= map(select(.name != $user))')
    conf=$(echo "$conf" | jq --arg out "$out" '.outbounds |= map(select(.tag != $out))')
    conf=$(echo "$conf" | jq --arg user "$user" '.route.rules |= map(select(.auth_user != [$user]))')
    updated_json=$(echo "$conf" | jq --argjson u "$new_u" --argjson o "$new_o" --argjson r "$new_r" '(.inbounds[] | select(.tag == "vless-main-in").users) += [$u] | .outbounds += [$o] | .route.rules = [$r] + .route.rules')
    
    atomic_save "$updated_json"
}

# --- 3. 删除中转 ---
del_relay_node() {
    local conf=$(cat "$CONFIG_FILE")
    mapfile -t nodes < <(echo "$conf" | jq -r '.inbounds[]? | select(.tag == "vless-main-in") | .users[]? | select(.name | startswith("relay-")) | .name' | sed 's/relay-//')
    [ ${#nodes[@]} -eq 0 ] && { echo -e "${Y}暂无已配置的中转节点。${NC}"; sleep 1; return; }
    
    echo -e "\n${R}─── 删除中转节点 ───${NC}"
    for i in "${!nodes[@]}"; do echo -e " [$(($i+1))] ${nodes[$i]}"; done
    read -p " 请输入要删除的编号: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#nodes[@]}" ]; then
        local target="${nodes[$(($choice-1))]}"
        updated_json=$(echo "$conf" | jq --arg u "relay-$target" --arg o "out-to-$target" '(.inbounds[] | select(.tag == "vless-main-in").users) |= map(select(.name != $u)) | .outbounds |= map(select(.tag != $o)) | .route.rules |= map(select(.auth_user != [$u]))')
        atomic_save "$updated_json"
    fi
}

# --- 4. 导出配置 ---
export_configs() {
    clear; local conf=$(cat "$CONFIG_FILE"); local ip=$(curl -s4 ifconfig.me || echo "IP"); local host=$(hostname)
    echo -e "\n${C}─── 节点配置导出 ───${NC}"
    read -p " 请输入 Reality Public Key: " v_pbk; v_pbk=${v_pbk:-"KEY_MISSING"}
    
    local v_sni=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-main-in") | .tls.server_name // "www.icloud.com"')
    local v_sid=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-main-in") | .tls.reality.short_id[0] // ""')

    local main_uuid=$(echo "$conf" | jq -r '.inbounds[]? | select(.tag=="vless-main-in") | .users[]? | select(.name=="direct-user") | .uuid // empty')
    if [ -n "$main_uuid" ]; then
        echo -e "\n${W}[VLESS Reality]${NC}"
        echo -e " Clash: - {name: ${host}-Reality, type: vless, server: $ip, port: 443, uuid: $main_uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $v_pbk, short-id: '$v_sid'}, client-fingerprint: chrome}"
        echo -e " QX:    vless=$ip:443, method=none, password=$main_uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=${host}-Reality"
    fi

    if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="tuic-in")' >/dev/null; then
        local t_u=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].uuid')
        local t_p=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].password')
        local t_s=$(echo "$conf" | jq -r '.inbounds[] | select(.tag=="tuic-in") | .tls.server_name')
        echo -e "\n${W}[TUIC V5]${NC}"
        echo -e " Clash: - {name: ${host}-TUIC, type: tuic, server: $ip, port: 443, uuid: $t_u, password: $t_p, alpn: [h3], disable-sni: true, reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true, sni: $t_s}"
    fi

    if echo "$conf" | jq -e '.inbounds[]? | select(.tag=="vless-main-in") | .users[]? | select(.name | startswith("relay-"))' >/dev/null; then
        echo -e "\n${W}[Tunnel Relays]${NC}"
        echo "$conf" | jq -c '.inbounds[]? | select(.tag=="vless-main-in") | .users[]? | select(.name | startswith("relay-"))' | while read -r u; do
            local r_name=$(echo "$u" | jq -r '.name' | sed 's/relay-//'); local r_uuid=$(echo "$u" | jq -r '.uuid')
            echo -e " Clash: - {name: ${host}-to-${r_name}, type: vless, server: $ip, port: 443, uuid: $r_uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $v_pbk, short-id: '$v_sid'}, client-fingerprint: chrome}"
            echo -e " QX:    vless=$ip:443, method=none, password=$r_uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=${host}-to-${r_name}"
        done
    fi
    echo ""
    read -n 1 -p "按任意键返回主菜单..."
}

while true; do
    clear
    echo -e "${B}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│          Sing-box Elite 管理系统 V-1.8.5         │${NC}"
    echo -e "${B}└──────────────────────────────────────────────────┘${NC}"
    echo -e "  ${C}1.${NC} 核心服务同步 (Reality/SS/TUIC)"
    echo -e "  ${C}2.${NC} 添加或覆盖中转节点"
    echo -e "  ${C}3.${NC} 删除现有中转节点"
    echo -e "  ${C}4.${NC} 导出客户端配置 (Clash/QX)"
    echo -e "  ${R}q.${NC} 退出系统"
    echo -e "${B}────────────────────────────────────────────────────${NC}"
    read -p " 请选择操作指令: " opt
    case $opt in 1) sync_core_services ;; 2) add_relay_node ;; 3) del_relay_node ;; 4) export_configs ;; q) exit 0 ;; esac
done
