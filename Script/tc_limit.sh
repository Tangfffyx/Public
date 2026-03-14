#!/bin/bash

# 自动获取默认外网网卡
INTERFACE=$(ip route | awk '/default/ {print $5}' | head -n 1)

if [ -z "$INTERFACE" ]; then
    echo -e "\033[31m[错误] 无法自动检测到外网网卡，请检查网络设置。\033[0m"
    exit 1
fi

# 应用限速的核心函数
apply_limit() {
    local rate=$1
    # 先静默删除旧规则，再添加新规则
    tc qdisc del dev $INTERFACE root 2>/dev/null
    tc qdisc add dev $INTERFACE root tbf rate ${rate}mbit burst 128kbit latency 50ms
    echo -e "\n\033[32m[成功] 已将网卡 $INTERFACE 的出站带宽限制为 ${rate} Mbps！\033[0m"
}

clear

# 主交互循环
while true; do
    echo -e "\033[36m=========================================\033[0m"
    echo -e "       \033[1m网络出站带宽限速控制面板\033[0m       "
    echo -e "\033[36m=========================================\033[0m"
    echo -e "当前生效网卡: \033[33m$INTERFACE\033[0m"
    echo -e "\033[31m[注意] 本脚本配置的限速存在于内存中，重启服务器后失效！\033[0m"
    echo "-----------------------------------------"
    echo "  1. 限制速率为 40 Mbps"
    echo "  2. 限制速率为 60 Mbps"
    echo "  3. 限制速率为 80 Mbps"
    echo "  4. 限制速率为 100 Mbps"
    echo "  5. 解除所有限速 (恢复满速)"
    echo "  6. 查看当前限速状态"
    echo "  0. 退出面板"
    echo -e "\033[36m=========================================\033[0m"
    
    # 注意：这里添加了 </dev/tty，专门为了兼容远程 curl 执行时的交互输入
    read -p "请输入对应的数字 [0-6]: " choice </dev/tty

    case $choice in
        1) apply_limit 40 ;;
        2) apply_limit 60 ;;
        3) apply_limit 80 ;;
        4) apply_limit 100 ;;
        5)
            tc qdisc del dev $INTERFACE root 2>/dev/null
            echo -e "\n\033[32m[成功] 已解除网卡 $INTERFACE 的所有限速！\033[0m"
            ;;
        6)
            echo -e "\n\033[33m当前 $INTERFACE 的限速底层状态如下：\033[0m"
            tc qdisc show dev $INTERFACE
            ;;
        0)
            echo -e "\n退出面板。祝你使用愉快！\n"
            exit 0
            ;;
        *)
            echo -e "\n\033[31m[错误] 无效的输入，请输入 0-6 之间的数字。\033[0m"
            ;;
    esac
    
    echo ""
    read -p "按回车键继续..." </dev/tty
    clear
done
