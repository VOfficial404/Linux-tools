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
            apt-get purge -y "${to_remove[@]}"
            update-grub
            CLEAN_STATS["kernel"]=$(( $(space_used) - CLEAN_STATS["kernel"] ))
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
            apt-get purge -y "${orphans[@]}"
            CLEAN_STATS["orphans"]=$(( $(space_used) - CLEAN_STATS["orphans"] ))
        fi
    else
        echo "未找到可清理的孤立包"
    fi
}

# 清理系统日志
clean_logs() {
    echo -e "\n${GREEN}=== 日志清理 ===${NC}"
    # 清理系统日志
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
    # 清理root日志
    find /root -type f -name "*.log" -exec truncate -s 0 {} \;
    # 清理journal日志
    journalctl --vacuum-time="${KEEP_LOGS_DAYS}d" --vacuum-size=1G
    CLEAN_STATS["logs"]=$(( $(space_used) - CLEAN_STATS["logs"] ))
}

# 清理缓存
clean_cache() {
    echo -e "\n${GREEN}=== 缓存清理 ===${NC}"
    # 系统缓存
    rm -rf -- /tmp/* /var/tmp/*
    # 用户缓存
    find /home -type d -name ".cache" -exec rm -rf {} \;
    # APT缓存
    rm -rf /var/cache/apt/archives/*
    CLEAN_STATS["cache"]=$(( $(space_used) - CLEAN_STATS["cache"] ))
}

# 清理APT
clean_apt() {
    echo -e "\n${GREEN}=== 包管理器清理 ===${NC}"
    apt-get autoclean -y
    apt-get autoremove -y
    apt-get clean -y
    CLEAN_STATS["apt"]=$(( $(space_used) - CLEAN_STATS["apt"] ))
}

# Docker清理
clean_docker() {
    command -v docker &>/dev/null || return
    
    echo -e "\n${GREEN}=== Docker 清理 ===${NC}"
    
    if [[ "$DOCKER_CLEAN_LEVEL" == "full" ]]; then
        # 清理镜像
        docker image prune -a -f
        CLEAN_STATS["docker_images"]=$(docker system df --format '{{.TotalSpace}}' | numfmt --from=iec)
        
        # 清理网络
        docker network prune -f
        CLEAN_STATS["docker_networks"]=$(docker network prune --force --filter until=24h 2>&1 | grep 'Total reclaimed space:' | awk '{print $4}')
        
        # 清理卷
        docker volume prune -f
        CLEAN_STATS["docker_volumes"]=$(docker volume prune --force --filter 'label!=keep' 2>&1 | grep 'Total reclaimed space:' | awk '{print $4}')
    else
        docker system prune -af --volumes
    fi
}

# === 主程序 ===
main() {
    [[ $EUID -ne  ]] && { echo -e "${RED}需要root权限!${NC}"; exit 1; }
    
    local start_space=$(space_used)
    
    check_deps
    
    echo -e "\n${GREEN}=== 开始系统清理 ===${NC}"
    clean_kernels
    clean_orphans  # 现在已正确定义
    clean_logs
    clean_cache
    clean_docker
    clean_apt
    
    local end_space=$(space_used)
    local total_cleared=$((start_space - end_space))
    
    echo -e "\n${GREEN}=== 清理统计 ===${NC}"
    printf "%-20s %15s\n" "清理项目" "释放空间"
    printf "%-20s %15d KB\n" "旧内核" "${CLEAN_STATS[kernel]}"
    printf "%-20s %15d KB\n" "孤立包" "${CLEAN_STATS[orphans]}"
    printf "%-20s %15d KB\n" "系统日志" "${CLEAN_STATS[logs]}"
    printf "%-20s %15d KB\n" "缓存文件" "${CLEAN_STATS[cache]}"
    printf "%-20s %15d KB\n" "Docker镜像" "${CLEAN_STATS[docker_images]}"
    printf "%-20s %15d KB\n" "Docker卷" "${CLEAN_STATS[docker_volumes]}"
    printf "%-20s %15d KB\n" "Docker网络" "${CLEAN_STATS[docker_networks]}"
    printf "%-20s %15d KB\n" "APT缓存" "${CLEAN_STATS[apt]}"
    printf "%-20s %15d KB\n" "总计" "$total_cleared"
    
    echo -e "\n${GREEN}操作完成! 详细日志: $LOG_FILE${NC}"
}

# 执行入口
main
