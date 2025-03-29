#!/bin/bash

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用root权限运行此脚本"
  exit 1
fi

# 检查是否已经有交换空间
if swapon --show | grep -q 'swap'; then
  echo "系统已存在SWAP"
else
  echo "未检测到SWAP，正在创建1G的交换空间..."

fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
swapon --show
cp /etc/fstab /etc/fstab.bak
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo "vm.swappiness = 100" >> /etc/sysctl.conf
echo "已自动创建1G的SWAP 防止小内存机器失联"
fi

apt-get update -y && apt-get dist-upgrade curl wget unzip gpg -y

wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -vo /usr/share/keyrings/xanmod-archive-keyring.gpg

echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list

apt-get update && apt-get install linux-xanmod-x64v3 -y

echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf

echo "net.core.default_qdisc = fq_pie" >> /etc/sysctl.conf

sysctl -p

echo "是否要重启系统？(y/n)"
read user_input

if [ "$user_input" == "y" ]; then
    echo "系统即将重启..."
    sudo reboot
elif [ "$user_input" == "n" ]; then
    echo "系统不会重启"
else
    echo "无效输入，请输入 'y' 或 'n'。"
fi
