#!/bin/bash

# -----------------------------------------------------------------------------
# 智能系统清理脚本
# 旨在最大化释放无用文件的同时,避免清理掉任何有用的文件。
# -----------------------------------------------------------------------------

# 颜色定义
# 使用 tput 命令来获取颜色代码,这比直接使用 ANSI 转义序列更健壮和兼容
# 如果 tput 不可用,则回退到默认的 ANSI 序列
if command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    NC=$(tput sgr0)
else
    # 直接定义 ANSI 颜色码,使用 printf 避免 echo -e 的兼容性问题
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
fi

# 日志函数
# 使用 printf 代替 echo -e,更具兼容性
log_info() { printf "%b[信息]%b %s\n" "${BLUE}" "${NC}" "$1"; }
log_success() { printf "%b[成功]%b %s\n" "${GREEN}" "${NC}" "$1"; }
log_warning() { printf "%b[警告]%b %s\n" "${YELLOW}" "${NC}" "$1"; }
log_error() { printf "%b[错误]%b %s\n" "${RED}" "${NC}" "$1"; }

# 确保脚本以root权限运行
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以root权限运行。请使用 'sudo $0' 执行。"
   exit 1
fi

log_info "正在启动智能系统清理程序..."

# 获取清理前的磁盘使用情况
# 确保 awk 命令中的单引号被正确处理,使用双引号包裹整个命令字符串
start_space_kb=$(df / | tail -n 1 | awk '{print $3}')

# -----------------------------------------------------------------------------
# 1. 更新包列表并安装必要工具
# -----------------------------------------------------------------------------
log_info "正在更新包列表并安装必要工具 (deborphan)..."
apt-get update > /dev/null 2>&1
if ! dpkg -s deborphan >/dev/null 2>&1; then
    if ! apt-get install -y deborphan > /dev/null 2>&1; then
        log_warning "deborphan 安装失败,部分清理功能可能受限。"
    else
        log_success "deborphan 安装成功。"
    fi
else
    log_info "deborphan 已安装。"
fi

# -----------------------------------------------------------------------------
# 2. 安全删除旧内核
# -----------------------------------------------------------------------------
log_info "正在检查并安全删除未使用的旧内核..."
current_kernel=$(uname -r)
# 获取所有已安装的内核,排除当前正在使用的内核和虚拟机相关内核
# 确保 grep -E 中的引号被正确处理,并确保整个命令在一个字符串中
kernel_packages=$(dpkg --list | grep -E '^ii  linux-(image|headers)-[0-9]+' | awk '{print $2}' | grep -v "$current_kernel" | grep -v -E '-virtual|-generic-lts-')

if [ -n "$kernel_packages" ]; then
    log_warning "发现以下旧内核,将进行删除:"
    echo "$kernel_packages"
    # 使用 --assume-yes 避免交互,并确保删除相关配置
    if apt-get purge --assume-yes "$kernel_packages" > /dev/null 2>&1; then
        log_success "旧内核删除成功。"
        log_info "正在更新 GRUB 引导配置..."
        update-grub > /dev/null 2>&1
        log_success "GRUB 更新完成。"
    else
        log_error "旧内核删除失败。"
    fi
else
    log_info "没有发现需要删除的旧内核。"
fi

# -----------------------------------------------------------------------------
# 3. 清理孤立的包和配置
# -----------------------------------------------------------------------------
log_info "正在清理孤立的库和数据包..."
# 清理孤立的库
orphaned_libs=$(deborphan --guess-common)
if [ -n "$orphaned_libs" ]; then
    log_warning "发现以下孤立库,将进行删除:"
    echo "$orphaned_libs"
    if apt-get -y remove --purge "$orphaned_libs" > /dev/null 2>&1; then
        log_success "孤立库清理成功。"
    else
        log_error "孤立库清理失败。"
    fi
else
    log_info "没有发现孤立的库。"
fi

# 清理孤立的数据包 (可能包含配置文件)
orphaned_data=$(deborphan --guess-data)
if [ -n "$orphaned_data" ]; then
    log_warning "发现以下孤立数据包,将进行删除:"
    echo "$orphaned_data"
    if apt-get -y remove --purge "$orphaned_data" > /dev/null 2>&1; then
        log_success "孤立数据包清理成功。"
    else
        log_error "孤立数据包清理失败。"
    fi
else
    log_info "没有发现孤立的数据包。"
fi

# -----------------------------------------------------------------------------
# 4. 安全清理临时文件
# -----------------------------------------------------------------------------
log_info "正在安全清理旧的临时文件 (超过 7 天)..."
# /tmp 和 /var/tmp 通常在重启后会被清理,但运行时清理旧文件更安全
# 删除 /tmp 下超过 7 天的文件和空目录,不删除正在使用的文件
find /tmp -type f -atime +7 -delete 2>/dev/null
find /tmp -type d -empty -delete 2>/dev/null
log_success "/tmp 目录下旧的临时文件清理完成。"

find /var/tmp -type f -atime +7 -delete 2>/dev/null
find /var/tmp -type d -empty -delete 2>/dev/null
log_success "/var/tmp 目录下旧的临时文件清理完成。"

