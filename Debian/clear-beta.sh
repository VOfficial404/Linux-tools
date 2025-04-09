#!/bin/bash

# 启用严格模式
set -euo pipefail
shopt -s nullglob

# 配置参数
readonly DRY_RUN=false
readonly KEEP_LOGS_DAYS=7
readonly MIN_KERNELS=2
readonly DOCKER_CLEAN_LEVEL="full"

# 颜色定义
readonly RED='\033[;31m'
readonly GREEN='\033[;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# 日志配置
readonly LOG_FILE="/var/log/system_cleaner-$(date +%Y%m%d).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# 初始化统计
declare -A CLEAN_STATS=(
    ["kernel"]=0
    ["orphans"]=0
    ["logs"]=0
    ["cache"]=0
    ["docker_images"]=0
    ["docker_volumes"]=0
    ["docker_networks"]=0
    ["apt"]=0
)

# === 所有函数定义必须在main之前 ===

# 依赖检查
check_deps() {
    local deps=("deborphan" "journalctl" "docker")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo -e "${YELLOW}正在安装依赖: $dep...${NC}"
            apt-get install -y "$dep" || true
        fi
    done
}

# 空间计算函数
space_used() {
    df --output=used -B1K / | awk 'NR==2 {print $1}'
}

# 安全删除旧内核
clean_kernels() {
    echo -e "\n${GREEN}=== 内核清理 ===${NC}"
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
        echo -e "${YELLOW}找到可删除内核 (保留最近 ${MIN_KERNELS} 个):${NC}"
        printf '• %s\n' "${to_remove[@]}"
        
        if ! $DRY_RUN; then
            local before=$(space_used)
            apt-get purge -y "${to_remove[@]}"
            update-grub
            local after=$(space_used)
            CLEAN_STATS["kernel"]=$((before - after))
        fi
    else
        echo "没有可删除的旧内核"
    fi
}

# 清理孤立包
clean_orphans() {
    echo -e "\n${GREEN}=== 清理孤立包 ===${NC}"
    local orphans=()
    mapfile -t orphans < <(deborphan --guess-all 2>/dev/null)
    
    if ((${#orphans[@]} > 0)); then
        echo -e "${YELLOW}找到孤立包:${NC}"
        printf '• %s\n' "${orphans[@]}"
        
        if ! $DRY_RUN; then
            local before=$(space_used)
            apt-get purge -y "${orphans[@]}"
            local after=$(space_used)
            CLEAN_STATS["orphans"]=$((before - after))
        fi
    else
        echo "未找到可清理的孤立包"
    fi
}

# 清理系统日志
clean_logs() {
    echo -e "\n${GREEN}=== 日志清理 ===${NC}"
    local before=$(space_used)
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
    find /root -type f -name "*.log" -exec truncate -s 0 {} \;
    journalctl --vacuum-time="${KEEP_LOGS_DAYS}d" --vacuum-size=1G
    local after=$(space_used)
    CLEAN_STATS["logs"]=$((before - after))
}

# 清理缓存
clean_cache() {
    echo -e "\n${GREEN}=== 缓存清理 ===${NC}"
    local before=$(space_used)
    rm -rf -- /tmp/* /var/tmp/*
    find /home -type d -name ".cache" -exec rm -rf {} \;
    rm -rf /var/cache/apt/archives/*
    local after=$(space_used)
    CLEAN_STATS["cache"]=$((before - after))
}

# 清理APT
clean_apt() {
    echo -e "\n${GREEN}=== 包管理器清理 ===${NC}"
    local before=$(space_used)
    apt-get autoclean -y
    apt-get autoremove -y
    apt-get clean -y
    local after=$(space_used)
    CLEAN_STATS["apt"]=$((before - after))
}

# Docker清理
clean_docker() {
    command -v docker &>/dev/null || return
    
    echo -e "\n${GREEN}=== Docker 清理 ===${NC}"
    
    convert_size() {
        local input="${1:-0B}"
        echo "$input" | sed '
            s/\([0-9.]*\)KB/\1K/i;
            s/\([0-9.]*\)MB/\1M/i;
            s/\([0-9.]*\)GB/\1G/i;
            s/\([0-9.]*\)TB/\1T/i;
            s/B//i;
            s/ //g;
            s/^$/0/'
    }

    if [[ "$DOCKER_CLEAN_LEVEL" == "full" ]]; then
        echo -e "${YELLOW}清理悬空镜像...${NC}"
        docker image prune -a -f
        CLEAN_STATS["docker_images"]=$(docker system df --format '{{.Size}}' | awk '/GB|MB|KB/ {print $1}' | convert_size | numfmt --from=iec)
        
        echo -e "${YELLOW}清理未使用网络...${NC}"
        CLEAN_STATS["docker_networks"]=$(docker network prune --force --filter until=24h 2>&1 | awk '/Total reclaimed space:/ {print $4}' | convert_size | numfmt --from=iec)
        
        echo -e "${YELLOW}清理孤立卷...${NC}"
        CLEAN_STATS["docker_volumes"]=$(docker volume prune --force --filter 'label!=keep' 2>&1 | awk '/Total reclaimed space:/ {print $4}' | convert_size | numfmt --from=iec)
    else
        docker system prune -af --volumes
    fi
}

# === 主程序 ===
main() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}需要root权限!${NC}"; exit 1; }
    
    local start_space=$(space_used)
    
    check_deps
    
    echo -e "\n${GREEN}=== 开始系统清理 ===${NC}"
    clean_kernels
    clean_orphans
    clean_logs
    clean_cache
    clean_docker
    clean_apt
    
    local end_space=$(space_used)
    local total_cleared=$((start_space - end_space))
    
    # 确保所有统计值为正数
    for key in "${!CLEAN_STATS[@]}"; do
        CLEAN_STATS[$key]=$((${CLEAN_STATS[$key]} < 0 ? 0 : ${CLEAN_STATS[$key]}))
    done

    echo -e "\n${GREEN}=== 清理统计 ===${NC}"
    printf "%-20s %15s\n" "清理项目" "释放空间(KB)"
    printf "%-20s %'15d\n" "旧内核" "${CLEAN_STATS[kernel]}"
    printf "%-20s %'15d\n" "孤立包" "${CLEAN_STATS[orphans]}"
    printf "%-20s %'15d\n" "系统日志" "${CLEAN_STATS[logs]}"
    printf "%-20s %'15d\n" "缓存文件" "${CLEAN_STATS[cache]}"
    printf "%-20s %'15d\n" "Docker镜像" "${CLEAN_STATS[docker_images]}"
    printf "%-20s %'15d\n" "Docker卷" "${CLEAN_STATS[docker_volumes]}"
    printf "%-20s %'15d\n" "Docker网络" "${CLEAN_STATS[docker_networks]}"
    printf "%-20s %'15d\n" "APT缓存" "${CLEAN_STATS[apt]}"
    printf "%-20s %'15d\n" "总计" "$total_cleared"
    
    echo -e "\n${GREEN}操作完成! 详细日志: $LOG_FILE${NC}"
}

# 执行入口
main
