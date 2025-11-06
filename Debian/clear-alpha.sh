#!/bin/bash

# -----------------------------------------------------------------------------
# 智能系统清理脚本 v4.0 (增强美化版)
# 特性:
# - 美观的终端输出界面
# - 详细显示每项清理的具体内容
# - 不安装任何额外软件包
# - 修复所有已知问题
# -----------------------------------------------------------------------------

# 颜色和样式定义
if command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    MAGENTA=$(tput setaf 5)
    CYAN=$(tput setaf 6)
    WHITE=$(tput setaf 7)
    BOLD=$(tput bold)
    NC=$(tput sgr0)
else
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    MAGENTA=$'\033[0;35m'
    CYAN=$'\033[0;36m'
    WHITE=$'\033[0;37m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
fi

# 全局统计变量
TOTAL_ITEMS_CLEANED=0
TOTAL_FILES_DELETED=0

# 增强的日志函数
print_header() {
    echo ""
    echo "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "${BOLD}${CYAN}  $1${NC}"
    echo "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_section() {
    echo ""
    echo "${BOLD}${MAGENTA}▶ $1${NC}"
    echo "${MAGENTA}────────────────────────────────────────────────────────────────────${NC}"
}

print_item() {
    echo "${CYAN}  ➜${NC} $1"
}

print_detail() {
    echo "${WHITE}    ├─ $1${NC}"
}

print_result() {
    echo "${WHITE}    └─ ${GREEN}✓${NC} $1${NC}"
}

log_info() { 
    printf "${BLUE}[信息]${NC} %s\n" "$1"
}

log_success() { 
    printf "${GREEN}[成功]${NC} %s\n" "$1"
}

log_warning() { 
    printf "${YELLOW}[警告]${NC} %s\n" "$1"
}

log_error() { 
    printf "${RED}[错误]${NC} %s\n" "$1"
}

# 计算文件大小的函数
get_size_mb() {
    local size_kb=$1
    echo $((size_kb / 1024))
}

get_size_human() {
    local size_kb=$1
    if [ "$size_kb" -gt 1048576 ]; then
        echo "$(echo "scale=2; $size_kb / 1024 / 1024" | bc 2>/dev/null || echo "0") GB"
    elif [ "$size_kb" -gt 1024 ]; then
        echo "$(echo "scale=2; $size_kb / 1024" | bc 2>/dev/null || echo "0") MB"
    else
        echo "${size_kb} KB"
    fi
}

# 统计文件数量的函数
count_files() {
    local path=$1
    local pattern=$2
    local count=0
    
    if [ -n "$pattern" ]; then
        count=$(eval find "$path" $pattern 2>/dev/null | wc -l)
    else
        count=$(find "$path" 2>/dev/null | wc -l)
    fi
    
    echo "$count"
}

# 确保脚本以root权限运行
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以root权限运行。请使用 'sudo $0' 执行。"
   exit 1
fi

# 显示欢迎界面
clear
echo ""
echo "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo "${BOLD}${GREEN}║                                                                   ║${NC}"
echo "${BOLD}${GREEN}║           智能系统清理工具 v4.0 (增强美化版)                      ║${NC}"
echo "${BOLD}${GREEN}║                                                                   ║${NC}"
echo "${BOLD}${GREEN}║   特性: 详细输出 | 美观界面 | 无额外依赖 | 安全可靠              ║${NC}"
echo "${BOLD}${GREEN}║                                                                   ║${NC}"
echo "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "正在启动系统清理程序..."
sleep 1

# 获取清理前的磁盘使用情况
start_space_kb=$(df / | tail -n 1 | awk '{print $3}')
start_space_human=$(get_size_human "$start_space_kb")

print_section "系统信息"
print_item "操作系统: $(lsb_release -d 2>/dev/null | cut -f2 || echo "未知")"
print_item "内核版本: $(uname -r)"
print_item "当前磁盘使用: $start_space_human"
echo ""

# -----------------------------------------------------------------------------
# 1. 安全删除旧内核
# -----------------------------------------------------------------------------
print_header "步骤 1/10: 清理旧内核"

current_kernel=$(uname -r)
print_item "当前内核版本: ${BOLD}$current_kernel${NC}"

