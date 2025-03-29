#!/bin/bash

# 启用严格模式
set -euo pipefail
shopt -s nullglob

# 日志文件路径
LOG_FILE="/var/log/system_cleaner.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# 初始化清理统计
declare -A CLEAN_STATS=(
    ["kernel"]=0
    ["orphans"]=0
    ["logs"]=0
    ["cache"]=0
    ["docker"]=0
    ["apt"]=0
)

# 资源清理配置
declare -r KEEP_LOGS_DAYS=7
declare -r MIN_KERNELS=2
declare -r DRY_RUN=false

# 依赖检查
check_dependencies() {
    local deps=("deborphan" "journalctl")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            apt-get install -y "$dep" || {
                echo "依赖安装失败: $dep"
                exit 1
            }
        fi
    done
}

# 空间计算函数
calculate_space() {
    df --output=used / | awk 'NR==2 {print $1*1024}'
}

# 安全删除旧内核
clean_kernels() {
    echo "正在扫描旧内核..."
    local current_kernel keep_kernels=()
    current_kernel=$(uname -r | sed 's/-.*//')
    
    # 获取可保留的内核列表
    readarray -t keep_kernels < <(
        dpkg --list | 
        awk '/^ii  linux-image-[0-9]+/ {print $2}' | 
        sort -V | 
        grep -v "$current_kernel" | 
        tail -n "$MIN_KERNELS"
    )

    # 查找需要删除的旧内核
    local to_remove=()
    while IFS= read -r pkg; do
        [[ " ${keep_kernels[*]} " != *"$pkg"* ]] && to_remove+=("$pkg")
    done < <(dpkg --list | awk '/^ii  linux-(image|headers)-[0-9]+/ {print $2}')

    if ((${#to_remove[@]} > 0)); then
        echo "正在删除旧内核:"
        printf '• %s\n' "${to_remove[@]}"
        $DRY_RUN || {
            apt-get purge -y "${to_remove[@]}" &&
            update-grub
        }
        CLEAN_STATS["kernel"]=$(calculate_space)
    else
        echo "没有可删除的旧内核"
    fi
}

# 清理孤立包
clean_orphans() {
    echo "清理孤立软件包..."
    local orphans=()
    mapfile -t orphans < <(deborphan --libdevel)
    ((${#orphans[@]} > 0)) && {
        $DRY_RUN || apt-get purge -y "${orphans[@]}"
        CLEAN_STATS["orphans"]=$(calculate_space)
    }
}

# 安全日志清理
clean_logs() {
    echo "清理系统日志..."
    # 使用logrotate方式
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
    journalctl --vacuum-time="${KEEP_LOGS_DAYS}d"
    CLEAN_STATS["logs"]=$(calculate_space)
}

# 缓存清理
clean_cache() {
    echo "清理系统缓存..."
    # 系统级缓存
    rm -rf -- /tmp/* /var/tmp/*
    find /root /home/* -type d -path "*/.cache" -exec rm -rf {} \;
    
    # 应用缓存
    for cache_dir in /var/cache/{apt,dnf,yum}; do
        [[ -d "$cache_dir" ]] && rm -rf "$cache_dir"/*
    done
    
    CLEAN_STATS["cache"]=$(calculate_space)
}

# Docker清理
clean_docker() {
    if command -v docker &>/dev/null; then
        echo "清理Docker资源..."
        $DRY_RUN || docker system prune -af --volumes
        CLEAN_STATS["docker"]=$(calculate_space)
    fi
}

# APT清理
clean_apt() {
    echo "清理包管理器..."
    apt-get -y autoremove
    apt-get -y autoclean
    apt-get -y clean
    CLEAN_STATS["apt"]=$(calculate_space)
}

# 显示统计信息
show_stats() {
    local total=0
    echo -e "\n清理统计:"
    for category in "${!CLEAN_STATS[@]}"; do
        printf "• %-10s : %'d KB\n" "${category^}" "${CLEAN_STATS[$category]}"
        ((total += CLEAN_STATS[$category]))
    done
    echo "总释放空间: $((total / 1024)) MB"
}

# 主函数
main() {
    [[ $EUID -ne 0 ]] && { echo "请使用root权限运行"; exit 1; }
    
    local start_space end_space
    start_space=$(calculate_space)
    
    check_dependencies
    clean_kernels
    clean_orphans
    clean_logs
    clean_cache
    clean_docker
    clean_apt
    
    end_space=$(calculate_space)
    CLEAN_STATS["total"]=$((start_space - end_space))
    
    show_stats
    echo "详细日志请查看: $LOG_FILE"
}

# 执行主程序
main
