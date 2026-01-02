#!/bin/bash

# ====================================================
# Project: Sing-box 管理脚本 (Reality + 传统 SS-AES-128-GCM)
# Logic: 保持 UUID 持久化，中转使用纯 AES-128-GCM 加密
# ====================================================

CONFIG_FILE="/etc/sing-box/config.json"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

init_env() {
    if ! command -v jq &> /dev/null; then
        apt-get update && apt-get install -y jq || yum install -y jq
    fi
    if [ ! -s "$CONFIG_FILE" ] || ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}' > "$CONFIG_FILE"
    fi
}

show_menu() {
    clear
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}    Sing-box 智能管理 (VLESS + SS-AES-GCM)    ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo " 1. 检查端口占用"
    echo " 2. 【本机配置】配置 Reality + SS-AES-GCM 入站"
    echo " 3. 【添加中转】连接落地机 (使用 SS-AES-GCM 隧道)"
    echo " 4. 列出节点配置 (含 QX/Clash)"
    echo " 5. 删除指定节点"
    echo " q. 退出"
    echo -e "${GREEN}----------------------------------------------${NC}"
    read -p "请输入选项: " opt
}

# 2. 本机服务配置 (使用传统 aes-128-gcm)
add_local_services() {
    echo -e "${YELLOW}--- 配置本机入站服务 ---${NC}"
    has_vless=$(jq -r '.inbounds[]? | select(.tag == "vless-main-in") | .tag' "$CONFIG_FILE")
    
    echo -e "${CYAN}配置 Shadowsocks (aes-128-gcm) 端口 8080...${NC}"
    read -p "请输入你的 SS 密码: " ss_key
    [ -z "$ss_key" ] && echo "密码不能为空" && return

    # 构建传统 SS 入站对象
    in_ss=$(jq -n --arg key "$ss_key" '{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":8080,"method":"aes-128-gcm","password":$key}')

    if [ -n "$has_vless" ]; then
        echo -e "${GREEN}检测到 Reality 入站已存在，仅更新 SS 配置...${NC}"
        updated_json=$(jq --argjson new_ss "$in_ss" '.inbounds = ([.inbounds[]? | select(.tag != "ss-in")] + [$new_ss])' "$CONFIG_FILE")
    else
        echo -e "${RED}未检测到主节点，开始全量配置...${NC}"
        read -p "Reality Private_Key: " priv_key
        read -p "Reality Short_ID: " sid
        read -p "SNI (域名): " sni
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
    echo -e "${GREEN}配置已保存并重启！${NC}"
    read -p "回车返回..."
}

# 3. 添加中转 (使用传统 aes-128-gcm & 保留 UUID)
add_relay_node() {
    if ! jq -e '.inbounds[]? | select(.tag == "vless-main-in")' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}请先执行选项 2。${NC}"; sleep 2; return
    fi
    
    read -p "1. 落地机标识 (如 sg02): " node_name
    [ -z "$node_name" ] && return
    read -p "2. 落地机 IP 地址: " remote_ip
    read -p "3. 落地机 SS (aes-128-gcm) 密码: " remote_key
    
    user_name="relay-$node_name"
    out_tag="out-to-$node_name"

    # 提取原有 UUID
    old_uuid=$(jq -r --arg name "$user_name" '.inbounds[] | select(.tag == "vless-main-in") | .users[]? | select(.name == $name) | .uuid' "$CONFIG_FILE")

    if [ -n "$old_uuid" ] && [ "$old_uuid" != "null" ]; then
        echo -e "${GREEN}继承原有 UUID: $old_uuid${NC}"
        relay_uuid="$old_uuid"
    else
        relay_uuid=$(sing-box generate uuid)
    fi

    new_user=$(jq -n --arg name "$user_name" --arg uuid "$relay_uuid" '{"name":$name,"uuid":$uuid,"flow":"xtls-rprx-vision"}')
    # 强制使用 aes-128-gcm
    new_out=$(jq -n --arg tag "$out_tag" --arg addr "$remote_ip" --arg key "$remote_key" \
        '{"type":"shadowsocks","tag":$tag,"server":$addr,"server_port":8080,"method":"aes-128-gcm","password":$key}')
    new_rule=$(jq -n --arg user "$user_name" --arg out "$out_tag" '{"auth_user":[$user],"action":"route","outbound":$out}')

    updated_json=$(jq --arg user_name "$user_name" --arg out_tag "$out_tag" --argjson user "$new_user" --argjson out "$new_out" --argjson rule "$new_rule" '
        (.inbounds[] | select(.tag == "vless-main-in").users) |= (del(.[] | select(.name == $user_name)) + [$user]) |
        .outbounds = ([.outbounds[]? | select(.tag != $out_tag)] + [$out]) |
        .route.rules = ([$rule] + [.route.rules[]? | select(.auth_user != [$user_name])])
    ' "$CONFIG_FILE")

    echo "$updated_json" > "$CONFIG_FILE" && systemctl restart sing-box
    echo -e "${GREEN}中转节点已更新，UUID 已保持。${NC}"
    read -p "回车返回..."
}

