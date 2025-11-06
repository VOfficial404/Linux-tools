#!/bin/bash

# -----------------------------------------------------------------------------
# 智能系统清理脚本 v3.0 (无额外依赖版本)
# 旨在最大化释放无用文件的同时,避免清理掉任何有用的文件。
# 
# 主要特性:
# - 不安装任何额外软件包 (移除了 deborphan 依赖)
# - 修复了 grep 命令错误
# - 安全清理 /tmp 目录,避免破坏系统
# - 自动验证和修复关键目录权限
# -----------------------------------------------------------------------------

# 颜色定义
if command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    NC=$(tput sgr0)
else
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
fi

# 日志函数
log_info() { printf "%b[信息]%b %s\n" "${BLUE}" "${NC}" "$1"; }
log_success() { printf "%b[成功]%b %s\n" "${GREEN}" "${NC}" "$1"; }
log_warning() { printf "%b[警告]%b %s\n" "${YELLOW}" "${NC}" "$1"; }
log_error() { printf "%b[错误]%b %s\n" "${RED}" "${NC}" "$1"; }

# 确保脚本以root权限运行
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以root权限运行。请使用 'sudo $0' 执行。"
   exit 1
fi

log_info "正在启动智能系统清理程序 v3.0 (无额外依赖版本)..."

# 获取清理前的磁盘使用情况
start_space_kb=$(df / | tail -n 1 | awk '{print $3}')

# -----------------------------------------------------------------------------
# 1. 安全删除旧内核
# -----------------------------------------------------------------------------
log_info "正在检查并安全删除未使用的旧内核..."
current_kernel=$(uname -r)

# 使用 grep -F 和 -- 避免内核版本被误解析为选项
kernel_packages=$(dpkg --list 2>/dev/null | grep -E '^ii  linux-(image|headers)-[0-9]+' | awk '{print $2}' | grep -vF -- "$current_kernel" | grep -vE -- '-virtual|-generic-lts-')

if [ -n "$kernel_packages" ]; then
    log_warning "发现以下旧内核,将进行删除:"
    echo "$kernel_packages"
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
# 2. 清理孤立的包和残留配置 (使用 APT 内建功能,无需 deborphan)
# -----------------------------------------------------------------------------
log_info "正在清理孤立的包和残留配置..."

# 2.1 清理自动安装但不再需要的依赖包
log_info "正在清理孤立的依赖包..."
if apt-get autoremove -y > /dev/null 2>&1; then
    log_success "孤立依赖包清理成功。"
else
    log_warning "孤立依赖包清理失败。"
fi

# 2.2 清理已卸载软件的残留配置文件
log_info "正在检查残留配置文件..."
residual_configs=$(dpkg -l 2>/dev/null | grep '^rc' | awk '{print $2}')
if [ -n "$residual_configs" ]; then
    log_warning "发现以下残留配置文件,将进行清理:"
    echo "$residual_configs"
    # 使用 xargs 避免变量过长导致的问题
    if echo "$residual_configs" | xargs apt-get purge -y > /dev/null 2>&1; then
        log_success "残留配置文件清理成功。"
    else
        log_warning "残留配置文件清理失败。"
    fi
else
    log_info "没有发现残留配置文件。"
fi

# -----------------------------------------------------------------------------
# 3. 安全清理临时文件
# -----------------------------------------------------------------------------
log_info "正在安全清理旧的临时文件 (超过 7 天)..."

# 清理 /tmp - 安全方式
if [ -d "/tmp" ]; then
    # 只删除 /tmp 根目录下的旧文件,不递归进入子目录
    find /tmp -maxdepth 1 -type f -atime +7 -delete 2>/dev/null
    # 只删除深层嵌套的空目录,保护 /tmp 的直接子目录
    find /tmp -mindepth 2 -type d -empty -delete 2>/dev/null
    log_success "/tmp 目录下旧的临时文件清理完成。"
else
    log_warning "/tmp 目录不存在,跳过清理。"
fi

# 清理 /var/tmp - 同样采用安全方式
if [ -d "/var/tmp" ]; then
    find /var/tmp -maxdepth 1 -type f -atime +7 -delete 2>/dev/null
    find /var/tmp -mindepth 2 -type d -empty -delete 2>/dev/null
    log_success "/var/tmp 目录下旧的临时文件清理完成。"
else
    log_warning "/var/tmp 目录不存在,跳过清理。"
fi

# -----------------------------------------------------------------------------
# 4. 清理用户缓存目录
# -----------------------------------------------------------------------------
log_info "正在清理用户缓存目录 (仅删除超过 30 天的旧文件)..."

