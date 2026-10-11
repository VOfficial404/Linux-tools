#!/bin/bash
#
# Debian 系统清理脚本
# 支持 Debian 12 (Bookworm) 和 Debian 13 (Trixie)
# 功能：清理旧内核、孤立包、日志文件、缓存和 Docker 数据
#

set -o pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否以 root 权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 权限运行"
        echo "请使用: sudo $0"
        exit 1
    fi
}

# 检测 Debian 版本
detect_debian_version() {
    if [ -f /etc/debian_version ]; then
        DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
        DEBIAN_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
        log_info "检测到 Debian 版本: $DEBIAN_VERSION ($DEBIAN_CODENAME)"
    else
        log_warning "无法检测 Debian 版本，继续执行..."
        DEBIAN_VERSION="unknown"
        DEBIAN_CODENAME="unknown"
    fi
}

# 获取磁盘使用情况（KB）
get_disk_usage() {
    df / | tail -n 1 | awk '{print $3}'
}

# 格式化空间大小
format_space() {
    local kb=$1
    if [ $kb -ge 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $kb/1048576}") GB"
    elif [ $kb -ge 1024 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $kb/1024}") MB"
    else
        echo "${kb} KB"
    fi
}

# 更新包列表
update_package_list() {
    log_info "正在更新软件包列表..."
    if apt-get update > /dev/null 2>&1; then
        log_success "软件包列表更新成功"
        return 0
    else
        log_warning "软件包列表更新失败，继续执行..."
        return 1
    fi
}

# 清理旧内核
clean_old_kernels() {
    log_info "正在检查旧内核..."

    local current_kernel=$(uname -r)
    log_info "当前运行的内核: $current_kernel"

    # 查找旧内核包
    local kernel_packages=$(dpkg --list | grep -E '^ii  linux-(image|headers|modules)-[0-9]+' | awk '{ print $2 }' | grep -v "$current_kernel" | grep -v "linux-image-amd64" | grep -v "linux-headers-amd64")

    if [ -z "$kernel_packages" ]; then
        log_success "没有旧内核需要删除"
        return 0
    fi

    log_info "找到以下旧内核包："
    echo "$kernel_packages" | while read pkg; do
        echo "  - $pkg"
    done

    log_info "正在删除旧内核..."
    if echo "$kernel_packages" | xargs apt-get purge -y > /dev/null 2>&1; then
        log_success "旧内核删除成功"

        # 更新 GRUB
        log_info "正在更新 GRUB..."
        if update-grub > /dev/null 2>&1; then
            log_success "GRUB 更新成功"
        else
            log_warning "GRUB 更新失败"
        fi
    else
        log_warning "部分旧内核删除失败"
    fi
}

# 清理孤立的包
clean_orphaned_packages() {
    log_info "正在清理不再需要的依赖包..."

    # Debian 12 和 13 都使用 apt autoremove
    local orphaned_count=$(apt-get --dry-run autoremove 2>/dev/null | grep -Po '^Remv \K[^ ]+' | wc -l)

    if [ "$orphaned_count" -gt 0 ]; then
        log_info "找到 $orphaned_count 个不再需要的包"
        if apt-get autoremove --purge -y > /dev/null 2>&1; then
            log_success "孤立包清理成功"
        else
            log_warning "孤立包清理失败"
        fi
    else
        log_success "没有孤立的包需要清理"
    fi
}

# 清理系统日志文件
clean_system_logs() {
    log_info "正在清理系统日志文件..."

    local cleaned=0

    # 清理 /var/log 下的 .log 文件（修复原脚本的错误）
    if find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null; then
        ((cleaned++))
    fi

    # 清理 /root 下的 .log 文件
    if find /root -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null; then
        ((cleaned++))
    fi

    # 清理旧的日志归档文件
    find /var/log -type f \( -name "*.log.[0-9]*" -o -name "*.log.*.gz" \) -mtime +7 -delete 2>/dev/null

    log_success "系统日志文件清理完成"
}

# 清理 journald 日志
clean_journald_logs() {
    log_info "正在清理 systemd 日志..."

    if command -v journalctl &> /dev/null; then
        # 保留最近 7 天的日志，限制总大小为 500MB
        if journalctl --vacuum-time=7d --vacuum-size=500M > /dev/null 2>&1; then
            log_success "systemd 日志清理成功"
        else
            log_warning "systemd 日志清理失败"
        fi
    else
        log_info "系统未使用 systemd journal，跳过"
    fi
}

