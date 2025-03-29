#!/bin/bash

# 启用严格错误检查
set -euo pipefail

# 安装参数配置
GO_VERSION="1.22.4"                  # 最新稳定版本
ARCH="linux-amd64"                   # 架构类型
INSTALL_DIR="/usr/local"             # 安装目录
PROFILE_FILE="$HOME/.profile"        # 配置文件路径
WORKSPACE="$HOME/go"                 # 默认工作区

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用sudo或以root权限运行此脚本"
  exit 1
fi

# 获取当前已安装版本
current_go_version=$(go version 2>/dev/null | awk '{print $3}' || echo "")

# 卸载旧版本函数
uninstall_old_go() {
  echo "检测到已安装版本: $current_go_version"
  read -p "是否要卸载当前版本？(y/n) " choice
  case "$choice" in
    y|Y)
      echo "正在卸载旧版本..."
      rm -rf "$INSTALL_DIR/go"
      [ -f "$PROFILE_FILE" ] && sed -i '/# GoLang Configuration/d' "$PROFILE_FILE"
      echo "旧版本已卸载"
      ;;
    *)
      echo "保留现有安装"
      exit 0
      ;;
  esac
}

# 如果有旧版本则提示
[ -n "$current_go_version" ] && uninstall_old_go

# 创建临时目录
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

# 下载并验证Go
download_go() {
  local package_name="go$GO_VERSION.$ARCH.tar.gz"
  local checksum_file="$temp_dir/go$GO_VERSION.checksum"

  echo "正在下载Go $GO_VERSION..."
  wget -q --show-progress -P "$temp_dir" "https://dl.google.com/go/$package_name"
  
  echo "下载校验文件..."
  wget -q -O "$checksum_file" "https://dl.google.com/go/$package_name.sha256"

  echo "验证文件完整性..."
  (cd "$temp_dir" && sha256sum -c "$checksum_file") || {
    echo "校验和不匹配！可能文件损坏或被篡改"
    exit 1
  }
}

# 执行下载
download_go

# 安装过程
echo "正在安装到 $INSTALL_DIR..."
tar -C "$INSTALL_DIR" -xzf "$temp_dir/go$GO_VERSION.$ARCH.tar.gz"

# 配置环境变量
configure_environment() {
  echo "配置环境变量..."
  
  # 删除旧配置
  [ -f "$PROFILE_FILE" ] && sed -i '/# GoLang Configuration/d' "$PROFILE_FILE"

  # 添加新配置
  cat << EOF >> "$PROFILE_FILE"

# GoLang Configuration
export GOROOT=$INSTALL_DIR/go
export GOPATH=$WORKSPACE
export PATH=\$GOPATH/bin:\$GOROOT/bin:\$PATH
EOF

  # 立即生效
  source "$PROFILE_FILE"
}

# 询问是否自动配置
read -p "是否自动配置环境变量？(y/n) " choice
case "$choice" in
  y|Y) configure_environment ;;
  *) echo "请手动配置环境变量" ;;
esac

# 创建工作区
create_workspace() {
  echo "创建Go工作区..."
  mkdir -p "$WORKSPATH"/{bin,src,pkg}
  echo "工作区已创建在 $WORKSPACE"
  echo "你可以将项目放在 $WORKSPACE/src 目录下"
}

read -p "是否创建默认工作区？(y/n) " choice
case "$choice" in
  y|Y) create_workspace ;;
  *) echo "跳过工作区创建" ;;
esac

# 验证安装
validation() {
  echo "验证安装..."
  if ! command -v go &> /dev/null; then
    echo "安装失败！请检查路径配置"
    exit 1
  fi

  echo "Go版本信息:"
  go version

  # 创建测试程序
  test_file="$WORKSPACE/src/hello/hello.go"
  mkdir -p "$(dirname "$test_file")"
  cat << EOF > "$test_file"
package main

import "fmt"

func main() {
    fmt.Println("Go 安装成功！")
}
EOF

  echo "编译测试程序..."
  (cd "$(dirname "$test_file")" && go build && ./hello)
}

validation

echo "安装完成！请重新登录或执行 'source $PROFILE_FILE' 使配置生效"
