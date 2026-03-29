#!/bin/bash
# Debian/Ubuntu 网络参数优化与 BBR 开启脚本
# 包含自动备份与一键恢复功能

# 定义路径变量
CONF_FILE="/etc/sysctl.d/99-z-network-optimize.conf"
BACKUP_DIR="/etc/sysctl.d/.network_backup"

# 强制 root 权限运行检测
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限运行此脚本 (例如: sudo bash $0)"
  exit 1
fi

# ==========================================
# 安装与优化逻辑
# ==========================================
install_optimize() {
    echo "🚀 开始部署网络优化参数..."

    # 1. 创建隐藏的备份目录
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi

    # 2. 隔离并备份潜在冲突文件 (99- 开头的文件)
    # 为什么要用 99-z？因为字典序中 z 排在最后，它必定会覆盖系统的 99-sysctl.conf
    for file in /etc/sysctl.d/99-*.conf; do
        if [ -f "$file" ] && [ "$file" != "$CONF_FILE" ]; then
            echo "📦 发现潜在冲突文件: $file，正在移至备份目录..."
            mv "$file" "$BACKUP_DIR/"
        fi
    done

    # 3. 写入终极配置
    echo "✍️ 正在写入独占优化配置到 $CONF_FILE ..."
    cat > "$CONF_FILE" << 'EOF'
# ==========================================
# Custom Network Optimization & BBR
# ==========================================
fs.file-max                     = 6815744
net.ipv4.tcp_max_syn_backlog    = 8192
net.core.somaxconn              = 8192
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_abort_on_overflow  = 1
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_no_metrics_save    = 1
net.ipv4.tcp_ecn                = 0
net.ipv4.tcp_frto               = 0
net.ipv4.tcp_mtu_probing        = 0
net.ipv4.tcp_rfc1337            = 1
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_fack               = 1
net.ipv4.tcp_window_scaling     = 1
net.ipv4.tcp_adv_win_scale      = 2
net.ipv4.tcp_moderate_rcvbuf    = 1
net.ipv4.tcp_fin_timeout        = 30
net.ipv4.tcp_rmem               = 4096 87380 67108864
net.ipv4.tcp_wmem               = 4096 65536 67108864
net.core.rmem_max               = 67108864
net.core.wmem_max               = 67108864
net.ipv4.udp_rmem_min           = 8192
net.ipv4.udp_wmem_min           = 8192
net.ipv4.ip_local_port_range    = 1024 65535
net.ipv4.tcp_timestamps         = 1
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward             = 1
net.ipv6.conf.all.forwarding    = 1
net.ipv6.conf.default.forwarding= 1
net.ipv4.conf.all.route_localnet= 1
EOF

    # 4. 重载内核参数生效
    echo "🔄 正在重载 sysctl 使配置生效..."
    sysctl --system > /dev/null 2>&1

    echo ""
    echo "✅ 优化完成！当前系统已成功开启 BBR 并接管网络参数。"
}

# ==========================================
# 卸载与恢复逻辑
# ==========================================
uninstall_restore() {
    echo "🧹 开始卸载优化参数并恢复系统原状..."

    # 1. 删除我们的专属优化文件
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo "🗑️ 已删除优化文件: $CONF_FILE"
    else
        echo "⚠️ 未找到优化文件，可能尚未安装。"
    fi

    # 2. 从备份目录中释放被隔离的文件
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
        echo "♻️ 正在将原有的配置文件恢复原位..."
        mv "$BACKUP_DIR"/* /etc/sysctl.d/
        rm -rf "$BACKUP_DIR"
        echo "✅ 备份文件已完全恢复。"
    else
        echo "ℹ️ 没有找到需要恢复的备份文件。"
    fi

    # 3. 重新加载原来的参数
    echo "🔄 正在重载原始 sysctl 配置..."
    sysctl --system > /dev/null 2>&1

    echo ""
    echo "✅ 恢复完成！系统已回到运行优化脚本前的状态。"
}

# ==========================================
# 脚本菜单入口
# ==========================================
case "$1" in
    install)
        install_optimize
        ;;
    uninstall)
        uninstall_restore
        ;;
    *)
        echo "========================================="
        echo " 网络优化与 BBR 一键脚本 (带备份恢复) "
        echo "========================================="
        echo "使用说明:"
        echo "  部署优化: bash $0 install"
        echo "  卸载恢复: bash $0 uninstall"
        echo "========================================="
        exit 1
        ;;
esac