kernel_packages=$(dpkg --list 2>/dev/null | grep -E '^ii  linux-(image|headers)-[0-9]+' | awk '{print $2}' | grep -vF -- "$current_kernel" | grep -vE -- '-virtual|-generic-lts-')

if [ -n "$kernel_packages" ]; then
    kernel_count=$(echo "$kernel_packages" | wc -l)
    print_detail "发现 ${YELLOW}$kernel_count${NC} 个旧内核包"
    
    echo "${WHITE}    ├─ 旧内核列表:${NC}"
    echo "$kernel_packages" | while read -r pkg; do
        echo "${WHITE}    │  • $pkg${NC}"
    done
    
    print_detail "正在删除旧内核..."
    if apt-get purge --assume-yes "$kernel_packages" > /dev/null 2>&1; then
        print_result "成功删除 $kernel_count 个旧内核包"
        TOTAL_ITEMS_CLEANED=$((TOTAL_ITEMS_CLEANED + kernel_count))
        
        print_detail "正在更新 GRUB 引导配置..."
        update-grub > /dev/null 2>&1
        print_result "GRUB 配置已更新"
    else
        log_error "旧内核删除失败"
    fi
else
    print_result "没有发现需要删除的旧内核"
fi

# -----------------------------------------------------------------------------
# 2. 清理孤立的包和残留配置
# -----------------------------------------------------------------------------
print_header "步骤 2/10: 清理孤立包和残留配置"

# 2.1 清理孤立依赖包
print_item "检查孤立的依赖包..."
orphaned_count=$(apt-get autoremove --dry-run 2>/dev/null | grep -oP '^\d+(?= 个不再需要)' || echo "0")

if [ "$orphaned_count" -gt 0 ]; then
    print_detail "发现 ${YELLOW}$orphaned_count${NC} 个孤立的依赖包"
    
    # 显示将要删除的包
    apt-get autoremove --dry-run 2>/dev/null | grep "^  " | head -10 | while read -r pkg; do
        echo "${WHITE}    │  • $pkg${NC}"
    done
    
    if [ "$orphaned_count" -gt 10 ]; then
        echo "${WHITE}    │  ... 还有 $((orphaned_count - 10)) 个包${NC}"
    fi
    
    print_detail "正在删除孤立依赖包..."
    if apt-get autoremove -y > /dev/null 2>&1; then
        print_result "成功删除 $orphaned_count 个孤立依赖包"
        TOTAL_ITEMS_CLEANED=$((TOTAL_ITEMS_CLEANED + orphaned_count))
    else
        log_warning "孤立依赖包清理失败"
    fi
else
    print_result "没有发现孤立的依赖包"
fi

# 2.2 清理残留配置文件
print_item "检查残留配置文件..."
residual_configs=$(dpkg -l 2>/dev/null | grep '^rc' | awk '{print $2}')

if [ -n "$residual_configs" ]; then
    residual_count=$(echo "$residual_configs" | wc -l)
    print_detail "发现 ${YELLOW}$residual_count${NC} 个残留配置文件"
    
    echo "${WHITE}    ├─ 残留配置列表:${NC}"
    echo "$residual_configs" | head -10 | while read -r pkg; do
        echo "${WHITE}    │  • $pkg${NC}"
    done
    
    if [ "$residual_count" -gt 10 ]; then
        echo "${WHITE}    │  ... 还有 $((residual_count - 10)) 个配置${NC}"
    fi
    
    print_detail "正在清理残留配置..."
    if echo "$residual_configs" | xargs apt-get purge -y > /dev/null 2>&1; then
        print_result "成功清理 $residual_count 个残留配置"
        TOTAL_ITEMS_CLEANED=$((TOTAL_ITEMS_CLEANED + residual_count))
    else
        log_warning "残留配置清理失败"
    fi
else
    print_result "没有发现残留配置文件"
fi

# -----------------------------------------------------------------------------
# 3. 清理临时文件
# -----------------------------------------------------------------------------
print_header "步骤 3/10: 清理临时文件"

