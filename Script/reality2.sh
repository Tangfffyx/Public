#!/bin/bash

# ====================================================
# Project: Sing-box 混合架构终极版 (智能覆盖)
# Logic: Reality(443) + SS2022(8080) / Auto-Detect
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
    # 确保文件存在且是合法的 JSON 对象
    if [ ! -s "$CONFIG_FILE" ] || ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}' > "$CONFIG_FILE"
    fi
}

show_menu() {
    clear
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}    Sing-box 智能管理 (VLESS + SS2022)       ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo " 1. 检查端口占用"
    echo " 2. 【本机配置】配置 Reality + SS2022 入站 (智能增量)"
    echo " 3. 【添加中转】连接落地机 (强制走 SS2022 隧道)"
    echo " 4. 列出所有节点 (Reality/SS/Relay)"
    echo " 5. 删除指定节点"
    echo " q. 退出"
    echo -e "${GREEN}----------------------------------------------${NC}"
    read -p "请输入选项: " opt
}

# 2. 智能配置本机服务 (密码由用户完全控制)
add_local_services() {
    echo -e "${YELLOW}--- 配置本机入站服务 ---${NC}"
    
    # 检测是否存在 VLESS 主入站
    has_vless=$(jq -r '.inbounds[]? | select(.tag == "vless-main-in") | .tag' "$CONFIG_FILE")
    
    # === SS-2022 密码处理 ===
    echo -e "${CYAN}准备配置 Shadowsocks-2022 (端口 8080)...${NC}"
    # 生成一个 16 字节 Base64 供参考，防止用户手头没有现成的
    suggest_key=$(openssl rand -base64 16)
    echo -e "${WHITE}参考 Key (16字节): ${GREEN}$suggest_key${NC}"
    
    # 强制用户输入或确认
    read -p "请输入你的 SS2022 密码 (直接回车则使用上方参考值): " input_key
    ss_key=${input_key:-$suggest_key}
    ss_port=8080

    # 构建 SS 入站对象
    in_ss=$(jq -n --arg key "$ss_key" --argjson port "$ss_port" \
        '{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":$port,"method":"2022-blake3-aes-128-gcm","password":$key}')

    if [ -n "$has_vless" ]; then
        echo -e "${GREEN}检测到 Reality 入站已存在，保持原配置不变。${NC}"
        echo -e "${YELLOW}正在更新/覆盖本机 SS-2022 节点...${NC}"
        
        updated_json=$(jq --argjson new_ss "$in_ss" '
            .inbounds = ([.inbounds[]? | select(.tag != "ss-in")] + [$new_ss])
        ' "$CONFIG_FILE")
    else
        echo -e "${RED}未检测到主节点，开始全量配置 (Reality + SS)...${NC}"
        read -p "请输入 Reality Private_Key: " priv_key
        read -p "请输入 Reality Short_ID: " sid
        read -p "请输入 SNI (域名): " sni
        uuid=$(sing-box generate uuid)

        in_reality=$(jq -n --arg uuid "$uuid" --arg priv "$priv_key" --arg sid "$sid" --arg sni "$sni" \
            '{"type":"vless","tag":"vless-main-in","listen":"::","listen_port":443,"users":[{"name":"direct-user","uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}')
        
        direct_rule=$(jq -n '{"auth_user":["direct-user"],"action":"route","outbound":"direct"}')

        updated_json=$(jq --argjson new_vless "$in_reality" --argjson new_ss "$in_ss" --argjson rule "$direct_rule" '
            .inbounds = ([.inbounds[]? | select(.tag != "vless-main-in" and .tag != "ss-in")] + [$new_vless, $new_ss]) |
            .route.rules = ([$rule] + [.route.rules[]? | select(.auth_user != ["direct-user"])]) |
            .outbounds = (.outbounds // [{"type":"direct","tag":"direct"}])
        ' "$CONFIG_FILE")
    fi

    echo "$updated_json" > "$CONFIG_FILE" && systemctl restart sing-box
    echo -e "${GREEN}配置已保存并重启服务！${NC}"
    echo -e "当前 SS-2022 密码: ${YELLOW}$ss_key${NC}"
    read -p "回车返回..."
}

# 3. 添加/覆盖 中转 (保持 UUID 持久化)
add_relay_node() {
    if ! jq -e '.inbounds[]? | select(.tag == "vless-main-in")' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}错误：本机 Reality 入口不存在，请先执行选项 2。${NC}"; sleep 2; return
    fi
    
    echo -e "${CYAN}--- 添加/覆盖 中转落地节点 ---${NC}"
    read -p "1. 落地机标识 (如 us01, sg02): " node_name
    [ -z "$node_name" ] && return
    
    read -p "2. 落地机 IP 地址: " remote_ip
    read -p "3. 落地机 SS2022 密码: " remote_key
    remote_port=8080
    
    user_name="relay-$node_name"
    out_tag="out-to-$node_name"

    # 【核心改进：尝试提取原有 UUID】
    old_uuid=$(jq -r --arg name "$user_name" '.inbounds[] | select(.tag == "vless-main-in") | .users[]? | select(.name == $name) | .uuid' "$CONFIG_FILE")

    if [ -n "$old_uuid" ] && [ "$old_uuid" != "null" ]; then
        echo -e "${GREEN}检测到原有用户，将保留 UUID: ${YELLOW}$old_uuid${NC}"
        relay_client_uuid="$old_uuid"
    else
        echo -e "${CYAN}新建节点，正在生成新 UUID...${NC}"
        relay_client_uuid=$(sing-box generate uuid)
    fi

    # 1. 构造新用户对象
    new_user=$(jq -n --arg name "$user_name" --arg uuid "$relay_client_uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')

    # 2. 构造 SS-2022 出站对象
    new_out=$(jq -n --arg tag "$out_tag" --arg addr "$remote_ip" --argjson port "$remote_port" --arg key "$remote_key" \
        '{"type":"shadowsocks","tag":$tag,"server":$addr,"server_port":$port,"method":"2022-blake3-aes-128-gcm","password":$key}')

    # 3. 构造路由规则
    new_rule=$(jq -n --arg user "$user_name" --arg out "$out_tag" '{"auth_user":[$user],"action":"route","outbound":$out}')

    echo -e "${YELLOW}正在应用配置...${NC}"

    content=$(cat "$CONFIG_FILE")
    updated_json=$(echo "$content" | jq --arg user_name "$user_name" --arg out_tag "$out_tag" --argjson user "$new_user" --argjson out "$new_out" --argjson rule "$new_rule" '
        # 覆盖用户
        (.inbounds[] | select(.tag == "vless-main-in").users) |= (del(.[] | select(.name == $user_name)) + [$user]) |
        # 覆盖出站
        .outbounds = ([.outbounds[]? | select(.tag != $out_tag)] + [$out]) |
        # 覆盖规则
        .route.rules = ([$rule] + [.route.rules[]? | select(.auth_user != [$user_name])])
    ')

    echo "$updated_json" > "$CONFIG_FILE" && systemctl restart sing-box
    echo -e "${GREEN}中转节点 [$node_name] 更新成功！${NC}"
    echo -e "UUID 状态: ${YELLOW}$relay_client_uuid (未变更)${NC}"
    read -p "回车返回..."
}

# 4. 列出节点 (含 Clash Meta 和 Quantumult X)
list_nodes() {
    clear
    local has_users=$(jq '.inbounds[]? | select(.tag=="vless-main-in") | .users? // empty' "$CONFIG_FILE")
    if [ -z "$has_users" ]; then 
        echo -e "${RED}未发现任何 VLESS 用户配置。${NC}"
        read -p "按回车返回..." && return
    fi

    echo -e "${CYAN}提示：QX 和 Clash 需要公钥才能生成完整配置。${NC}"
    read -p "请输入 Reality Public_Key: " pub_key
    pub_key=${pub_key:-"YOUR_PUBLIC_KEY"}
    
    local hostname=$(hostname)
    local my_ip=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org || echo "你的IP")
    
    # 提取公共入站参数
    local v_port=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .listen_port' "$CONFIG_FILE")
    local v_sni=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .tls.server_name' "$CONFIG_FILE")
    local v_sid=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .tls.reality.short_id[0] // ""' "$CONFIG_FILE")

    echo -e "\n${GREEN}=== 节点列表 (Reality) ===${NC}"
    
    # 获取 VLESS 入站下的所有用户
    local users_json=$(jq -c '.inbounds[] | select(.tag=="vless-main-in") | .users[]' "$CONFIG_FILE")
    
    while IFS= read -r user_item; do
        [ -z "$user_item" ] && continue
        
        local name=$(echo "$user_item" | jq -r '.name')
        local uuid=$(echo "$user_item" | jq -r '.uuid')
        
        # 确定显示名称
        local dname=""
        if [[ "$name" == "direct-user" ]]; then
            dname="${hostname}"
        else
            dname="${hostname}-to-${name#relay-}"
        fi

        echo -e "\n${YELLOW}--------------------------------------${NC}"
        echo -e "${CYAN}节点: ${NC}$dname"

        # 1. Clash Meta 格式
        echo -e "\n${GREEN}[Clash Meta / Mihomo]${NC}"
        echo "- {name: $dname, type: vless, server: $my_ip, port: $v_port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $pub_key, short-id: '$v_sid'}, client-fingerprint: chrome}"
        
        # 2. Quantumult X 格式 (补全部分)
        echo -e "\n${GREEN}[Quantumult X]${NC}"
        echo "vless=$my_ip:$v_port, method=none, password=$uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$pub_key, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=$dname"

    done <<< "$users_json"

    # --- 本机 SS2022 信息展示 ---
    local ss_port=$(jq -r '.inbounds[] | select(.tag=="ss-in") | .listen_port // empty' "$CONFIG_FILE")
    if [ -n "$ss_port" ]; then
        local ss_key=$(jq -r '.inbounds[] | select(.tag=="ss-in") | .password' "$CONFIG_FILE")
        echo -e "\n${YELLOW}--------------------------------------${NC}"
        echo -e "${CYAN}本机 SS2022 落地入口 (仅用于中转连接，非客户端配置):${NC}"
        echo -e "端口: ${GREEN}$ss_port${NC}"
        echo -e "密码: ${GREEN}$ss_key${NC}"
    fi

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
        .outbounds = ([.outbounds[]? | select(.tag != $out)] ) |
        .route.rules = [.route.rules[]? | select(.auth_user != [$user])]
    ' "$CONFIG_FILE")
    echo "$updated_json" > "$CONFIG_FILE" && systemctl restart sing-box
    read -p "已删除。"
}

# 检查端口
check_port() {
    lsof -i:443 && echo "443 占用" || echo "443 空闲"
    lsof -i:8080 && echo "8080 占用" || echo "8080 空闲"
    read -p ".."
}

init_env
while true; do
    show_menu
    case $opt in
        1) check_port ;; 2) add_local_services ;; 3) add_relay_node ;;
        4) list_nodes ;; 5) delete_node ;; q) exit 0 ;;
    esac
done
