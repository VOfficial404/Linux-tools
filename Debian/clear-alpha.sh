#!/bin/bash

# 颜色定义
if command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    BOLD=$(tput bold)
    NC=$(tput sgr0)
else
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
fi

# 日志函数
log_info() { printf "${BLUE}[信息]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[成功]${NC} %s\n" "$1"; }
log_warning() { printf "${YELLOW}[警告]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[错误]${NC} %s\n" "$1"; }

# 打印分隔线
print_separator() {
    echo "----------------------------------------"
}

# 确保脚本以root权限运行
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以root权限运行。请使用 'sudo $0' 执行。"
   exit 1
fi

# 获取清理前的磁盘使用情况
start_space_kb=$(df / | tail -n 1 | awk '{print $3}')

# -----------------------------------------------------------------------------
# 1. 清理旧内核
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[1/10] 清理旧内核${NC}"
print_separator

current_kernel=$(uname -r)
echo "当前内核: $current_kernel"

kernel_packages=$(dpkg --list 2>/dev/null | grep -E '^ii  linux-(image|headers)-[0-9]+' | awk '{print $2}' | grep -vF -- "$current_kernel" | grep -vE -- '-virtual|-generic-lts-')

if [ -n "$kernel_packages" ]; then
    echo ""
    echo "发现以下旧内核:"
    echo "$kernel_packages"
    echo ""
    
    log_info "正在删除旧内核..."
    if echo "$kernel_packages" | xargs apt-get purge --assume-yes 2>&1 | grep -E '^(正在|Removing|Purging|删除)'; then
        log_success "旧内核删除完成"
        update-grub > /dev/null 2>&1
        log_success "GRUB 配置已更新"
    else
        log_error "旧内核删除失败"
    fi
else
    log_info "没有需要删除的旧内核"
fi

# -----------------------------------------------------------------------------
# 2. 清理孤立包
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[2/10] 清理孤立的依赖包${NC}"
print_separator

echo "正在检查孤立包..."
orphaned_list=$(apt-get autoremove --dry-run 2>/dev/null | grep "^  " | sed 's/^  //')

if [ -n "$orphaned_list" ]; then
    echo ""
    echo "发现以下孤立包:"
    echo "$orphaned_list"
    echo ""
    
    log_info "正在删除孤立包..."
    apt-get autoremove -y 2>&1 | grep -E '^(正在|Removing|删除|The following)'
    log_success "孤立包清理完成"
else
    log_info "没有孤立的依赖包"
fi

# -----------------------------------------------------------------------------
# 3. 清理残留配置
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[3/10] 清理残留配置文件${NC}"
print_separator

residual_configs=$(dpkg -l 2>/dev/null | grep '^rc' | awk '{print $2}')

if [ -n "$residual_configs" ]; then
    echo ""
    echo "发现以下残留配置:"
    echo "$residual_configs"
    echo ""
    
    log_info "正在清理残留配置..."
    echo "$residual_configs" | xargs apt-get purge -y 2>&1 | grep -E '^(正在|Removing|Purging|删除)'
    log_success "残留配置清理完成"
else
    log_info "没有残留配置文件"
fi

# -----------------------------------------------------------------------------
# 4. 清理临时文件
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[4/10] 清理临时文件${NC}"
print_separator

# 清理 /tmp
if [ -d "/tmp" ]; then
    echo "正在扫描 /tmp 目录..."
    tmp_files=$(find /tmp -maxdepth 1 -type f -atime +7 2>/dev/null)
    
    if [ -n "$tmp_files" ]; then
        echo ""
        echo "发现以下超过 7 天的临时文件:"
        echo "$tmp_files" | while read -r file; do
            size=$(du -h "$file" 2>/dev/null | cut -f1)
            echo "  - $(basename "$file") ($size)"
        done
        echo ""
        
        find /tmp -maxdepth 1 -type f -atime +7 -delete 2>/dev/null
        find /tmp -mindepth 2 -type d -empty -delete 2>/dev/null
        log_success "/tmp 清理完成"
    else
        log_info "/tmp 没有需要清理的文件"
    fi
fi

# 清理 /var/tmp
if [ -d "/var/tmp" ]; then
    echo "正在扫描 /var/tmp 目录..."
    vartmp_files=$(find /var/tmp -maxdepth 1 -type f -atime +7 2>/dev/null)
    
    if [ -n "$vartmp_files" ]; then
        echo ""
        echo "发现以下超过 7 天的临时文件:"
        echo "$vartmp_files" | while read -r file; do
            size=$(du -h "$file" 2>/dev/null | cut -f1)
            echo "  - $(basename "$file") ($size)"
        done
        echo ""
        
        find /var/tmp -maxdepth 1 -type f -atime +7 -delete 2>/dev/null
        find /var/tmp -mindepth 2 -type d -empty -delete 2>/dev/null
        log_success "/var/tmp 清理完成"
    else
        log_info "/var/tmp 没有需要清理的文件"
    fi
fi

# -----------------------------------------------------------------------------
# 5. 清理用户缓存
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[5/10] 清理用户缓存目录${NC}"
print_separator

