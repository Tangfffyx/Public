#!/usr/bin/env bash
set -e

echo "========== 磁盘清理开始 =========="
echo
echo "[1/8] 清理前磁盘占用："
df -h /
echo

echo "[2/8] 清理 apt 软件包缓存..."
apt clean || true
echo

echo "[3/8] 删除 apt 包列表缓存..."
rm -rf /var/lib/apt/lists/* || true
echo

echo "[4/8] 修复损坏依赖..."
apt --fix-broken install -y || true
echo

echo "[5/8] 自动删除无用依赖..."
apt autoremove -y || true
echo

echo "[6/8] 清理临时目录..."
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
echo

echo "[7/8] 压缩 systemd 日志到 50MB..."
journalctl --vacuum-size=50M || true
echo

echo "[8/8] 清理 /var/cache 残留缓存..."
rm -rf /var/cache/* 2>/dev/null || true
echo

echo "========== 清理完成 =========="
echo
echo "清理后磁盘占用："
df -h /
