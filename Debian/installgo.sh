#!/bin/bash

# 确保脚本以root权限运行
if [[ $EUID -ne 0 ]]; then
   echo "Please run it with root privileges!" 
   exit 1
fi

rm -rf /usr/local/go

wget -O go.tar.gz https://dl.google.com/go/go1.23.4.linux-amd64.tar.gz

tar -C /usr/local -xzf go.tar.gz

echo "export PATH=$PATH:/usr/local/go/bin" >> /root/.bashrc

rm go.tar.gz

go version
