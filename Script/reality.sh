#!/bin/bash

# 变量定义
CONFIG_FILE="/etc/sing-box/config.json"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 初始化环境
init_env() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}检测到未安装 jq，正在安装...${NC}"
        apt-get update && apt-get install -y jq || yum install -y jq
    fi

    # 核心修复：如果文件不存在 OR 文件内容为空 OR 文件内容不是合法的 JSON
    if [ ! -s "$CONFIG_FILE" ] || ! jq . "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}配置文件为空或非法，正在初始化基础结构...${NC}"
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
    echo " 2. 【直连/落地机】配置 443 主入站 (自动生成 UUID)"
    echo " 3. 【中转机】添加落地节点配置 (手动填写落地 UUID)"
    echo " 4. 列出当前节点配置 (Clash/QX 格式)"
    echo " q. 退出脚本"
    echo -e "${GREEN}--------------------------------------${NC}"
    read -p "请输入选项: " opt
}

# 1. 端口检查
check_port() {
    echo -e "${YELLOW}正在扫描 443 端口...${NC}"
    if lsof -i:443 > /dev/null; then
        echo -e "${RED}警告：443 端口已被占用！${NC}"
        lsof -i:443
    else
        echo -e "${GREEN}恭喜：443 端口目前空闲。${NC}"
    fi
    read -p "按回车键返回..."
}

# 2. 基础入站配置
add_direct_node() {
    echo -e "${YELLOW}开始配置 443 端口 Reality 主入站...${NC}"
    read -p "请输入 Private_Key: " priv_key
    read -p "请输入 Short_ID: " sid
    read -p "请输入偷的域名 (SNI): " sni
    
    uuid=$(sing-box generate uuid)

    new_inbound=$(jq -n --arg uuid "$uuid" --arg priv "$priv_key" --arg sid "$sid" --arg sni "$sni" \
        '{
            "type": "vless",
            "tag": "vless-main-in",
            "listen": "::",
            "listen_port": 443,
            "users": [{"name": "direct-user", "uuid": $uuid, "flow": "xtls-rprx-vision"}],
            "tls": {
                "enabled": true,
                "server_name": $sni,
                "reality": {
                    "enabled": true,
                    "handshake": {"server": $sni, "server_port": 443},
                    "private_key": $priv,
                    "short_id": [$sid]
                }
            }
        }')

    direct_rule=$(jq -n '{"user": ["direct-user"], "outbound": "direct"}')

    tmp=$(mktemp)
    jq --argjson in "$new_inbound" --argjson rule "$direct_rule" \
       'del(.inbounds[]? | select(.tag == "vless-main-in")) | .inbounds += [$in] | 
        if (.route.rules | map(.user == ["direct-user"]) | any | not) then .route.rules += [$rule] else . end' \
       "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    systemctl restart sing-box
    echo -e "${GREEN}直连节点配置成功！${NC}"
    echo -e "直连 UUID: ${YELLOW}$uuid${NC}"
    read -p "按回车返回主菜单..." res
}

# 3. 中转节点配置
add_relay_node() {
    if ! jq -e '.inbounds[]? | select(.tag == "vless-main-in")' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}错误：必须先运行选项 2 建立主入站！${NC}"
        sleep 2; return
    fi

    echo -e "${YELLOW}开始添加中转落地配置...${NC}"
    read -p "1. 落地机标识名称: " node_name
    read -p "2. 落地机 IP 地址: " remote_ip
    read -p "3. 落地机 UUID: " remote_uuid
    read -p "4. 落地机域名 (SNI): " sni
    read -p "5. 落地机 Public_Key: " pub_key
    read -p "6. 落地机 Short_ID: " sid
    
    relay_client_uuid=$(sing-box generate uuid)
    user_name="relay-$node_name"
    out_tag="out-to-$node_name"

    new_user=$(jq -n --arg name "$user_name" --arg uuid "$relay_client_uuid" '{"name": $name, "uuid": $uuid, "flow": "xtls-rprx-vision"}')
    new_out=$(jq -n --arg tag "$out_tag" --arg addr "$remote_ip" --arg uuid "$remote_uuid" --arg sni "$sni" --arg pub "$pub_key" --arg sid "$sid" \
        '{"type": "vless", "tag": $tag, "server": $addr, "server_port": 443, "uuid": $uuid, "flow": "xtls-rprx-vision", "tls": {"enabled": true, "server_name": $sni, "utls": {"enabled": true, "fingerprint": "chrome"}, "reality": {"enabled": true, "public_key": $pub, "short_id": $sid}}}')
    new_rule=$(jq -n --arg user "$user_name" --arg out "$out_tag" '{"user": [$user], "outbound": $out}')

    tmp=$(mktemp)
    jq --argjson user "$new_user" --argjson out "$new_out" --argjson rule "$new_rule" \
       '(.inbounds[] | select(.tag == "vless-main-in").users) += [$user] | 
        .outbounds += [$out] | 
        .route.rules = [$rule] + .route.rules' \
       "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    systemctl restart sing-box
    echo -e "${GREEN}中转节点 [$node_name] 已添加！${NC}"
    echo -e "手机连接中转机使用的 UUID: ${YELLOW}$relay_client_uuid${NC}"
    read -p "按回车返回主菜单..." res
}

# 4. 列出节点 (强制获取 IPv4)
list_nodes() {
    if ! jq -e '.inbounds[]? | select(.tag == "vless-main-in")' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}未发现主入站配置！${NC}"; sleep 1; return
    fi
    clear
    echo -e "${YELLOW}正在获取 IPv4 地址...${NC}"
    local port=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .listen_port' "$CONFIG_FILE")
    local sni=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .tls.server_name' "$CONFIG_FILE")
    local sid=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .tls.reality.short_id[0]' "$CONFIG_FILE")
    
    # 使用 curl -4 强制请求 IPv4 地址
    local my_ip=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org || echo "你的IPv4地址")

    echo -e "${GREEN}--- 节点配置列表 (IPv4) ---${NC}"
    jq -c '.inbounds[] | select(.tag=="vless-main-in") | .users[]' "$CONFIG_FILE" | while read -r user; do
        local name=$(echo $user | jq -r '.name')
        local uuid=$(echo $user | jq -r '.uuid')
        echo -e "\n${CYAN}用户: $name${NC}"
        echo -e "${YELLOW}[Clash]${NC}"
        echo "- {name: $name, type: vless, server: $my_ip, port: $port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $sni, reality-opts: {public-key: 你的公钥, short-id: $sid}, client-fingerprint: chrome}"
        echo -e "${YELLOW}[QX]${NC}"
        echo "vless=$my_ip:$port, method=none, password=$uuid, obfs=over-tls, obfs-host=$sni, reality-base64-pubkey=你的公钥, reality-hex-shortid=$sid, vless-flow=xtls-rprx-vision, tag=$name"
    done
    read -p "按回车返回..." res
}

# 执行
init_env
while true; do
    show_menu
    case $opt in
        1) check_port ;;
        2) add_direct_node ;;
        3) add_relay_node ;;
        4) list_nodes ;;
        q) exit 0 ;;
        *) echo "无效输入"; sleep 1 ;;
    esac
done
