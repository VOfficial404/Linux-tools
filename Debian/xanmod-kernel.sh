#!/bin/bash

# XanMod Kernel 安装脚本 (修复版)
# 适用于 Debian 12+ (bookworm, trixie, sid)

# 启用严格错误检查
set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# apt 全程非交互；配置文件冲突时保留本地版本
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# 从终端读取单个字符，兼容 curl ... | bash 的用法；无终端时返回空
ask() {
  REPLY=''
  if [ -r /dev/tty ]; then
    read -r -p "$1" -n 1 REPLY </dev/tty || true
    echo
  fi
}

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
  log_error "请使用root权限运行此脚本"
  echo "使用方法: sudo bash $0"
  exit 1
fi

# 检测 Debian 版本
if [ ! -f /etc/os-release ]; then
  log_error "无法检测系统版本"
  exit 1
fi

source /etc/os-release

if [ "$ID" != "debian" ]; then
  log_error "此脚本仅支持 Debian 系统，当前系统: $ID"
  exit 1
fi

log_info "检测到系统: $PRETTY_NAME"

# 获取发行版代号：优先用 os-release，没有时再退回 lsb_release
DEBIAN_CODENAME="${VERSION_CODENAME:-}"
if [ -z "$DEBIAN_CODENAME" ]; then
  if ! command -v lsb_release &> /dev/null; then
    log_warn "lsb_release 未安装，正在安装..."
    apt-get update -qq
    apt-get install -y lsb-release
  fi
  DEBIAN_CODENAME=$(lsb_release -sc)
fi
log_info "发行版代号: $DEBIAN_CODENAME"

# 检查是否支持的版本
case "$DEBIAN_CODENAME" in
  bookworm|trixie|forky|sid)
    log_info "✓ 此版本受 XanMod 支持"
    ;;
  *)
    log_warn "警告: $DEBIAN_CODENAME 可能不被 XanMod 官方支持"
    ask "是否继续? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
    ;;
esac

# 创建交换空间函数
create_swap() {
  log_info "未检测到SWAP，正在创建1G的交换空间..."

  if ! fallocate -l 1G /swapfile 2>/dev/null; then
    log_warn "fallocate 失败，尝试使用 dd 创建交换文件..."
    dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
  fi

  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  # 备份并添加到 fstab
  if ! grep -q '/swapfile' /etc/fstab; then
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
  fi

  # swappiness 统一由后面的 /etc/sysctl.d/99-xanmod-optimizations.conf 设置
  # （Debian 13 已不再读取 /etc/sysctl.conf）

  swapon --show
  log_info "✓ SWAP 创建成功"
}

# 检查现有交换空间：有任何一行输出就说明已有交换（分区、文件、zram 都算）
if [ -z "$(swapon --noheadings --show 2>/dev/null)" ]; then
  create_swap
else
  log_info "✓ 已存在 SWAP 空间"
  swapon --show
fi

# 更新系统并安装依赖
log_info "更新软件包列表..."
apt-get update -y

log_info "安装必要依赖..."
apt-get install -y --no-install-recommends \
  curl \
  wget \
  gpg \
  lsb-release \
  apt-transport-https \
  ca-certificates

log_info "升级系统软件包..."
apt-get "${APT_OPTS[@]}" dist-upgrade -y

# 处理 XanMod GPG 密钥
keyring_path="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
temp_key=$(mktemp)

cleanup() {
  rm -f "$temp_key"
}
trap cleanup EXIT

# 创建 keyrings 目录
mkdir -p /etc/apt/keyrings

log_info "正在下载 XanMod 官方 GPG 密钥..."
# mktemp 已经创建了文件，必须加 --yes，否则 gpg 会停下来询问是否覆盖
if ! wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o "$temp_key"; then
  log_error "密钥下载或转换失败"
  exit 1
fi

# 验证密钥有效性
if ! gpg --no-default-keyring --keyring "$temp_key" --list-keys &> /dev/null; then
  log_error "无效的 GPG 密钥格式"
  exit 1
fi

# 安装已验证的密钥
mv -f "$temp_key" "$keyring_path"
chmod 644 "$keyring_path"
log_info "✓ GPG 密钥安装成功"

# 添加软件源
sources_list="/etc/apt/sources.list.d/xanmod-release.list"
log_info "配置 XanMod 软件源..."
echo "deb [signed-by=$keyring_path] http://deb.xanmod.org $DEBIAN_CODENAME main" | tee "$sources_list"

# 检测 CPU 微架构级别
log_info "检测 CPU 微架构级别..."

# 按 x86-64 psABI 的定义检查整组指令集，只看到 avx2 / avx512 字样并不够
# （部分虚拟机会暴露 avx2 却缺 bmi2/fma，装 v3 内核后无法启动）
detect_cpu_level() {
  local flags
  flags=" $(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2) "
  has() {
    local f
    for f in "$@"; do [[ $flags == *" $f "* ]] || return 1; done
  }
  if ! has cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; then
    echo "x64v1"
  elif ! has avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; then
    echo "x64v2"
  elif ! has avx512f avx512bw avx512cd avx512dq avx512vl; then
    echo "x64v3"
  else
    echo "x64v4"
  fi
}