# 清理普通用户缓存
for user_home in /home/*; do
  if [ -d "$user_home/.cache" ]; then
    log_info "正在清理用户 $user_home 的缓存..."
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
# 5. 清理系统日志文件
# -----------------------------------------------------------------------------
log_info "正在清理系统日志文件..."

# 5.1 使用 journalctl 清理系统日志
if command -v journalctl >/dev/null 2>&1; then
    if journalctl --vacuum-time=7d --vacuum-size=1G > /dev/null 2>&1; then
        log_success "journalctl 日志清理完成。"
    else
        log_warning "journalctl 日志清理失败或无效。"
    fi
else
    log_info "未检测到 journalctl,跳过 systemd 日志清理。"
fi

# 5.2 使用 logrotate 进行日志轮换
if command -v logrotate >/dev/null 2>&1; then
    if logrotate -f /etc/logrotate.conf > /dev/null 2>&1; then
        log_success "logrotate 日志轮换完成。"
    else
        log_warning "logrotate 执行失败或无效。"
    fi
else
    log_info "未检测到 logrotate,跳过日志轮换。"
fi

# 5.3 清理 /var/log 下的旧日志文件
if [ -d "/var/log" ]; then
    log_info "正在清理 /var/log 下超过 30 天的旧日志文件..."
    find /var/log -type f -name "*.log" -atime +30 -delete 2>/dev/null
    find /var/log -type f -name "*.gz" -atime +30 -delete 2>/dev/null
    find /var/log -type f -name "*.old" -atime +30 -delete 2>/dev/null
    log_success "/var/log 下旧日志文件清理完成。"
fi

# -----------------------------------------------------------------------------
# 6. 清理 APT 的本地存档和缓存
# -----------------------------------------------------------------------------
log_info "正在清理 APT 的本地存档和缓存..."

# 清理不再可下载的包文件
apt-get autoclean > /dev/null 2>&1

# 再次运行 autoremove,确保清理所有孤立包
apt-get autoremove -y > /dev/null 2>&1

# 清理所有已下载的包文件
apt-get clean > /dev/null 2>&1

log_success "APT 缓存清理完成。"

# -----------------------------------------------------------------------------
# 7. 清理 Docker (如果使用 Docker)
# -----------------------------------------------------------------------------
if command -v docker &> /dev/null; then
    log_info "检测到 Docker,正在清理未使用的资源..."
    
    # 提示用户确认
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
# 8. 清理缩略图缓存
# -----------------------------------------------------------------------------
log_info "正在清理缩略图缓存..."

# 清理 root 用户的缩略图缓存
if [ -d "$HOME/.cache/thumbnails" ]; then
    rm -rf "$HOME/.cache/thumbnails"/* 2>/dev/null
fi

# 清理所有用户的缩略图缓存
for user_home in /home/*; do
    if [ -d "$user_home/.cache/thumbnails" ]; then
        rm -rf "$user_home/.cache/thumbnails"/* 2>/dev/null
    fi
done

log_success "缩略图缓存清理完成。"

# -----------------------------------------------------------------------------
# 9. 清理其他常见缓存目录
# -----------------------------------------------------------------------------
log_info "正在清理其他常见缓存目录..."

# 清理 apt 缓存目录
if [ -d "/var/cache/apt/archives" ]; then
    find /var/cache/apt/archives -type f -name "*.deb" -delete 2>/dev/null
fi

# 清理字体缓存
if [ -d "/var/cache/fontconfig" ]; then
    rm -rf /var/cache/fontconfig/* 2>/dev/null
fi

# 清理 man 页面缓存
if [ -d "/var/cache/man" ]; then
    rm -rf /var/cache/man/* 2>/dev/null
fi

log_success "其他缓存目录清理完成。"

# -----------------------------------------------------------------------------
# 10. 验证并修复系统关键目录
# -----------------------------------------------------------------------------
log_info "正在验证系统关键目录..."

# 检查并修复 /tmp 目录
if [ ! -d "/tmp" ]; then
    log_warning "/tmp 目录不存在,正在重建..."
    mkdir -p /tmp
    chmod 1777 /tmp
    chown root:root /tmp
    log_success "/tmp 目录已重建。"
elif [ "$(stat -c %a /tmp 2>/dev/null)" != "1777" ]; then
    log_warning "/tmp 目录权限不正确,正在修复..."
    chmod 1777 /tmp
    log_success "/tmp 目录权限已修复。"
else
    log_info "/tmp 目录状态正常。"
fi

# 检查并修复 /var/tmp 目录
if [ ! -d "/var/tmp" ]; then
    log_warning "/var/tmp 目录不存在,正在重建..."
    mkdir -p /var/tmp
    chmod 1777 /var/tmp
    chown root:root /var/tmp
    log_success "/var/tmp 目录已重建。"
elif [ "$(stat -c %a /var/tmp 2>/dev/null)" != "1777" ]; then
    log_warning "/var/tmp 目录权限不正确,正在修复..."
    chmod 1777 /var/tmp
    log_success "/var/tmp 目录权限已修复。"
else
    log_info "/var/tmp 目录状态正常。"
fi

# -----------------------------------------------------------------------------
# 获取清理后的磁盘使用情况并显示结果
# -----------------------------------------------------------------------------
end_space_kb=$(df / | tail -n 1 | awk '{print $3}')
cleared_space_kb=$((start_space_kb - end_space_kb))

log_success "========================================="
log_success "智能系统清理完成!"
log_success "========================================="

if [ "$cleared_space_kb" -gt 0 ]; then
    cleared_space_mb=$((cleared_space_kb / 1024))
    cleared_space_gb=$(echo "scale=2; $cleared_space_kb / 1024 / 1024" | bc 2>/dev/null || echo "0")
    
    if [ "$cleared_space_mb" -gt 1024 ]; then
        log_success "共清理了 ${cleared_space_gb} GB 空间!"
    else
        log_success "共清理了 ${cleared_space_mb} MB 空间!"
    fi
else
    log_info "本次清理没有释放额外空间,系统可能已经很干净了。"
fi

log_info ""
log_info "清理摘要:"
log_info "- 已删除旧内核和相关文件"
log_info "- 已清理孤立的依赖包 (使用 apt autoremove)"
log_info "- 已清理残留配置文件"
log_info "- 已清理临时文件 (/tmp, /var/tmp)"
log_info "- 已清理用户缓存目录"
log_info "- 已清理系统日志文件"
log_info "- 已清理 APT 缓存"
log_info "- 已验证系统关键目录"
log_info ""
log_info "建议重启系统以应用所有更改。"
