#!/bin/bash

# 启用严格错误检查
set -euo pipefail

# 配置参数
readonly KEYRINGS_DIR="/etc/apt/keyrings"
readonly REPO_NAME="sagernet"
readonly GPG_KEY_URL="https://sing-box.app/gpg.key"
readonly GPG_KEY_PATH="${KEYRINGS_DIR}/${REPO_NAME}.asc"
readonly SOURCE_LIST_PATH="/etc/apt/sources.list.d/${REPO_NAME}.list"
readonly ARCHITECTURE="$(dpkg --print-architecture)"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m' # 无色

# 错误处理函数
error_exit() {
  echo -e "${RED}[错误] $1${NC}" >&2
  exit 1
}

# 检查 root 权限
check_root() {
  [[ "$(id -u)" -eq 0 ]] || error_exit "本脚本需要 root 权限执行"
}

# 创建密钥目录
create_keyring_dir() {
  if [[ ! -d "$KEYRINGS_DIR" ]]; then
    echo -e "${GREEN}创建密钥目录: ${KEYRINGS_DIR}${NC}"
    mkdir -p "$KEYRINGS_DIR" || error_exit "目录创建失败"
    chmod 755 "$KEYRINGS_DIR"
  fi
}

# 下载并验证 GPG 密钥
import_gpg_key() {
  local temp_key
  temp_key=$(mktemp) || error_exit "无法创建临时文件"

  echo -e "${GREEN}下载 GPG 密钥...${NC}"
  if ! curl -fsSL "$GPG_KEY_URL" -o "$temp_key"; then
    rm -f "$temp_key"
    error_exit "密钥下载失败，请检查网络连接"
  fi

  echo -e "${GREEN}验证密钥格式...${NC}"
  if ! gpg --dry-run --import --quiet "$temp_key"; then
    rm -f "$temp_key"
    error_exit "无效的 GPG 密钥格式"
  fi

  mv -f "$temp_key" "$GPG_KEY_PATH" || error_exit "密钥移动失败"
  chmod 644 "$GPG_KEY_PATH"
}

# 添加软件源
add_repository() {
  echo -e "${GREEN}配置软件源...${NC}"
  cat << EOF | tee "$SOURCE_LIST_PATH" >/dev/null
deb [arch=${ARCHITECTURE} signed-by=${GPG_KEY_PATH}] https://deb.sagernet.org/ * *
EOF
  chmod 644 "$SOURCE_LIST_PATH"
}

# 安装软件包
install_package() {
  echo -e "${GREEN}更新软件包列表...${NC}"
  apt-get update -qq || error_exit "软件源更新失败"

  echo -e "${GREEN}安装 sing-box...${NC}"
  if ! apt-get install -y sing-box; then
    error_exit "软件安装失败，建议检查:\n1. 网络连接\n2. 软件源配置: ${SOURCE_LIST_PATH}"
  fi

  echo -e "${GREEN}验证安装...${NC}"
  if ! command -v sing-box &>/dev/null; then
    error_exit "安装后未找到可执行文件"
  fi

  echo -e "${GREEN}当前版本信息:${NC}"
  sing-box version
}

# 主流程
main() {
  check_root
  create_keyring_dir
  import_gpg_key
  add_repository
  install_package
  echo -e "${GREEN}安装成功完成!${NC}"
}

# 执行主函数
main