# 清理 /tmp
print_item "清理 /tmp 目录..."
if [ -d "/tmp" ]; then
    tmp_files_before=$(count_files "/tmp" "-maxdepth 1 -type f -atime +7")
    
    if [ "$tmp_files_before" -gt 0 ]; then
        print_detail "发现 ${YELLOW}$tmp_files_before${NC} 个超过 7 天的临时文件"
        
        # 显示一些示例文件
        find /tmp -maxdepth 1 -type f -atime +7 2>/dev/null | head -5 | while read -r file; do
            file_size=$(du -h "$file" 2>/dev/null | cut -f1)
            file_name=$(basename "$file")
            echo "${WHITE}    │  • $file_name ($file_size)${NC}"
        done
        
        if [ "$tmp_files_before" -gt 5 ]; then
            echo "${WHITE}    │  ... 还有 $((tmp_files_before - 5)) 个文件${NC}"
        fi
        
        find /tmp -maxdepth 1 -type f -atime +7 -delete 2>/dev/null
        find /tmp -mindepth 2 -type d -empty -delete 2>/dev/null
        
        print_result "成功清理 $tmp_files_before 个临时文件"
        TOTAL_FILES_DELETED=$((TOTAL_FILES_DELETED + tmp_files_before))
    else
        print_result "没有发现需要清理的临时文件"
    fi
else
    log_warning "/tmp 目录不存在"
fi

# 清理 /var/tmp
print_item "清理 /var/tmp 目录..."
if [ -d "/var/tmp" ]; then
    vartmp_files_before=$(count_files "/var/tmp" "-maxdepth 1 -type f -atime +7")
    
    if [ "$vartmp_files_before" -gt 0 ]; then
        print_detail "发现 ${YELLOW}$vartmp_files_before${NC} 个超过 7 天的临时文件"
        
        find /var/tmp -maxdepth 1 -type f -atime +7 -delete 2>/dev/null
        find /var/tmp -mindepth 2 -type d -empty -delete 2>/dev/null
        
        print_result "成功清理 $vartmp_files_before 个临时文件"
        TOTAL_FILES_DELETED=$((TOTAL_FILES_DELETED + vartmp_files_before))
    else
        print_result "没有发现需要清理的临时文件"
    fi
else
    log_warning "/var/tmp 目录不存在"
fi

# -----------------------------------------------------------------------------
# 4. 清理用户缓存
# -----------------------------------------------------------------------------
print_header "步骤 4/10: 清理用户缓存目录"