# 清理临时文件
clean_temp_files() {
    log_info "正在清理临时文件..."

    # 清理 /tmp（排除当前正在使用的文件）
    find /tmp -type f -atime +7 -delete 2>/dev/null || true
    find /tmp -type d -empty -delete 2>/dev/null || true

    # 清理 /var/tmp（排除当前正在使用的文件）
    find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    find /var/tmp -type d -empty -delete 2>/dev/null || true

    log_success "临时文件清理完成"
}

# 清理用户缓存
clean_user_caches() {
    log_info "正在清理用户缓存目录..."

    # 清理 root 用户缓存
    if [ -d "/root/.cache" ]; then
        rm -rf /root/.cache/* 2>/dev/null || true
    fi

    # 清理 pip 缓存
    if [ -d "/root/.cache/pip" ]; then
        rm -rf /root/.cache/pip 2>/dev/null || true
    fi

    # 清理其他用户的缓存（修复原脚本的路径错误）
    for user_dir in /home/*; do
        if [ -d "$user_dir/.cache" ]; then
            local username=$(basename "$user_dir")
            # 只清理部分缓存，避免影响用户体验
            find "$user_dir/.cache" -type f -atime +30 -delete 2>/dev/null || true
            log_info "  清理用户 $username 的缓存"
        fi
    done

    log_success "用户缓存清理完成"
}

# 清理 APT 缓存
clean_apt_cache() {
    log_info "正在清理 APT 缓存..."

    # 清理已下载的包文件
    apt-get clean > /dev/null 2>&1

    # 清理部分下载的包文件
    apt-get autoclean > /dev/null 2>&1

    # 清理归档文件
    rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
    rm -rf /var/cache/apt/archives/partial/*.deb 2>/dev/null || true

    log_success "APT 缓存清理完成"
}

# 清理 Docker（可选）
clean_docker() {
    if ! command -v docker &> /dev/null; then
        log_info "未检测到 Docker，跳过清理"
        return 0
    fi

    log_info "检测到 Docker，正在清理..."

    # 检查 Docker 是否运行
    if ! docker info > /dev/null 2>&1; then
        log_warning "Docker 服务未运行，跳过 Docker 清理"
        return 0
    fi

    # 只清理未使用的数据，保留运行中的容器和镜像
    log_info "  清理未使用的 Docker 资源..."
    if docker system prune -f --volumes > /dev/null 2>&1; then
        log_success "Docker 清理成功（保留了使用中的镜像和容器）"
    else
        log_warning "Docker 清理失败"
    fi

    # 如果需要清理所有未使用的镜像，取消下面的注释
    # docker system prune -a -f --volumes > /dev/null 2>&1
}

# 清理包管理器缓存
clean_package_manager_cache() {
    log_info "正在执行最终包管理器清理..."

    apt-get autoremove -y > /dev/null 2>&1
    apt-get autoclean > /dev/null 2>&1
    apt-get clean > /dev/null 2>&1

    log_success "包管理器清理完成"
}

# 显示摘要
show_summary() {
    local start_space=$1
    local end_space=$2

    echo ""
    echo "========================================"
    log_success "系统清理完成！"
    echo "========================================"

    local cleared_space=$((start_space - end_space))

    # 处理负数情况（可能由于清理过程中有新文件写入）
    if [ $cleared_space -lt 0 ]; then
        log_info "磁盘使用量变化: 增加了 $(format_space ${cleared_space#-})"
        log_info "（这可能是因为清理过程中有新的日志或缓存写入）"
    else
        log_success "释放的磁盘空间: $(format_space $cleared_space)"
    fi

    echo ""
    log_info "当前磁盘使用情况:"
    df -h / | tail -n 1 | awk '{printf "  使用: %s / %s (%s)\n", $3, $2, $5}'
    echo ""
}

# 主函数
main() {
    echo "========================================"
    echo "  Debian 系统清理脚本"
    echo "  支持 Debian 12/13"
    echo "========================================"
    echo ""

    # 检查 root 权限
    check_root

    # 检测系统版本
    detect_debian_version

    echo ""

    # 记录开始时的磁盘使用情况
    local start_space=$(get_disk_usage)
    log_info "清理前磁盘使用: $(format_space $start_space)"

    echo ""
    echo "开始清理..."
    echo "----------------------------------------"

    # 执行清理操作
    update_package_list
    clean_old_kernels
    clean_orphaned_packages
    clean_system_logs
    clean_journald_logs
    clean_temp_files
    clean_user_caches
    clean_apt_cache
    clean_docker
    clean_package_manager_cache

    # 记录结束时的磁盘使用情况
    local end_space=$(get_disk_usage)

    # 显示摘要
    show_summary $start_space $end_space

    log_info "建议重启系统以确保所有更改生效"
}

# 运行主函数
main "$@"
