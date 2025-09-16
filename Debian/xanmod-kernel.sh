#!/bin/bash

# 启用严格错误检查
set -euo pipefail

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用root权限运行此脚本"
  exit 1
fi

# 创建交换空间函数
create_swap() {
  echo "未检测到SWAP，正在创建1G的交换空间..."
  
  if ! fallocate -l 1G /swapfile; then
    echo "fallocate 失败，尝试使用 dd 创建交换文件..."
    dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
  fi
  
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  swapon --show
  cp /etc/fstab /etc/fstab.bak
  echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
  echo "vm.swappiness = 100" >> /etc/sysctl.conf
  sysctl -p
}

# 检查现有交换空间
if ! swapon --show | grep -q 'swap'; then
  create_swap
  echo "已自动创建1G的SWAP 防止小内存机器失联"
fi

# 更新系统并安装依赖
apt-get update -y
apt-get install -y --no-install-recommends curl wget unzip gpg
apt-get dist-upgrade -y

# 处理 XanMod 密钥
keyring_path="/usr/share/keyrings/xanmod-archive-keyring.gpg"
temp_key=$(mktemp)

cleanup() {
  rm -f "$temp_key"
  echo "已清理临时文件"
}
trap cleanup EXIT

echo "正在下载并验证 XanMod 密钥..."
if ! wget -qO - https://gitlab.com/afrd.gpg | gpg --dearmor -o "$temp_key"; then
  echo "密钥下载或转换失败"
  exit 1
fi

# 验证密钥有效性（基础验证）
if ! gpg --no-default-keyring --keyring "$temp_key" --list-keys &> /dev/null; then
  echo "无效的 GPG 密钥格式"
  exit 1
fi

# 安装已验证的密钥
mv -f "$temp_key" "$keyring_path"
chmod 644 "$keyring_path"

# 添加软件源
echo "deb [signed-by=$keyring_path] http://deb.xanmod.org releases main" | tee /etc/apt/sources.list.d/xanmod-release.list

# 安装内核
apt-get update
apt-get install -y linux-xanmod-x64v3

# 应用网络优化配置
{
  echo "net.ipv4.tcp_congestion_control = bbr"
  echo "net.core.default_qdisc = fq_pie"
  echo "net.core.rmem_max = 67108848"
  echo "net.core.wmem_max = 67108848"
  echo "net.core.somaxconn = 16384"
  echo "net.core.netdev_max_backlog = 8192"
  echo "net.ipv4.tcp_rmem = 4096 87380 67108848"
  echo "net.ipv4.tcp_wmem = 4096 87380 67108848"
  echo "net.ipv4.tcp_adv_win_scale = 0"
  echo "net.ipv4.tcp_sack = 1"
  echo "net.ipv4.tcp_timestamps = 1"
  echo "net.ipv4.tcp_tw_reuse = 1"
  echo "net.ipv4.tcp_fin_timeout = 60"
  echo "net.ipv4.tcp_ecn = 2"
  echo "net.ipv4.tcp_max_syn_backlog = 8192"
  echo "net.ipv4.tcp_max_tw_buckets = 16384"
  echo "net.ipv4.tcp_max_orphans = 16384"
  echo "net.ipv4.tcp_syncookies = 1"
  echo "net.ipv4.tcp_syn_retries = 5"
  echo "net.ipv4.tcp_synack_retries = 5"
  echo "net.ipv4.tcp_slow_start_after_idle = 0"
  echo "net.ipv4.tcp_fastopen = 3"
  echo "net.ipv4.route.gc_timeout = 300"
  echo "fs.file-max = 500000"
  echo "fs.inotify.max_user_instances = 128"
} >> /etc/sysctl.conf

sysctl -p

# 重启提示
read -p "是否要重启系统？(y/n) " user_input
case "$user_input" in
  y|Y) 
    echo "系统即将重启..."
    reboot
    ;;
  n|N)
    echo "系统不会重启"
    ;;
  *)
    echo "无效输入，系统保持当前状态"
    ;;
esac