# 4. 列出配置 (包含 Clash Meta 和 QX，修正节点命名逻辑)
list_nodes() {
    clear
    local has_users=$(jq '.inbounds[]? | select(.tag=="vless-main-in") | .users? // empty' "$CONFIG_FILE")
    if [ -z "$has_users" ]; then 
        echo -e "${RED}未发现任何 VLESS 用户配置。${NC}"
        read -p "按回车返回..." && return
    fi

    echo -e "${CYAN}提示：QX 和 Clash 需要 Reality 公钥才能生成完整配置。${NC}"
    read -p "请输入 Reality Public_Key (直接回车使用占位符): " pub_key
    pub_key=${pub_key:-"YOUR_PUBLIC_KEY"}
    
    local hostname=$(hostname)
    local my_ip=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org || echo "你的IP")
    
    # 提取公共入站参数
    local v_port=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .listen_port' "$CONFIG_FILE")
    local v_sni=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .tls.server_name' "$CONFIG_FILE")
    local v_sid=$(jq -r '.inbounds[] | select(.tag=="vless-main-in") | .tls.reality.short_id[0] // ""' "$CONFIG_FILE")

    echo -e "\n${GREEN}=== 节点列表 (Reality 终端入口) ===${NC}"
    
    # 获取 VLESS 入站下的所有用户
    local users_json=$(jq -c '.inbounds[] | select(.tag=="vless-main-in") | .users[]' "$CONFIG_FILE")
    
    while IFS= read -r user_item; do
        [ -z "$user_item" ] && continue
        
        local name=$(echo "$user_item" | jq -r '.name')
        local uuid=$(echo "$user_item" | jq -r '.uuid')
        
        # --- 核心命名逻辑修正 ---
        local dname=""
        if [[ "$name" == "direct-user" ]]; then
            dname="${hostname}-direct"
        else
            # 格式：本机名字-relay-sg01
            dname="${hostname}-${name}"
        fi

        echo -e "\n${YELLOW}--------------------------------------${NC}"
        echo -e "${CYAN}节点名称: ${NC}$dname"

        # 1. Clash Meta / Mihomo 格式
        echo -e "\n${GREEN}[Clash Meta / Mihomo]${NC}"
        echo "- {name: $dname, type: vless, server: $my_ip, port: $v_port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: $v_sni, reality-opts: {public-key: $pub_key, short-id: '$v_sid'}, client-fingerprint: chrome}"
        
        # 2. Quantumult X 格式
        echo -e "\n${GREEN}[Quantumult X]${NC}"
        echo "vless=$my_ip:$v_port, method=none, password=$uuid, obfs=over-tls, obfs-host=$v_sni, reality-base64-pubkey=$pub_key, reality-hex-shortid=$v_sid, vless-flow=xtls-rprx-vision, tag=$dname"

    done <<< "$users_json"

    # --- 本机 SS (aes-128-gcm) 信息展示 ---
    local ss_port=$(jq -r '.inbounds[] | select(.tag=="ss-in") | .listen_port // empty' "$CONFIG_FILE")
    if [ -n "$ss_port" ]; then
        local ss_key=$(jq -r '.inbounds[] | select(.tag=="ss-in") | .password' "$CONFIG_FILE")
        echo -e "\n${YELLOW}======================================${NC}"
        echo -e "${CYAN}本机 SS 落地信息 (供其他中转机连接使用):${NC}"
        echo -e "加密方式: ${GREEN}aes-128-gcm${NC}"
        echo -e "端口: ${GREEN}$ss_port${NC}"
        echo -e "密码: ${GREEN}$ss_key${NC}"
    fi

    echo -e "\n${YELLOW}--------------------------------------${NC}"
    read -p "按回车返回主菜单..." res
}

# (其余删除和端口检查函数保持不变...)
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
}

init_env
while true; do
    show_menu
    case $opt in
        1) lsof -i:443; lsof -i:8080; read -p ".." ;;
        2) add_local_services ;;
        3) add_relay_node ;;
        4) list_nodes ;;
        5) delete_node ;;
        q) exit 0 ;;
    esac
done
