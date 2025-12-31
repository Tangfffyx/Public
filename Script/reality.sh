#!/bin/bash

CONFIG_FILE="/etc/sing-box/config.json"

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 初始化环境
init_env() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}正在安装 jq...${NC}"
        apt-get update && apt-get install -y jq || yum install -y jq
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p /etc/sing-box
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
    fi
}

show_menu() {
    clear
    echo -e "${GREEN}===============================${NC}"
    echo -e "${GREEN}   Sing-box Reality 自动化脚本  ${NC}"
    echo -e "${GREEN}===============================${NC}"
    echo "1. 检查 443 端口占用"
    echo "2. 【直连/落地机】配置 443 主入站"
    echo "3. 【中转机】添加落地节点配置"
    echo "q. 退出"
    echo "-------------------------------"
    read -p "请选择操作: " opt
}

check_port() {
    echo -e "${YELLOW}检查 443 端口占用情况...${NC}"
    if lsof -i:443 > /dev/null; then
        echo -e "${RED}443 端口已被以下进程占用：${NC}"
        lsof -i:443
    else
        echo -e "${GREEN}恭喜！443 端口没有被占用！${NC}"
    fi
    read -p "按回车键返回主菜单..."
}

# 选项 2：配置直连/主入站
add_direct_node() {
    echo -e "${YELLOW}--- 配置基础直连入站 ---${NC}"
    read -p "请输入 Private_Key: " priv_key
    read -p "请输入 Short_ID: " sid
    read -p "请输入想偷的域名 (SNI): " sni
    
    # 只有选项 2 自动生成 UUID
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
    echo -e "${GREEN}配置成功！${NC}"
    echo -e "直连 UUID: ${YELLOW}$uuid${NC}"
    read -p "按 0 返回主菜单: " res
}

# 选项 3：添加中转
add_relay_node() {
    if ! jq -e '.inbounds[]? | select(.tag == "vless-main-in")' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}错误：请先运行选项 2 建立主入站！${NC}"
        sleep 2; return
    fi

    echo -e "${YELLOW}--- 添加中转节点配置 ---${NC}"
    read -p "1. 落地机名称 (如 us01): " node_name
    read -p "2. 落地机 IP: " remote_ip
    read -p "3. 落地机 UUID (手动填写落地机生成的那个): " remote_uuid
    read -p "4. 落地机域名 (SNI): " sni
    read -p "5. 落地机 Public_Key: " pub_key
    read -p "6. 落地机 Short_ID: " sid
    
    # 自动生成给客户端连接中转机用的新 UUID
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
    echo -e "${GREEN}中转节点 [$node_name] 配置成功！${NC}"
    echo -e "手机连接中转机应使用的 UUID: ${YELLOW}$relay_client_uuid${NC}"
    read -p "按 0 返回主菜单: " res
}

# --- 启动脚本 ---
init_env
while true; do
    show_menu
    case $opt in
        1) check_port ;;
        2) add_direct_node ;;
        3) add_relay_node ;;
        q) exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