# 清理普通用户缓存
user_count=0
for user_home in /home/*; do
    if [ -d "$user_home/.cache" ]; then
        user_name=$(basename "$user_home")
        print_item "清理用户 ${BOLD}$user_name${NC} 的缓存..."
        
        cache_files=$(count_files "$user_home/.cache" "-type f -atime +30")
        
        if [ "$cache_files" -gt 0 ]; then
            cache_size=$(du -sh "$user_home/.cache" 2>/dev/null | cut -f1)
            print_detail "缓存目录大小: $cache_size"
            print_detail "发现 ${YELLOW}$cache_files${NC} 个超过 30 天的缓存文件"
            
            find "$user_home/.cache" -type f -atime +30 -delete 2>/dev/null
            find "$user_home/.cache" -type d -empty -delete 2>/dev/null
            
            print_result "成功清理 $cache_files 个缓存文件"
            TOTAL_FILES_DELETED=$((TOTAL_FILES_DELETED + cache_files))
            user_count=$((user_count + 1))
        else
            print_result "没有需要清理的缓存文件"
        fi
    fi
done

# 清理 root 用户缓存
if [ -d "/root/.cache" ]; then
    print_item "清理 ${BOLD}root${NC} 用户的缓存..."
    
    root_cache_files=$(count_files "/root/.cache" "-type f -atime +30")
    
    if [ "$root_cache_files" -gt 0 ]; then
        root_cache_size=$(du -sh "/root/.cache" 2>/dev/null | cut -f1)
        print_detail "缓存目录大小: $root_cache_size"
        print_detail "发现 ${YELLOW}$root_cache_files${NC} 个超过 30 天的缓存文件"
        
        find "/root/.cache" -type f -atime +30 -delete 2>/dev/null
        find "/root/.cache" -type d -empty -delete 2>/dev/null
        
        print_result "成功清理 $root_cache_files 个缓存文件"
        TOTAL_FILES_DELETED=$((TOTAL_FILES_DELETED + root_cache_files))
    else
        print_result "没有需要清理的缓存文件"
    fi
fi

if [ "$user_count" -eq 0 ] && [ "$root_cache_files" -eq 0 ]; then
    print_result "所有用户缓存都很干净"
fi

# -----------------------------------------------------------------------------
# 5. 清理系统日志
# -----------------------------------------------------------------------------
print_header "步骤 5/10: 清理系统日志文件"

# journalctl 清理
print_item "清理 systemd 日志 (journalctl)..."
if command -v journalctl >/dev/null 2>&1; then
    journal_size_before=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[GM]' | head -1)
    print_detail "当前日志大小: $journal_size_before"
    
    if journalctl --vacuum-time=7d --vacuum-size=1G > /dev/null 2>&1; then
        journal_size_after=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[GM]' | head -1)
        print_result "日志已压缩到 $journal_size_after (保留最近 7 天,最大 1GB)"
    else
        log_warning "journalctl 清理失败"
    fi
else
    print_result "未检测到 journalctl"
fi

# logrotate 清理
print_item "执行日志轮换 (logrotate)..."
if command -v logrotate >/dev/null 2>&1; then
    if logrotate -f /etc/logrotate.conf > /dev/null 2>&1; then
        print_result "日志轮换完成"
    else
        log_warning "logrotate 执行失败"
    fi
else
    print_result "未检测到 logrotate"
fi

# 清理 /var/log 下的旧日志
print_item "清理 /var/log 下的旧日志文件..."
if [ -d "/var/log" ]; then
    old_logs=$(find /var/log -type f \( -name "*.log" -o -name "*.gz" -o -name "*.old" \) -atime +30 2>/dev/null | wc -l)
    
    if [ "$old_logs" -gt 0 ]; then
        print_detail "发现 ${YELLOW}$old_logs${NC} 个超过 30 天的日志文件"
        
        # 显示一些示例
        find /var/log -type f \( -name "*.log" -o -name "*.gz" -o -name "*.old" \) -atime +30 2>/dev/null | head -5 | while read -r log; do
            log_size=$(du -h "$log" 2>/dev/null | cut -f1)
            log_name=$(basename "$log")
            echo "${WHITE}    │  • $log_name ($log_size)${NC}"
        done
        
        if [ "$old_logs" -gt 5 ]; then
            echo "${WHITE}    │  ... 还有 $((old_logs - 5)) 个日志文件${NC}"
        fi
        
        find /var/log -type f -name "*.log" -atime +30 -delete 2>/dev/null
        find /var/log -type f -name "*.gz" -atime +30 -delete 2>/dev/null
        find /var/log -type f -name "*.old" -atime +30 -delete 2>/dev/null
        
        print_result "成功清理 $old_logs 个旧日志文件"
        TOTAL_FILES_DELETED=$((TOTAL_FILES_DELETED + old_logs))
    else
        print_result "没有需要清理的旧日志文件"
    fi
fi

# -----------------------------------------------------------------------------
# 6. 清理 APT 缓存
# -----------------------------------------------------------------------------
print_header "步骤 6/10: 清理 APT 缓存"

print_item "检查 APT 缓存大小..."
if [ -d "/var/cache/apt/archives" ]; then
    apt_cache_size=$(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1)
    apt_cache_files=$(find /var/cache/apt/archives -type f -name "*.deb" 2>/dev/null | wc -l)
    
    print_detail "缓存目录大小: $apt_cache_size"
    print_detail "缓存包数量: ${YELLOW}$apt_cache_files${NC} 个"
    
    if [ "$apt_cache_files" -gt 0 ]; then
        # 显示一些示例包
        echo "${WHITE}    ├─ 部分缓存包:${NC}"
        find /var/cache/apt/archives -type f -name "*.deb" 2>/dev/null | head -5 | while read -r deb; do
            deb_size=$(du -h "$deb" 2>/dev/null | cut -f1)
            deb_name=$(basename "$deb")
            echo "${WHITE}    │  • $deb_name ($deb_size)${NC}"
        done
        
        if [ "$apt_cache_files" -gt 5 ]; then
            echo "${WHITE}    │  ... 还有 $((apt_cache_files - 5)) 个包${NC}"
        fi
    fi
fi

print_item "执行 APT 清理..."
print_detail "运行 apt-get autoclean..."
apt-get autoclean > /dev/null 2>&1

print_detail "运行 apt-get autoremove..."
apt-get autoremove -y > /dev/null 2>&1

print_detail "运行 apt-get clean..."
apt-get clean > /dev/null 2>&1

print_result "APT 缓存清理完成"

# -----------------------------------------------------------------------------
# 7. 清理 Docker (如果存在)
# -----------------------------------------------------------------------------
print_header "步骤 7/10: 清理 Docker 资源"

if command -v docker &> /dev/null; then
    print_item "检测到 Docker,正在分析资源使用..."
    
    # 显示 Docker 资源统计
    docker_images=$(docker images -q 2>/dev/null | wc -l)
    docker_containers=$(docker ps -aq 2>/dev/null | wc -l)
    docker_volumes=$(docker volume ls -q 2>/dev/null | wc -l)
    
    print_detail "镜像数量: $docker_images"
    print_detail "容器数量: $docker_containers"
    print_detail "卷数量: $docker_volumes"
    
    read -r -p "${YELLOW}警告:此操作将删除所有未使用的 Docker 镜像、容器、网络和卷。是否继续? (y/N)${NC} " confirm_docker_prune
    
    if [[ "$confirm_docker_prune" =~ ^[Yy]$ ]]; then
        print_detail "正在清理 Docker 资源..."
        if docker system prune -a --volumes --force > /dev/null 2>&1; then
            print_result "Docker 资源清理完成"
        else
            log_error "Docker 资源清理失败"
        fi
    else
        print_result "已跳过 Docker 清理"
    fi
else
    print_result "未检测到 Docker"
fi

# -----------------------------------------------------------------------------
# 8. 清理缩略图缓存
# -----------------------------------------------------------------------------
print_header "步骤 8/10: 清理缩略图缓存"

thumbnail_cleaned=0

# 清理 root 用户
if [ -d "$HOME/.cache/thumbnails" ]; then
    thumb_count=$(find "$HOME/.cache/thumbnails" -type f 2>/dev/null | wc -l)
    if [ "$thumb_count" -gt 0 ]; then
        print_item "清理 root 用户的缩略图..."
        print_detail "发现 ${YELLOW}$thumb_count${NC} 个缩略图文件"
        rm -rf "$HOME/.cache/thumbnails"/* 2>/dev/null
        print_result "成功清理 $thumb_count 个缩略图"
        thumbnail_cleaned=$((thumbnail_cleaned + thumb_count))
    fi
fi

# 清理所有用户
for user_home in /home/*; do
    if [ -d "$user_home/.cache/thumbnails" ]; then
        user_name=$(basename "$user_home")
        thumb_count=$(find "$user_home/.cache/thumbnails" -type f 2>/dev/null | wc -l)
        
        if [ "$thumb_count" -gt 0 ]; then
            print_item "清理用户 ${BOLD}$user_name${NC} 的缩略图..."
            print_detail "发现 ${YELLOW}$thumb_count${NC} 个缩略图文件"
            rm -rf "$user_home/.cache/thumbnails"/* 2>/dev/null
            print_result "成功清理 $thumb_count 个缩略图"
            thumbnail_cleaned=$((thumbnail_cleaned + thumb_count))
        fi
    fi
done

if [ "$thumbnail_cleaned" -eq 0 ]; then
    print_result "没有需要清理的缩略图"
else
    TOTAL_FILES_DELETED=$((TOTAL_FILES_DELETED + thumbnail_cleaned))
fi

# -----------------------------------------------------------------------------
# 9. 清理其他缓存
# -----------------------------------------------------------------------------
print_header "步骤 9/10: 清理其他系统缓存"

# 字体缓存
print_item "清理字体缓存..."
if [ -d "/var/cache/fontconfig" ]; then
    font_cache_size=$(du -sh /var/cache/fontconfig 2>/dev/null | cut -f1)
    print_detail "字体缓存大小: $font_cache_size"
    rm -rf /var/cache/fontconfig/* 2>/dev/null
    print_result "字体缓存已清理"
else
    print_result "未发现字体缓存"
fi

# man 页面缓存
print_item "清理 man 页面缓存..."
if [ -d "/var/cache/man" ]; then
    man_cache_size=$(du -sh /var/cache/man 2>/dev/null | cut -f1)
    print_detail "man 缓存大小: $man_cache_size"
    rm -rf /var/cache/man/* 2>/dev/null
    print_result "man 缓存已清理"
else
    print_result "未发现 man 缓存"
fi

# -----------------------------------------------------------------------------
# 10. 验证系统关键目录
# -----------------------------------------------------------------------------
print_header "步骤 10/10: 验证系统关键目录"

# 检查 /tmp
print_item "验证 /tmp 目录..."
if [ ! -d "/tmp" ]; then
    log_warning "/tmp 目录不存在,正在重建..."
    mkdir -p /tmp
    chmod 1777 /tmp
    chown root:root /tmp
    print_result "/tmp 目录已重建"
elif [ "$(stat -c %a /tmp 2>/dev/null)" != "1777" ]; then
    log_warning "/tmp 目录权限不正确,正在修复..."
    chmod 1777 /tmp
    print_result "/tmp 目录权限已修复为 1777"
else
    print_result "/tmp 目录状态正常 (权限: 1777)"
fi

# 检查 /var/tmp
print_item "验证 /var/tmp 目录..."
if [ ! -d "/var/tmp" ]; then
    log_warning "/var/tmp 目录不存在,正在重建..."
    mkdir -p /var/tmp
    chmod 1777 /var/tmp
    chown root:root /var/tmp
    print_result "/var/tmp 目录已重建"
elif [ "$(stat -c %a /var/tmp 2>/dev/null)" != "1777" ]; then
    log_warning "/var/tmp 目录权限不正确,正在修复..."
    chmod 1777 /var/tmp
    print_result "/var/tmp 目录权限已修复为 1777"
else
    print_result "/var/tmp 目录状态正常 (权限: 1777)"
fi

# -----------------------------------------------------------------------------
# 显示清理总结
# -----------------------------------------------------------------------------
end_space_kb=$(df / | tail -n 1 | awk '{print $3}')
cleared_space_kb=$((start_space_kb - end_space_kb))
end_space_human=$(get_size_human "$end_space_kb")

echo ""
echo "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo "${BOLD}${GREEN}║                        清理完成!                                  ║${NC}"
echo "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

print_section "清理统计"

if [ "$cleared_space_kb" -gt 0 ]; then
    cleared_space_human=$(get_size_human "$cleared_space_kb")
    
    print_item "${BOLD}${GREEN}释放空间: $cleared_space_human${NC}"
    print_detail "清理前: $start_space_human"
    print_detail "清理后: $end_space_human"
else
    print_item "本次清理没有释放额外空间"
    print_detail "系统已经很干净了!"
fi

echo ""
print_item "清理项目统计:"
print_detail "软件包/配置项: ${GREEN}$TOTAL_ITEMS_CLEANED${NC} 个"
print_detail "文件数量: ${GREEN}$TOTAL_FILES_DELETED${NC} 个"

echo ""
print_section "清理项目明细"
echo "${WHITE}  ✓ 旧内核和相关文件${NC}"
echo "${WHITE}  ✓ 孤立的依赖包${NC}"
echo "${WHITE}  ✓ 残留配置文件${NC}"
echo "${WHITE}  ✓ 临时文件 (/tmp, /var/tmp)${NC}"
echo "${WHITE}  ✓ 用户缓存目录${NC}"
echo "${WHITE}  ✓ 系统日志文件${NC}"
echo "${WHITE}  ✓ APT 缓存${NC}"
echo "${WHITE}  ✓ 缩略图缓存${NC}"
echo "${WHITE}  ✓ 其他系统缓存${NC}"
echo "${WHITE}  ✓ 系统目录验证${NC}"

echo ""
log_info "${BOLD}建议重启系统以应用所有更改。${NC}"
echo ""
