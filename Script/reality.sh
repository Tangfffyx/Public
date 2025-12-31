#!/bin/bash

# ====================================================
# Project: Sing-box Reality 一键管理脚本
# Author: Tangfffyx
# Function: 自动化配置 Reality 入站、中转出站及路由
# ====================================================

CONFIG_FILE="/etc/sing-box/config.json"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 初始化环境：安装依赖并校验配置文件结构
init_env() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}检测到未安装 jq，正在安装...${NC}"
        apt-get update && apt-get install -y jq || yum install -y jq
    fi
    # 物理校验：如果文件不是合法的 JSON 对象，则强制重置
    if [ ! -s "$CONFIG_FILE" ] || ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}配置文件为空或损坏，初始化标准结构...${NC}"
        mkdir -p /etc/sing-box
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
    fi
}

show_menu() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}    Sing-box Reality 自动化管理脚本     ${NC}"
    echo -e "${GREEN}    GitHub: Tangfffyx                 ${NC}"
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

# 1. 端口检查
check_port() {
    echo -e "${YELLOW}正在扫描 443 端口占用情况...${NC}"
    if lsof -i:443 > /dev/null; then
        echo -e "${RED}警告：443 端口已被占用！${NC}"
        lsof -i:443
    else
        echo -e "${GREEN}恭喜：443 端口目前空闲。${NC}"
    fi
    read -p "按回车键返回..."
}