# 清理所有用户
for user_home in /home/* /root; do
    if [ -d "$user_home/.cache" ]; then
        user_name=$(basename "$user_home")
        echo "正在扫描用户 $user_name 的缓存..."
        
        cache_files=$(find "$user_home/.cache" -type f -atime +30 2>/dev/null | head -20)
        
        if [ -n "$cache_files" ]; then
            cache_count=$(find "$user_home/.cache" -type f -atime +30 2>/dev/null | wc -l)
            cache_size=$(du -sh "$user_home/.cache" 2>/dev/null | cut -f1)
            
            echo "  缓存大小: $cache_size"
            echo "  发现 $cache_count 个超过 30 天的缓存文件"
            
            if [ "$cache_count" -le 10 ]; then
                echo "  清理文件:"
                echo "$cache_files" | while read -r file; do
                    echo "    - ${file#"$user_home"/.cache/}"
                done
            else
                echo "  部分清理文件 (显示前 10 个):"
                echo "$cache_files" | head -10 | while read -r file; do
                    echo "    - ${file#"$user_home"/.cache/}"
                done
                echo "    ... 还有 $((cache_count - 10)) 个文件"
            fi
            
            find "$user_home/.cache" -type f -atime +30 -delete 2>/dev/null
            find "$user_home/.cache" -type d -empty -delete 2>/dev/null
            log_success "用户 $user_name 缓存清理完成"
            echo ""
        else
            log_info "用户 $user_name 没有需要清理的缓存"
        fi
    fi
done

# -----------------------------------------------------------------------------
# 6. 清理系统日志
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[6/10] 清理系统日志${NC}"
print_separator

# journalctl 清理
if command -v journalctl >/dev/null 2>&1; then
    journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[MGT]' | head -1)
    echo "当前 journalctl 日志大小: $journal_size"
    
    log_info "正在清理 journalctl 日志 (保留最近 7 天,最大 1GB)..."
    journalctl --vacuum-time=7d --vacuum-size=1G 2>&1 | grep -E '(Deleted|Vacuuming|删除|清理)'
    log_success "journalctl 日志清理完成"
else
    log_info "未检测到 journalctl"
fi

# logrotate
if command -v logrotate >/dev/null 2>&1; then
    log_info "正在执行日志轮换..."
    logrotate -f /etc/logrotate.conf > /dev/null 2>&1
    log_success "日志轮换完成"
fi

# 清理 /var/log 旧日志
echo "正在扫描 /var/log 目录..."
old_logs=$(find /var/log -type f \( -name "*.log" -o -name "*.gz" -o -name "*.old" \) -atime +30 2>/dev/null)

if [ -n "$old_logs" ]; then
    log_count=$(echo "$old_logs" | wc -l)
    echo ""
    echo "发现 $log_count 个超过 30 天的日志文件"
    
    if [ "$log_count" -le 15 ]; then
        echo "清理文件:"
        echo "$old_logs" | while read -r log; do
            size=$(du -h "$log" 2>/dev/null | cut -f1)
            echo "  - ${log#/var/log/} ($size)"
        done
    else
        echo "部分清理文件 (显示前 15 个):"
        echo "$old_logs" | head -15 | while read -r log; do
            size=$(du -h "$log" 2>/dev/null | cut -f1)
            echo "  - ${log#/var/log/} ($size)"
        done
        echo "  ... 还有 $((log_count - 15)) 个文件"
    fi
    echo ""
    
    find /var/log -type f -name "*.log" -atime +30 -delete 2>/dev/null
    find /var/log -type f -name "*.gz" -atime +30 -delete 2>/dev/null
    find /var/log -type f -name "*.old" -atime +30 -delete 2>/dev/null
    log_success "/var/log 清理完成"
else
    log_info "/var/log 没有需要清理的旧日志"
fi

# -----------------------------------------------------------------------------
# 7. 清理 APT 缓存
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[7/10] 清理 APT 缓存${NC}"
print_separator

if [ -d "/var/cache/apt/archives" ]; then
    apt_cache_size=$(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1)
    apt_debs=$(find /var/cache/apt/archives -type f -name "*.deb" 2>/dev/null)
    if [ -n "$apt_debs" ]; then
        deb_count=$(echo "$apt_debs" | wc -l)
    else
        deb_count=0
    fi
    
    echo "APT 缓存目录大小: $apt_cache_size"
    echo "缓存包数量: $deb_count 个"
    
    if [ "$deb_count" -gt 0 ]; then
        echo ""
        if [ "$deb_count" -le 20 ]; then
            echo "缓存包列表:"
            echo "$apt_debs" | while read -r deb; do
                size=$(du -h "$deb" 2>/dev/null | cut -f1)
                echo "  - $(basename "$deb") ($size)"
            done
        else
            echo "部分缓存包 (显示前 20 个):"
            echo "$apt_debs" | head -20 | while read -r deb; do
                size=$(du -h "$deb" 2>/dev/null | cut -f1)
                echo "  - $(basename "$deb") ($size)"
            done
            echo "  ... 还有 $((deb_count - 20)) 个包"
        fi
        echo ""
    fi
fi

log_info "正在清理 APT 缓存..."
apt-get autoclean -y > /dev/null 2>&1
apt-get autoremove -y > /dev/null 2>&1
apt-get clean -y > /dev/null 2>&1
log_success "APT 缓存清理完成"

# -----------------------------------------------------------------------------
# 8. 清理 Docker
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[8/10] 清理 Docker 资源${NC}"
print_separator

if command -v docker &> /dev/null; then
    docker_images=$(docker images -q 2>/dev/null | wc -l)
    docker_containers=$(docker ps -aq 2>/dev/null | wc -l)
    docker_volumes=$(docker volume ls -q 2>/dev/null | wc -l)
    
    echo "Docker 镜像: $docker_images 个"
    echo "Docker 容器: $docker_containers 个"
    echo "Docker 卷: $docker_volumes 个"
    echo ""
    
    read -r -p "${YELLOW}是否清理所有未使用的 Docker 资源? (y/N)${NC} " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在清理 Docker 资源..."
        docker system prune -a --volumes --force 2>&1 | grep -E '(Total|deleted|Deleted|reclaimed|释放)'
        log_success "Docker 清理完成"
    else
        log_info "已跳过 Docker 清理"
    fi
else
    log_info "未检测到 Docker"
fi

# -----------------------------------------------------------------------------
# 9. 清理缩略图缓存
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[9/10] 清理缩略图缓存${NC}"
print_separator

thumbnail_cleaned=0

for user_home in /home/* /root; do
    if [ -d "$user_home/.cache/thumbnails" ]; then
        user_name=$(basename "$user_home")
        thumb_count=$(find "$user_home/.cache/thumbnails" -type f 2>/dev/null | wc -l)
        
        if [ "$thumb_count" -gt 0 ]; then
            thumb_size=$(du -sh "$user_home/.cache/thumbnails" 2>/dev/null | cut -f1)
            echo "用户 $user_name: $thumb_count 个缩略图 ($thumb_size)"
            rm -rf "$user_home/.cache/thumbnails"/* 2>/dev/null
            thumbnail_cleaned=$((thumbnail_cleaned + thumb_count))
        fi
    fi
done

if [ "$thumbnail_cleaned" -gt 0 ]; then
    log_success "共清理 $thumbnail_cleaned 个缩略图"
else
    log_info "没有需要清理的缩略图"
fi

# -----------------------------------------------------------------------------
# 10. 验证系统目录
# -----------------------------------------------------------------------------
echo ""
echo "${BOLD}[10/10] 验证系统关键目录${NC}"
print_separator

# 检查 /tmp
if [ ! -d "/tmp" ]; then
    log_warning "/tmp 目录不存在,正在重建..."
    mkdir -p /tmp && chmod 1777 /tmp && chown root:root /tmp
    log_success "/tmp 目录已重建"
elif [ "$(stat -c %a /tmp 2>/dev/null)" != "1777" ]; then
    log_warning "/tmp 目录权限不正确,正在修复..."
    chmod 1777 /tmp
    log_success "/tmp 权限已修复"
else
    log_info "/tmp 目录状态正常"
fi

# 检查 /var/tmp
if [ ! -d "/var/tmp" ]; then
    log_warning "/var/tmp 目录不存在,正在重建..."
    mkdir -p /var/tmp && chmod 1777 /var/tmp && chown root:root /var/tmp
    log_success "/var/tmp 目录已重建"
elif [ "$(stat -c %a /var/tmp 2>/dev/null)" != "1777" ]; then
    log_warning "/var/tmp 目录权限不正确,正在修复..."
    chmod 1777 /var/tmp
    log_success "/var/tmp 权限已修复"
else
    log_info "/var/tmp 目录状态正常"
fi

# -----------------------------------------------------------------------------
# 显示清理总结
# -----------------------------------------------------------------------------
end_space_kb=$(df / | tail -n 1 | awk '{print $3}')
cleared_space_kb=$((start_space_kb - end_space_kb))

echo ""
echo "${BOLD}${GREEN}========================================${NC}"
echo "${BOLD}${GREEN}  清理完成!${NC}"
echo "${BOLD}${GREEN}========================================${NC}"
echo ""

if [ "$cleared_space_kb" -gt 0 ]; then
    if [ "$cleared_space_kb" -gt 1048576 ]; then
        cleared_gb=$(echo "scale=2; $cleared_space_kb / 1024 / 1024" | bc 2>/dev/null)
        echo "${GREEN}释放空间: ${BOLD}${cleared_gb} GB${NC}"
    else
        cleared_mb=$((cleared_space_kb / 1024))
        echo "${GREEN}释放空间: ${BOLD}${cleared_mb} MB${NC}"
    fi
else
    echo "${BLUE}本次清理未释放额外空间,系统已经很干净了!${NC}"
fi

echo ""
log_info "建议重启系统以应用所有更改"
echo ""