CPU_LEVEL=$(detect_cpu_level)
log_info "检测到 CPU 级别: $CPU_LEVEL"

# 让用户选择内核分支
echo ""
echo "请选择内核分支:"
echo "1) LTS (长期支持，推荐用于生产环境)"
echo "2) MAIN (主线，最新特性)"
echo "3) RT (实时内核，用于低延迟场景)"
kernel_choice=''
if [ -r /dev/tty ]; then
  read -r -p "请输入选项 [1-3] (默认: 1): " kernel_choice </dev/tty || true
fi

case "${kernel_choice:-1}" in
  1) BRANCH="lts" ;;
  2) BRANCH="main" ;;
  3) BRANCH="rt" ;;
  *) log_warn "无效选择，使用默认 LTS 内核"; BRANCH="lts" ;;
esac

log_info "更新软件包列表..."
apt-get update

# 并非每个分支都提供所有级别（例如 x64v4 已停止单独构建），
# 依次尝试 本级别 -> 更低级别 -> LTS，选第一个软件源里真实存在的包
pkg_name() {
  if [ "$1" = "main" ]; then echo "linux-xanmod-$2"; else echo "linux-xanmod-$1-$2"; fi
}
levels=()
for lv in x64v4 x64v3 x64v2 x64v1; do
  [[ ${#levels[@]} -gt 0 || $lv == "$CPU_LEVEL" ]] && levels+=("$lv")
done

KERNEL_PACKAGE=''
for br in "$BRANCH" lts; do
  for lv in "${levels[@]}"; do
    candidate=$(pkg_name "$br" "$lv")
    if apt-cache show "$candidate" >/dev/null 2>&1; then
      KERNEL_PACKAGE=$candidate
      break 2
    fi
  done
done

if [ -z "$KERNEL_PACKAGE" ]; then
  log_error "软件源里找不到适合 $CPU_LEVEL 的 XanMod 内核包"
  log_error "请检查 $sources_list 以及 $DEBIAN_CODENAME 是否受 XanMod 支持"
  exit 1
fi
[ "$KERNEL_PACKAGE" = "$(pkg_name "$BRANCH" "$CPU_LEVEL")" ] \
  || log_warn "软件源中没有 $(pkg_name "$BRANCH" "$CPU_LEVEL")，改用 $KERNEL_PACKAGE"

log_info "将安装: $KERNEL_PACKAGE"

log_info "正在安装 XanMod 内核..."
if apt-get "${APT_OPTS[@]}" install -y "$KERNEL_PACKAGE"; then
  log_info "✓ XanMod 内核安装成功"
else
  log_error "内核安装失败"
  log_error "请检查错误信息并重试"
  exit 1
fi

# 应用网络优化配置
log_info "正在应用网络优化配置..."

sysctl_conf="/etc/sysctl.d/99-xanmod-optimizations.conf"

cat > "$sysctl_conf" <<'EOF'
# XanMod 网络优化配置

# TCP BBR 拥塞控制算法
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq_pie

# 网络缓冲区大小
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536

# TCP 缓冲区调优
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864

# 连接队列
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

# TCP 优化
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_max_tw_buckets = 16384
net.ipv4.tcp_max_orphans = 16384
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3

# 路由优化
net.ipv4.route.gc_timeout = 100

# 文件系统
fs.file-max = 1000000
fs.inotify.max_user_instances = 256
fs.inotify.max_user_watches = 524288

# 虚拟内存
vm.swappiness = 60
vm.vfs_cache_pressure = 50
EOF

# 应用配置。当前还在旧内核上，个别参数可能暂不支持，失败不应中断脚本，重启后会自动生效
if sysctl -p "$sysctl_conf" >/dev/null; then
  log_info "✓ 网络优化配置已应用"
else
  log_warn "部分参数在当前内核上未能应用，重启进入 XanMod 内核后会自动生效"
fi

# 显示已安装的内核
log_info "当前已安装的内核:"
dpkg -l | grep -E 'linux-image|linux-xanmod' | grep ^ii || true

# 显示当前内核
log_info "当前运行的内核: $(uname -r)"

# 完成提示
echo ""
echo "=========================================="
log_info "✓ XanMod 内核安装完成！"
echo "=========================================="
echo ""
echo "已安装的包: $KERNEL_PACKAGE"
echo "优化配置: $sysctl_conf"
echo ""
log_warn "重要: 需要重启系统以使用新内核"
echo ""

# 重启提示
ask "是否现在重启系统？(y/n) "
case "$REPLY" in
  y|Y)
    log_info "系统将在 5 秒后重启..."
    sleep 5
    reboot
    ;;
  *)
    log_info "请稍后手动重启系统"
    echo "重启后可以使用以下命令验证:"
    echo "  uname -r"
    echo "  cat /proc/version"
    ;;
esac