# -----------------------------------------------------------------------------
# 5. 清理用户缓存目录 (更温和的方式)
# -----------------------------------------------------------------------------
log_info "正在清理用户缓存目录 (仅删除超过 30 天的旧文件)..."
for user_home in /home/*; do
  if [ -d "$user_home/.cache" ]; then
    log_info "正在清理用户 $user_home 的缓存..."
    # 删除 .cache 目录下超过 30 天的文件和空目录
    find "$user_home/.cache" -type f -atime +30 -delete 2>/dev/null
    find "$user_home/.cache" -type d -empty -delete 2>/dev/null
    log_success "用户 $user_home 的缓存清理完成。"
  fi
done

# 清理 root 用户的缓存
if [ -d "/root/.cache" ]; then
    log_info "正在清理 root 用户的缓存..."
    find "/root/.cache" -type f -atime +30 -delete 2>/dev/null
    find "/root/.cache" -type d -empty -delete 2>/dev/null
    log_success "root 用户的缓存清理完成。"
fi

# -----------------------------------------------------------------------------
# 6. 清理系统日志文件 (使用 journalctl 和 logrotate)
# -----------------------------------------------------------------------------
log_info "正在清理系统日志文件 (journalctl)..."
# 限制 journalctl 日志大小和时间,这是推荐的清理方式
if journalctl --vacuum-time=7d --vacuum-size=1G > /dev/null 2>&1; then
    log_success "journalctl 日志清理完成。"
else
    log_warning "journalctl 日志清理失败或无效。"
fi

log_info "正在运行 logrotate 进行日志轮换..."
# 强制执行 logrotate,处理 /var/log 下的日志文件
if logrotate -f /etc/logrotate.conf > /dev/null 2>&1; then
    log_success "logrotate 日志轮换完成。"
else
    log_warning "logrotate 执行失败或无效。"
fi

# 清理 /var/log 下超过 30 天的旧日志文件 (非活跃日志)
log_info "正在清理 /var/log 下超过 30 天的旧日志文件..."
find /var/log -type f -name "*.log" -atime +30 -delete 2>/dev/null
find /var/log -type f -name "*.gz" -atime +30 -delete 2>/dev/null
log_success "/var/log 下旧日志文件清理完成。"

# -----------------------------------------------------------------------------
# 7. 清理APT的本地存档和缓存
# -----------------------------------------------------------------------------
log_info "正在清理APT的本地存档和缓存..."
apt-get autoclean > /dev/null 2>&1 # 清理不再可下载的包文件
apt-get autoremove -y > /dev/null 2>&1 # 删除不再需要的依赖包
apt-get clean > /dev/null 2>&1 # 清理所有已下载的包文件
log_success "APT 缓存清理完成。"

# -----------------------------------------------------------------------------
# 8. 清理Docker(如果使用Docker)
# -----------------------------------------------------------------------------
if command -v docker &> /dev/null; then
    log_info "正在清理Docker镜像、容器和卷... (此操作会删除所有未使用的Docker资源)"
    # 提示用户确认,因为 -a --volumes 会删除所有未使用的资源
    read -r -p "${YELLOW}警告:此操作将删除所有未使用的 Docker 镜像、容器、网络和卷。是否继续? (y/N)${NC} " confirm_docker_prune
    if [[ "$confirm_docker_prune" =~ ^[Yy]$ ]]; then
        if docker system prune -a --volumes --force > /dev/null 2>&1; then
            log_success "Docker 资源清理完成。"
        else
            log_error "Docker 资源清理失败。"
        fi
    else
        log_info "已跳过 Docker 资源清理。"
    fi
else
    log_info "未检测到 Docker,跳过 Docker 资源清理。"
fi

# -----------------------------------------------------------------------------
# 9. 清理缩略图缓存
# -----------------------------------------------------------------------------
log_info "正在清理缩略图缓存..."
rm -rf ~/.cache/thumbnails/* > /dev/null 2>&1
log_success "缩略图缓存清理完成。"

# -----------------------------------------------------------------------------
# 10. 清理旧的日志压缩文件 (例如 /var/log/*.gz)
# -----------------------------------------------------------------------------
log_info "正在清理旧的日志压缩文件..."
find /var/log -name "*.gz" -type f -mtime +30 -delete 2>/dev/null
log_success "旧的日志压缩文件清理完成。"

# -----------------------------------------------------------------------------
# 获取清理后的磁盘使用情况并显示结果
# -----------------------------------------------------------------------------
end_space_kb=$(df / | tail -n 1 | awk '{print $3}')
cleared_space_kb=$((start_space_kb - end_space_kb))

log_success "智能系统清理完成!"
if [ "$cleared_space_kb" -gt 0 ]; then
    cleared_space_mb=$((cleared_space_kb / 1024))
    log_success "共清理了 ${cleared_space_mb}MB 空间!"
else
    log_info "本次清理没有释放额外空间,系统可能已经很干净了。"
fi

log_info "建议重启系统以应用所有更改。"
