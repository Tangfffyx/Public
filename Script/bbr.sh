#!/bin/bash
# Debian/Ubuntu 网络参数优化与 BBR 开启脚本
# 包含自动备份与一键恢复功能 (完美最终版)

CONF_FILE="/etc/sysctl.d/99-z-network-optimize.conf"
BACKUP_DIR="/etc/sysctl.d/.network_backup"
MODULE_FILE="/etc/modules-load.d/bbr.conf"

if [ "$EUID" -ne 0 ]; then
    echo "❌ 错误: 请使用 root 权限运行此脚本"
    exit 1
fi

install_optimize() {
    echo "🚀 开始部署网络优化参数..."

    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi

    # 1. 唤醒并加载 BBR 内核模块 (进阶兼容性优化)
    echo "⚙️ 正在加载 tcp_bbr 内核模块..."
    modprobe tcp_bbr 2>/dev/null
    echo "tcp_bbr" > "$MODULE_FILE"

    # 2. 处理全局 /etc/sysctl.conf
    if [ -f "/etc/sysctl.conf" ]; then
        if [ ! -f "$BACKUP_DIR/sysctl.conf.bak" ]; then
            echo "📦 正在备份全局配置文件 /etc/sysctl.conf ..."
            cp "/etc/sysctl.conf" "$BACKUP_DIR/sysctl.conf.bak"
        else
            echo "ℹ️ 检测到全局配置备份已存在，跳过备份以保护原数据。"
        fi
        > "/etc/sysctl.conf"
    fi

    # 3. 隔离并备份潜在冲突文件
    for file in /etc/sysctl.d/99-*.conf; do
        if [ -f "$file" ] && [ "$file" != "$CONF_FILE" ]; then
            echo "📦 发现潜在冲突文件: $file，正在移至备份目录..."
            mv "$file" "$BACKUP_DIR/"
        fi
    done

    # 4. 写入终极配置
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

    # 5. 重载内核参数生效
    echo "🔄 正在重载 sysctl 使配置生效..."
    sysctl --system > /dev/null 2>&1

    echo ""
    echo "✅ 优化完成！当前系统已成功开启 BBR 并接管网络参数。"
}

uninstall_restore() {
    echo "🧹 开始卸载优化参数并恢复系统原状..."

    # 1. 删除开机自启的 BBR 模块配置
    if [ -f "$MODULE_FILE" ]; then
        rm -f "$MODULE_FILE"
    fi

    # 2. 删除我们的专属优化文件
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo "🗑️ 已删除优化文件: $CONF_FILE"
    fi

    # 3. 恢复全局 /etc/sysctl.conf
    if [ -f "$BACKUP_DIR/sysctl.conf.bak" ]; then
        echo "♻️ 正在恢复全局配置文件 /etc/sysctl.conf ..."
        mv "$BACKUP_DIR/sysctl.conf.bak" "/etc/sysctl.conf"
    fi

    # 4. 从备份目录中释放被隔离的 .conf 文件
    if [ -d "$BACKUP_DIR" ]; then
        if [ "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
            echo "♻️ 正在将 /etc/sysctl.d/ 中的原配置文件恢复原位..."
            mv "$BACKUP_DIR"/* /etc/sysctl.d/ 2>/dev/null
        fi
        rm -rf "$BACKUP_DIR"
        echo "✅ 所有备份文件已完全恢复。"
    fi

    # 5. 重新加载原来的参数
    echo "🔄 正在重载原始 sysctl 配置..."
    sysctl --system > /dev/null 2>&1

    echo ""
    echo "✅ 恢复完成！系统已完美回到你运行优化脚本前的状态。"
}

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
