#!/bin/bash

# ====================================================
# Project: Sing-box Reality 一键管理脚本 (稳定版)
# Author: Tangfffyx
# ====================================================

CONFIG_FILE="/etc/sing-box/config.json"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 初始化环境：只安装依赖，不重置文件
init_env() {
    if ! command -v jq &> /dev/null; then
        apt-get update && apt-get install -y jq || yum install -y jq
    fi
}

show_menu() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}    Sing-box Reality 自动化管理脚本     ${NC}"
    echo -e "${GREEN}    (Auth_User + Action: Route 版)    ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo " 1. 检查 443 端口占用"
    echo " 2. 【落地/直连】配置 443 主入站"
    echo " 3. 【中转机】添加/更新落地节点"
    echo " 4. 列出当前节点配置 (Clash/QX)"
    echo " 5. 删除指定中转节点"
    echo " q. 退出脚本"
    echo -e "${GREEN}--------------------------------------${NC}"
    read -p "请输入选项: " opt
}

# 2. 基础入站配置 (仅保留 auth_user)
add_direct_node() {
    echo -e "${YELLOW}开始配置 443 端口 Reality 主入站...${NC}"
    read -p "请输入 Reality Private_Key: " priv_key
    read -p "请输入 Reality Short_ID: " sid
    read -p "请输入偷的域名 (SNI): " sni
    uuid=$(sing-box generate uuid)

    # 确保基础结构存在
    [ ! -s "$CONFIG_FILE" ] && echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"

    # 生成入站配置
    new_inbound=$(jq -n --arg uuid "$uuid" --arg priv "$priv_key" --arg sid "$sid" --arg sni "$sni" \
        '{"type":"vless","tag":"vless-main-in","listen":"::","listen_port":443,"users":[{"name":"direct-user","uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}')
    
    # 【核心修改】只定义 auth_user 且必须为数组，加上 action: route
    direct_rule=$(jq -n '{"auth_user":["direct-user"],"action":"route","outbound":"direct"}')

    content=$(cat "$CONFIG_FILE")
    updated_json=$(echo "$content" | jq --argjson in "$new_inbound" --argjson rule "$direct_rule" '
        (if type == "object" then . else {} end) |
        # 更新入站
        .inbounds = ([.inbounds[]? | select(.tag != "vless-main-in")] + [$in]) |
        # 【清理关键】删除所有旧的包含 "user" 或 "auth_user" 的直连规则，只添加唯一的数组格式 auth_user 规则
        .route.rules = ([$rule] + [.route.rules[]? | select(.auth_user != ["direct-user"] and .user != "direct-user" and .user != ["direct-user"])]) |
        .outbounds = (.outbounds // [{"type":"direct","tag":"direct"}]) |
        .log = (.log // {"level":"info"})
    ')

    if [ -n "$updated_json" ]; then
        echo "$updated_json" > "$CONFIG_FILE"
        systemctl restart sing-box
        echo -e "${GREEN}主入站已成功配置！${NC}"
        echo -e "生成 UUID: ${YELLOW}$uuid${NC}"
    fi
    read -p "按回车返回..." res
}

# 3. 添加/更新中转
add_relay_node() {
    if ! jq -e '.inbounds[]? | select(.tag == "vless-main-in")' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}错误：请先执行选项 2 建立主入站${NC}"; sleep 2; return
    fi
    read -p "1. 落地标识: " node_name
    read -p "2. 落地 IP: " remote_ip
    read -p "3. 落地 UUID: " remote_uuid
    read -p "4. 落地 SNI: " sni
    read -p "5. 落地 Public_Key: " pub_key
    read -p "6. 落地 Short_ID: " sid
    
    relay_client_uuid=$(sing-box generate uuid)
    user_name="relay-$node_name"
    out_tag="out-to-$node_name"

    new_user=$(jq -n --arg name "$user_name" --arg uuid "$relay_client_uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')
    new_out=$(jq -n --arg tag "$out_tag" --arg addr "$remote_ip" --arg uuid "$remote_uuid" --arg sni "$sni" --arg pub "$pub_key" --arg sid "$sid" \
        '{"type":"vless","tag":$tag,"server":$addr,"server_port":443,"uuid":$uuid,"flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":$sni,"utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":$pub,"short_id":$sid}}}')
    new_rule=$(jq -n --arg user "$user_name" --arg out "$out_tag" '{"auth_user":[$user],"action":"route","outbound":$out}')

    content=$(cat "$CONFIG_FILE")
    updated_json=$(echo "$content" | jq --arg user_name "$user_name" --arg out_tag "$out_tag" --argjson user "$new_user" --argjson out "$new_out" --argjson rule "$new_rule" '
        (.inbounds[] | select(.tag == "vless-main-in").users) |= (del(.[] | select(.name == $user_name)) + [$user]) |
        .outbounds = ([.outbounds[]? | select(.tag != $out_tag)] + [$out]) |
        .route.rules = ([$rule] + [.route.rules[]? | select(.auth_user != [$user_name])])
    ')

    echo "$updated_json" > "$CONFIG_FILE" && systemctl restart sing-box
    echo -e "${GREEN}中转 [$node_name] 已配置。${NC}"
    read -p "按回车返回..."
}

# 4. 列出节点 (节点名称精简版)
list_nodes() {
    clear
    local has_users=$(jq '.inbounds[].users? // empty' "$CONFIG_FILE")
    if [ -z "$has_users" ]; then
        echo -e "${RED}配置文件中无节点。${NC}"; read -p "回车返回..." && return
    fi

    read -p "请输入 Reality Public_Key: " input_pub_key
    local pub_key=${input_pub_key:-"你的公钥"}
    local hostname=$(hostname)
    local my_ip=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org || echo "你的IP")
    
    # 提取公共入站参数
    local port=$(jq -r '.inbounds[0].listen_port' "$CONFIG_FILE")
    local sni=$(jq -r '.inbounds[0].tls.server_name' "$CONFIG_FILE")
    local sid=$(jq -r '.inbounds[0].tls.reality.short_id[0] // ""' "$CONFIG_FILE")

    echo -e "\n${GREEN}--- 节点列表 ---${NC}"
    
    local users_json=$(jq -c '.inbounds[].users[]' "$CONFIG_FILE")
    
    while IFS= read -r user_item; do
        [ -z "$user_item" ] && continue
        
        local name=$(echo "$user_item" | jq -r '.name')
        local uuid=$(echo "$user_item" | jq -r '.uuid')
        
        # --- 节点名称调整逻辑 ---
        local display_name=""
        if [[ "$name" == "direct-user" ]]; then
            display_name="${hostname}"  # 直连直接显示主机名 (如 us02)
        else
            local pure_name=${name#relay-}
            display_name="${hostname}-to-${pure_name}" # 中转显示 (如 us02-to-az-jp)
        fi

        echo -e "\n${YELLOW}--------------------------------------${NC}"
        echo -e "${CYAN}节点名称: ${NC}$display_name"

        # 1. Clash Meta / Mihomo
        echo -e "\n${GREEN}[Clash Meta / Mihomo]${NC}"
        echo "- {name: $display_name, type: vless, server: $my_ip, port: $port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $sni, reality-opts: {public-key: $pub_key, short-id: '$sid'}, client-fingerprint: chrome}"
        
        # 2. Quantumult X
        echo -e "\n${GREEN}[Quantumult X]${NC}"
        echo "vless=$my_ip:$port, method=none, password=$uuid, obfs=over-tls, obfs-host=$sni, reality-base64-pubkey=$pub_key, reality-hex-shortid=$sid, vless-flow=xtls-rprx-vision, tag=$display_name"

    done <<< "$users_json"

    echo -e "\n${YELLOW}--------------------------------------${NC}"
    read -p "按回车返回主菜单..." res
}

# 5. 删除节点
delete_node() {
    clear
    local nodes=$(jq -r '.inbounds[].users[]?.name' "$CONFIG_FILE" | grep "relay-")
    [ -z "$nodes" ] && echo "无中转节点" && sleep 1 && return
    echo "$nodes" | sed 's/relay-//g'
    read -p "输入标识删除: " target
    [ -z "$target" ] && return
    user_tag="relay-$target"
    out_tag="out-to-$target"
    updated_json=$(jq --arg user "$user_tag" --arg out "$out_tag" '
        (.inbounds[] | select(.tag == "vless-main-in").users) |= del(.[] | select(.name == $user)) |
        .outbounds |= del(.[] | select(.tag == $out)) |
        .route.rules |= del(.[] | select(.auth_user == [$user]))
    ' "$CONFIG_FILE")
    echo "$updated_json" > "$CONFIG_FILE" && systemctl restart sing-box
    read -p "已删除。"
}

init_env
while true; do
    show_menu
    case $opt in
        1) if lsof -i:443; then echo "占用"; else echo "空闲"; fi; read -p ".." ;;
        2) add_direct_node ;; 3) add_relay_node ;; 4) list_nodes ;; 5) delete_node ;; q) exit 0 ;;
    esac
done
