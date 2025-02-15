#!/bin/bash

KEYRINGS_DIR="/etc/apt/keyrings"

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用root权限运行此脚本"
  exit 1
fi

# 检查目录是否存在
if [ -d "$KEYRINGS_DIR" ]; then
    echo "目录 $KEYRINGS_DIR 已存在，无需创建。"
else
    # 使用 sudo 创建目录（需有权限）
    sudo mkdir -p "$KEYRINGS_DIR"
    # 检查是否创建成功
    if [ $? -eq 0 ]; then
        echo "目录 $KEYRINGS_DIR 创建成功。"
    else
        echo "错误：无法创建目录 $KEYRINGS_DIR，请检查权限！" >&2
        exit 1
    fi
fi

curl -fsSL https://repo.natesales.net/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/natesales.gpg

echo "deb [signed-by=/etc/apt/keyrings/natesales.gpg] https://repo.natesales.net/apt * *" | sudo tee /etc/apt/sources.list.d/natesales.list

apt-get update

apt-get install q -y

q -V