# 2. 基础入站配置 (覆盖式)
add_direct_node() {
    echo -e "${YELLOW}开始配置 443 端口 Reality 主入站...${NC}"
    read -p "请输入 Reality Private_Key: " priv_key
    read -p "请输入 Reality Short_ID: " sid
    read -p "请输入偷的域名 (SNI): " sni
    uuid=$(sing-box generate uuid)

    new_inbound=$(jq -n --arg uuid "$uuid" --arg priv "$priv_key" --arg sid "$sid" --arg sni "$sni" \
        '{"type":"vless","tag":"vless-main-in","listen":"::","listen_port":443,"users":[{"name":"direct-user","uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}')
    
    direct_rule=$(jq -n '{"user":["direct-user"],"outbound":"direct"}')

    content=$(cat "$CONFIG_FILE")
    # 再次确保内容为对象，防止 jq 报错
    if ! echo "$content" | jq -e 'type == "object"' >/dev/null 2>&1; then content='{}'; fi

    updated_json=$(echo "$content" | jq --argjson in "$new_inbound" --argjson rule "$direct_rule" '
        (if type == "object" then . else {} end) |
        .inbounds = ((.inbounds // []) | del(.[] | select(.tag == "vless-main-in")) + [$in]) |
        .route.rules = (([$rule] + (.route.rules // [])) | unique_by(.user)) |
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

# 3. 中转节点配置 (同名覆盖)
add_relay_node() {
    if ! jq -e '.inbounds[]? | select(.tag == "vless-main-in")' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}错误：必须先运行选项 2 建立主入站！${NC}"; sleep 2; return
    fi
    echo -e "${CYAN}添加中转，落地机标识只需输入如 'us02'${NC}"
    read -p "1. 落地机标识 (如 us02): " node_name
    read -p "2. 落地机 IP 地址: " remote_ip
    read -p "3. 落地机 UUID: " remote_uuid
    read -p "4. 落地机 SNI: " sni
    read -p "5. 落地机 Public_Key: " pub_key
    read -p "6. 落地机 Short_ID: " sid
    
    relay_client_uuid=$(sing-box generate uuid)
    user_name="relay-$node_name"
    out_tag="out-to-$node_name"

    new_user=$(jq -n --arg name "$user_name" --arg uuid "$relay_client_uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')
    new_out=$(jq -n --arg tag "$out_tag" --arg addr "$remote_ip" --arg uuid "$remote_uuid" --arg sni "$sni" --arg pub "$pub_key" --arg sid "$sid" \
        '{"type":"vless","tag":$tag,"server":$addr,"server_port":443,"uuid":$uuid,"flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":$sni,"utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":$pub,"short_id":$sid}}}')
    new_rule=$(jq -n --arg user "$user_name" --arg out "$out_tag" '{"user":[$user],"outbound":$out}')

    content=$(cat "$CONFIG_FILE")
    updated_json=$(echo "$content" | jq --arg user_name "$user_name" --arg out_tag "$out_tag" --argjson user "$new_user" --argjson out "$new_out" --argjson rule "$new_rule" '
        (if type == "object" then . else {} end) |
        (.inbounds[] | select(.tag == "vless-main-in").users) |= (del(.[] | select(.name == $user_name)) + [$user]) |
        .outbounds |= (del(.[] | select(.tag == $out_tag)) + [$out]) |
        .route.rules |= (del(.[] | select(.user == [$user_name])) | [$rule] + .)
    ')
    if [ -n "$updated_json" ]; then
        echo "$updated_json" > "$CONFIG_FILE"
        systemctl restart sing-box
        echo -e "${GREEN}中转节点 [$node_name] 已处理完成！${NC}"
    fi
    read -p "按回车返回..." res
}

# 4. 列出节点 (增强交互：支持动态填入公钥)
list_nodes() {
    if ! jq -e '.inbounds[]? | select(.tag == "vless-main-in")' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}未发现配置，请先执行选项 2！${NC}"; sleep 1; return
    fi
    clear

    # 新增：询问公钥
    echo -e "${CYAN}提示：为了生成完整的配置，建议输入公钥。${NC}"
    read -p "请输入 Reality Public_Key (直接回车则显示占位符): " input_pub_key
    
    # 设置默认值
    local pub_key=${input_pub_key:-"你的公钥"}
    
    local hostname=$(hostname)
    local port=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .listen_port' "$CONFIG_FILE")
    local sni=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .tls.server_name' "$CONFIG_FILE")
    local sid=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .tls.reality.short_id[0]' "$CONFIG_FILE")
    local my_ip=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org || echo "你的IPv4地址")

    echo -e "\n${GREEN}================ 配置信息 ==================${NC}"
    
    jq -c '.inbounds[] | select(.tag=="vless-main-in") | .users[]' "$CONFIG_FILE" | while read -r user; do
        local name=$(echo $user | jq -r '.name')
        local uuid=$(echo $user | jq -r '.uuid')
        
        if [ "$name" == "direct-user" ]; then
            local display_name="$hostname"
        else
            local display_name="${hostname}-to-${name#relay-}"
        fi

        echo -e "\n${CYAN}节点名称: $display_name${NC}"
        
        echo -e "${YELLOW}[Clash Meta / Mihomo]${NC}"
        echo "- {name: $display_name, type: vless, server: $my_ip, port: $port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $sni, reality-opts: {public-key: $pub_key, short-id: $sid}, client-fingerprint: chrome}"
        
        echo -e "${YELLOW}[Quantumult X]${NC}"
        echo "vless=$my_ip:$port, method=none, password=$uuid, obfs=over-tls, obfs-host=$sni, reality-base64-pubkey=$pub_key, reality-hex-shortid=$sid, vless-flow=xtls-rprx-vision, tag=$display_name"
    done
    
    echo -e "${GREEN}============================================${NC}"
    read -p "按回车返回主菜单..." res
}

# 5. 删除节点
delete_node() {
    clear
    echo -e "${YELLOW}--- 可删除的中转节点 ---${NC}"
    local nodes=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .users[].name' "$CONFIG_FILE" 2>/dev/null | grep "relay-")
    if [ -z "$nodes" ]; then
        echo -e "${RED}当前暂无中转节点。${NC}"; sleep 1; return
    fi
    echo "$nodes" | sed 's/relay-//g'
    echo -e "${GREEN}------------------------${NC}"
    read -p "输入要删除的名称: " target
    [ -z "$target" ] && return
    
    user_tag="relay-$target"
    out_tag="out-to-$target"
    content=$(cat "$CONFIG_FILE")
    updated_json=$(echo "$content" | jq --arg user "$user_tag" --arg out "$out_tag" '
        (.inbounds[] | select(.tag == "vless-main-in").users) |= del(.[] | select(.name == $user)) |
        .outbounds |= del(.[] | select(.tag == $out)) |
        .route.rules |= del(.[] | select(.user == [$user]))
    ')
    if [ -n "$updated_json" ]; then
        echo "$updated_json" > "$CONFIG_FILE"
        systemctl restart sing-box
        echo -e "${GREEN}节点 [$target] 已彻底清理。${NC}"
    fi
    read -p "按回车返回..." res
}

# 运行初始化
init_env

# 菜单循环
while true; do
    show_menu
    case $opt in
        1) check_port ;;
        2) add_direct_node ;;
        3) add_relay_node ;;
        4) list_nodes ;;
        5) delete_node ;;
        q) exit 0 ;;
        *) echo "无效输入"; sleep 1 ;;
    esac
done
