#!/bin/bash

# ====================================================
# Project: Sing-box 终极管理脚本
# Features: Reality + TUIC V5 + SS-AES-128-GCM
# ====================================================

CONFIG_FILE="/etc/sing-box/config.json"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

init_env() {
    if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
        apt-get update && apt-get install -y jq openssl || yum install -y jq openssl
    fi
    if [ ! -d "/etc/sing-box" ]; then mkdir -p /etc/sing-box; fi
    if [ ! -s "$CONFIG_FILE" ] || ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}' > "$CONFIG_FILE"
    fi
}

show_menu() {
    clear
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}    Sing-box 终极管理脚本 (VLESS/SS/TUIC)     ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo " 1. 【本机配置】配置 Reality + SS + TUIC 入站"
    echo " 2. 【添加中转】连接落地机 (使用 SS-AES-GCM 隧道)"
    echo " 3. 列出节点配置 (含 QX/Clash Meta)"
    echo " 4. 删除指定中转节点"
    echo " q. 退出"
    echo -e "${GREEN}----------------------------------------------${NC}"
    read -p "请输入选项: " opt
}

# 1. 本机服务配置 (Reality + SS + TUIC)
add_local_services() {
    echo -e "${YELLOW}--- 配置本机入站服务 ---${NC}"
    
    # --- SS 配置 ---
    read -p "请输入 SS (aes-128-gcm) 密码 (回车随机): " ss_key
    ss_key=${ss_key:-$(openssl rand -base64 16)}
    in_ss=$(jq -n --arg key "$ss_key" '{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":8080,"method":"aes-128-gcm","password":$key}')

    # --- TUIC 配置 ---
    echo -e "${CYAN}配置 TUIC V5 (监听 443 UDP)...${NC}"
    read -p "请输入 TUIC 自签名伪装域名 (如 www.bing.com): " tuic_sni
    tuic_sni=${tuic_sni:-"www.bing.com"}
    tuic_uuid=$(sing-box generate uuid)
    read -p "请输入 TUIC 认证密码 (回车随机): " tuic_pass
    tuic_pass=${tuic_pass:-$(openssl rand -base64 12)}
    
    # 生成自签名证书
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout /etc/sing-box/self_tuic.key -out /etc/sing-box/self_tuic.crt -days 3650 -subj "/CN=$tuic_sni" &> /dev/null

    in_tuic=$(jq -n --arg uuid "$tuic_uuid" --arg pass "$tuic_pass" '{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":443,"users":[{"name":"tuic-user","uuid":$uuid,"password":$pass}],"congestion_control":"bbr","tls":{"enabled":true,"certificate_path":"/etc/sing-box/self_tuic.crt","key_path":"/etc/sing-box/self_tuic.key","alpn":["h3"]}}')

    # --- Reality 配置 (检测增量) ---
    has_vless=$(jq -r '.inbounds[]? | select(.tag == "vless-main-in") | .tag' "$CONFIG_FILE")
    
    if [ -n "$has_vless" ] && [ "$has_vless" != "null" ]; then
        echo -e "${GREEN}检测到 Reality 已存在，正在更新 SS 和 TUIC...${NC}"
        updated_json=$(jq --argjson new_ss "$in_ss" --argjson new_tuic "$in_tuic" '
            .inbounds = ([.inbounds[]? | select(.tag != "ss-in" and .tag != "tuic-in")] + [$new_ss, $new_tuic])
        ' "$CONFIG_FILE")
    else
        echo -e "${RED}未检测到 Reality，开始全量配置...${NC}"
        read -p "Reality Private_Key: " priv_key
        read -p "Reality Short_ID: " sid
        read -p "Reality SNI: " sni
        v_uuid=$(sing-box generate uuid)

        in_reality=$(jq -n --arg uuid "$v_uuid" --arg priv "$priv_key" --arg sid "$sid" --arg sni "$sni" \
            '{"type":"vless","tag":"vless-main-in","listen":"::","listen_port":443,"users":[{"name":"direct-user","uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}')
        
        # 默认路由规则
        rules=$(jq -n '{"auth_user":["direct-user","tuic-user"],"action":"route","outbound":"direct"}')

        updated_json=$(jq --argjson new_vless "$in_reality" --argjson new_ss "$in_ss" --argjson new_tuic "$in_tuic" --argjson rule "$rules" '
            .inbounds = ([.inbounds[]? | select(.tag != "vless-main-in" and .tag != "ss-in" and .tag != "tuic-in")] + [$new_vless, $new_ss, $new_tuic]) |
            .route.rules = ([$rule] + [.route.rules[]? | select(.auth_user != ["direct-user"])])
        ' "$CONFIG_FILE")
    fi

    echo "$updated_json" > "$CONFIG_FILE" && systemctl restart sing-box
    echo -e "${GREEN}配置完成！端口 443 (Reality/TUIC) 和 8080 (SS) 已就绪。${NC}"
    read -p "按回车返回..."
}

# 2. 添加中转节点 (SS-AES-GCM 隧道 & UUID 继承)
add_relay_node() {
    if ! jq -e '.inbounds[]? | select(.tag == "vless-main-in")' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}错误：请先执行选项 1 配置基础入站。${NC}"; sleep 2; return
    fi
    
    read -p "1. 落地机标识 (如 sg02): " node_name
    [ -z "$node_name" ] && return
    read -p "2. 落地机 IP 地址: " remote_ip
    read -p "3. 落地机 SS (aes-128-gcm) 密码: " remote_key
    
    user_name="relay-$node_name"
    out_tag="out-to-$node_name"

    # 尝试提取原有 UUID
    old_uuid=$(jq -r --arg name "$user_name" '.inbounds[] | select(.tag == "vless-main-in") | .users[]? | select(.name == $name) | .uuid' "$CONFIG_FILE")

    if [ -n "$old_uuid" ] && [ "$old_uuid" != "null" ]; then
        echo -e "${GREEN}检测到同名标识，继承 UUID: $old_uuid${NC}"
        relay_uuid="$old_uuid"
    else
        relay_uuid=$(sing-box generate uuid)
    fi

    new_user=$(jq -n --arg name "$user_name" --arg uuid "$relay_uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')
    new_out=$(jq -n --arg tag "$out_tag" --arg addr "$remote_ip" --arg key "$remote_key" \
        '{"type":"shadowsocks","tag":$tag,"server":$addr,"server_port":8080,"method":"aes-128-gcm","password":$key}')
    new_rule=$(jq -n --arg user "$user_name" --arg out "$out_tag" '{"auth_user":[$user],"action":"route","outbound":$out}')

    updated_json=$(jq --arg user_name "$user_name" --arg out_tag "$out_tag" --argjson user "$new_user" --argjson out "$new_out" --argjson rule "$new_rule" '
        (.inbounds[] | select(.tag == "vless-main-in").users) |= (del(.[] | select(.name == $user_name)) + [$user]) |
        .outbounds = ([.outbounds[]? | select(.tag != $out_tag)] + [$out]) |
        .route.rules = ([$rule] + [.route.rules[]? | select(.auth_user != [$user_name])])
    ' "$CONFIG_FILE")

    echo "$updated_json" > "$CONFIG_FILE" && systemctl restart sing-box
    echo -e "${GREEN}中转节点 [$node_name] 已配置/覆盖，协议已切换为 SS-AES-128-GCM。${NC}"
    read -p "按回车返回..."
}

# 3. 列出节点配置 (支持 QX/Clash Meta)
list_nodes() {
    clear
    local hostname=$(hostname)
    local my_ip=$(curl -s4 ifconfig.me || echo "你的IP")
    
    # Reality 信息
    local v_in=$(jq -r '.inbounds[] | select(.tag=="vless-main-in")' "$CONFIG_FILE")
    if [ -n "$v_in" ] && [ "$v_in" != "null" ]; then
        echo -e "${GREEN}=== Reality 节点 (QX & Clash Meta) ===${NC}"
        read -p "请输入 Reality Public_Key: " pub_key
        pub_key=${pub_key:-"YOUR_PUB_KEY"}
        
        local v_port=$(echo "$v_in" | jq -r '.listen_port')
        local v_sni=$(echo "$v_in" | jq -r '.tls.server_name')
        local v_sid=$(echo "$v_in" | jq -r '.tls.reality.short_id[0]')

        echo "$v_in" | jq -c '.users[]' | while read -r user; do
            name=$(echo "$user" | jq -r '.name')
            uuid=$(echo "$user" | jq -r '.uuid')
            # 命名逻辑：本机名-relay-标识
            [[ "$name" == "direct-user" ]] && dname="${hostname}-direct" || dname="${hostname}-${name}"
            
            echo -e "\n${CYAN}节点: $dname${NC}"
            echo -e "${YELLOW}[Clash Meta]${NC} - {name: $dname, type: vless, server: $my_ip, port: $v_port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $pub_key, short-id: '$v_sid'}, client-fingerprint: chrome}"
            echo -e "${YELLOW}[QX]${NC} vless=$my_ip:$v_port, method=none, password=$uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$pub_key, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=$dname"
        done
    fi

    # TUIC 信息
    local t_in=$(jq -r '.inbounds[] | select(.tag=="tuic-in")' "$CONFIG_FILE")
    if [ -n "$t_in" ] && [ "$t_in" != "null" ]; then
        echo -e "\n${GREEN}=== TUIC V5 节点 (仅 Clash Meta) ===${NC}"
        local t_uuid=$(echo "$t_in" | jq -r '.users[0].uuid')
        local t_pass=$(echo "$t_in" | jq -r '.users[0].password')
        local t_sni=$(openssl x509 -in /etc/sing-box/self_tuic.crt -noout -subject -nameopt RFC2253 | sed 's/.*CN=//')
        t_name="${hostname}-tuic-V5"

        echo -e "${CYAN}节点: $t_name${NC}"
        echo -e "${YELLOW}[Clash Meta]${NC}"
        echo "- name: $t_name"
        echo "  server: $my_ip"
        echo "  port: 443"
        echo "  type: tuic"
        echo "  uuid: $t_uuid"
        echo "  password: $t_pass"
        echo "  alpn: [h3]"
        echo "  disable-sni: true"
        echo "  reduce-rtt: true"
        echo "  udp-relay-mode: native"
        echo "  congestion-controller: bbr"
        echo "  sni: $t_sni"
        echo "  skip-cert-verify: true"
    fi

    # SS 隧道信息
    local ss_key=$(jq -r '.inbounds[] | select(.tag=="ss-in") | .password // empty' "$CONFIG_FILE")
    if [ -n "$ss_key" ]; then
        echo -e "\n${GREEN}=== 本机 SS 隧道落地信息 (供中转机使用) ===${NC}"
        echo "Port: 8080 | Method: aes-128-gcm | Key: $ss_key"
    fi
    read -p "按回车返回..."
}

# 4. 删除中转节点
delete_node() {
    clear
    local nodes=$(jq -r '.inbounds[].users[]?.name' "$CONFIG_FILE" | grep "relay-")
    if [ -z "$nodes" ]; then echo "没有可删除的中转节点"; sleep 1; return; fi
    
    echo -e "${YELLOW}当前中转节点列表：${NC}"
    echo "$nodes" | sed 's/relay-//g'
    read -p "请输入要删除的标识 (如 sg02): " target
    [ -z "$target" ] && return
    
    user_tag="relay-$target"
    out_tag="out-to-$target"
    
    updated_json=$(jq --arg user "$user_tag" --arg out "$out_tag" '
        (.inbounds[] | select(.tag == "vless-main-in").users) |= del(.[] | select(.name == $user)) |
        .outbounds = ([.outbounds[]? | select(.tag != $out)] ) |
        .route.rules = [.route.rules[]? | select(.auth_user != [$user])]
    ' "$CONFIG_FILE")
    
    echo "$updated_json" > "$CONFIG_FILE" && systemctl restart sing-box
    echo -e "${GREEN}节点已删除。${NC}"
    sleep 1
}

# 脚本入口
init_env
while true; do
    show_menu
    case $opt in
        1) add_local_services ;;
        2) add_relay_node ;;
        3) list_nodes ;;
        4) delete_node ;;
        q) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
