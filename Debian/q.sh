#!/bin/bash

# 启用严格错误检查模式
set -euo pipefail

# 定义常量
KEYRINGS_DIR="/etc/apt/keyrings"
REPO_NAME="natesales"
GPG_KEY_URL="https://repo.natesales.net/apt/gpg.key"
GPG_KEY_PATH="$KEYRINGS_DIR/$REPO_NAME.gpg"
SOURCE_LIST_PATH="/etc/apt/sources.list.d/$REPO_NAME.list"
REPO_ENTRY="deb [signed-by=$GPG_KEY_PATH] https://repo.natesales.net/apt * *"

# 检查依赖项
check_deps() {
  local deps=("curl" "gpg")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      echo "正在安装依赖项: $dep..."
      apt-get update -qq
      apt-get install -y -qq "$dep"
    fi
  done
}

# 检查 root 权限
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本" >&2
    exit 1
  fi
}

# 创建密钥目录
create_keyring_dir() {
  if [ ! -d "$KEYRINGS_DIR" ]; then
    echo "创建密钥目录: $KEYRINGS_DIR"
    mkdir -p "$KEYRINGS_DIR"
    chmod 755 "$KEYRINGS_DIR"
  fi
}

# 导入 GPG 密钥
import_gpg_key() {
  echo "下载并验证 GPG 密钥..."
  local temp_key
  temp_key=$(mktemp)
  
  # 下载密钥并验证状态码
  if ! curl -fsSL "$GPG_KEY_URL" -o "$temp_key"; then
    echo "错误：无法下载 GPG 密钥" >&2
    exit 1
  fi

  # 验证密钥格式
  if ! gpg --dry-run --import --quiet "$temp_key"; then
    echo "错误：无效的 GPG 密钥格式" >&2
    rm -f "$temp_key"
    exit 1
  fi

  # 转换并安装密钥
  gpg --dearmor --yes -o "$GPG_KEY_PATH" "$temp_key"
  chmod 644 "$GPG_KEY_PATH"
  rm -f "$temp_key"
}

# 添加软件源
add_repository() {
  echo "添加软件源..."
  echo "$REPO_ENTRY" | tee "$SOURCE_LIST_PATH" >/dev/null
  chmod 644 "$SOURCE_LIST_PATH"
}

# 安装软件包
install_package() {
  echo "更新软件包列表..."
  apt-get update -qq

  if ! apt-get install -y -qq q; then
    echo "错误：软件包安装失败" >&2
    echo "建议操作："
    echo "1. 检查仓库配置: $SOURCE_LIST_PATH"
    echo "2. 确认网络连接正常"
    exit 1
  fi

  echo "验证安装结果..."
  if ! command -v q &> /dev/null; then
    echo "错误：软件包安装后未找到可执行文件" >&2
    exit 1
  fi

  echo "安装版本信息："
  q -V
}

# 主流程
main() {
  check_root
  check_deps
  create_keyring_dir
  import_gpg_key
  add_repository
  install_package
  echo "安装完成"
}

# 执行主函数
main
