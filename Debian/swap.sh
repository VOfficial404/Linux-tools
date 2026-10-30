#!/usr/bin/env bash
#
# Swap 管理脚本（Debian 12 / 13）
#
# 参考 spiritLHLS/addswap 的功能编写：添加 / 调整 / 删除 swap 文件，设置 swappiness。
#
# 用法：
#   sudo bash swap.sh                  交互式菜单
#   sudo bash swap.sh --add 2G         添加 2G 的 /swapfile（已有时改为 2G），单位可用 M / G，不写单位按 MB
#   sudo bash swap.sh --remove         删除 /swapfile
#   sudo bash swap.sh --swappiness 10  设置 swappiness 并永久保存
#
# 与参考脚本的不同：
#   * 删除时只关闭 /swapfile，不用 swapoff -a，不会顺带关掉 swap 分区和 zram
#   * 修改 /etc/fstab 前先备份，只处理第一列正好是 /swapfile 的那一行
#   * 创建前检查磁盘剩余空间；btrfs 上按要求关闭写时复制；
#     预分配的文件无法启用时，自动改用 dd 真正写一遍再试
#   * swappiness 写到 /etc/sysctl.d/（Debian 13 已不再读取 /etc/sysctl.conf）
#   * 容器（OpenVZ / LXC / Docker）里不添加 swap：容器没有权限启用 swap。
#     参考脚本在 OpenVZ 上是改写 /proc/meminfo 显示的数字，并没有真正增加可用内存，这里不这样做

set -uo pipefail

SWAPFILE="/swapfile"
# 文件名带 zz：systemd 按文件名顺序应用 sysctl.d，排在其他 99-*.conf 之后才能最终生效
SYSCTL_FILE="/etc/sysctl.d/99-zz-swappiness.conf"

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
else
    BOLD=''; RED=''; GREEN=''; YELLOW=''; NC=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法: sudo bash ${0##*/} [选项]

  （不带参数）          打开交互式菜单
  -a, --add <大小>      添加 /swapfile，已有时调整为该大小。例：2G、512M、1024（MB）
  -r, --remove          删除 /swapfile（不影响 swap 分区和 zram）
  -s, --swappiness <N>  设置 swappiness（0-100）并永久保存
  -h, --help            显示本帮助
EOF
}

# -----------------------------------------------------------------------------
# 交互：一律从 /dev/tty 读，用 curl ... | bash 运行时也能正常提问
# -----------------------------------------------------------------------------
HAVE_TTY=0
{ : </dev/tty; } 2>/dev/null && HAVE_TTY=1

# ask_yn <提示> <默认 y|n>；没有终端时取默认值
ask_yn() {
    local prompt=$1 def=$2 hint='[y/N]' reply=''
    [[ $def == y ]] && hint='[Y/n]'
    read -r -p "$prompt $hint " reply </dev/tty 2>/dev/null || reply=''
    reply=${reply:-$def}
    [[ $reply =~ ^[Yy] ]]
}

# ask_value <提示> <默认值> <校验正则>；结果输出到 stdout
ask_value() {
    local prompt=$1 def=$2 re=$3 reply=''
    while true; do
        read -r -p "$prompt [$def]: " reply </dev/tty || reply=''
        reply=${reply:-$def}
        if [[ $reply =~ $re ]]; then
            printf '%s' "$reply"
            return
        fi
        printf '  输入无效，请重新输入。\n' >&2
    done
}

# -----------------------------------------------------------------------------
# 工具函数
# -----------------------------------------------------------------------------
human_mb() { awk -v m="${1:-0}" 'BEGIN { if (m >= 1024) printf "%.1fG", m / 1024; else printf "%dM", m }'; }

# mem_mb <字段>：读取 /proc/meminfo 里的某一项，单位 MB
mem_mb() { awk -v k="$1:" '$1 == k { print int($2 / 1024); exit }' /proc/meminfo; }

# parse_size <输入>：2G / 512M / 1024 / 2GB -> MB；格式不对时返回 1
parse_size() {
    local s=${1^^}
    s=${s%B}
    case $s in
        *G) [[ ${s%G} =~ ^[0-9]+$ ]] && echo $(( 10#${s%G} * 1024 )) ;;
        *M) [[ ${s%M} =~ ^[0-9]+$ ]] && echo $(( 10#${s%M} )) ;;
        *)  [[ $s =~ ^[0-9]+$ ]] && echo $(( 10#$s )) ;;
    esac
}

# 建议大小：内存 ≤2G 取 2 倍，≤8G 取 1 倍，更大取 4G；按 256M 取整
# （参考脚本一律取 2 倍，大内存机器上会白白占掉很多磁盘）
recommend_mb() {
    local ram mb
    ram=$(mem_mb MemTotal)
    if (( ram <= 2048 )); then
        mb=$(( ram * 2 ))
    elif (( ram <= 8192 )); then
        mb=$ram
    else
        mb=4096
    fi
    echo $(( (mb + 255) / 256 * 256 ))
}

detect_container() {
    CONTAINER=$(systemd-detect-virt --container 2>/dev/null) || CONTAINER=''
    if [[ -z $CONTAINER ]]; then
        [[ -f /proc/user_beancounters ]] && CONTAINER=openvz
        [[ -f /.dockerenv ]] && CONTAINER=docker
    fi
    return 0
}

swapfile_active() { swapon --noheadings --show=NAME 2>/dev/null | grep -qxF "$SWAPFILE"; }

# ---- /etc/fstab --------------------------------------------------------------
fstab_has_swapfile() { awk -v f="$SWAPFILE" '$1 == f { found = 1 } END { exit !found }' /etc/fstab 2>/dev/null; }

backup_fstab() {
    [[ -f /etc/fstab ]] || return 0
    local b
    b="/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a /etc/fstab "$b" && info "已备份 /etc/fstab -> $b"
}

fstab_add_swapfile() {
    fstab_has_swapfile && return 0
    backup_fstab
    printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
}

fstab_remove_swapfile() {
    fstab_has_swapfile || return 0
    backup_fstab
    local tmp
    tmp=$(mktemp) || return 1
    # 只删第一列正好是 /swapfile 的行；用 cat 写回，保留原文件的权限和属主
    awk -v f="$SWAPFILE" '$1 != f' /etc/fstab > "$tmp" && cat "$tmp" > /etc/fstab
    rm -f -- "$tmp"
}

# -----------------------------------------------------------------------------
# 状态
# -----------------------------------------------------------------------------
show_status() {
    local total avail st sf
    total=$(mem_mb MemTotal); avail=$(mem_mb MemAvailable)
    st=$(mem_mb SwapTotal);   sf=$(mem_mb SwapFree)
    info "=============================================================="
    info " ${BOLD}Swap 管理${NC}"
    info "=============================================================="
    info " 内存       : 共 $(human_mb "$total")，可用 $(human_mb "$avail")"
    if (( st > 0 )); then
        info " Swap       : 共 $(human_mb "$st")，已用 $(human_mb $(( st - sf )))"
    else
        info " Swap       : 未启用"
    fi
    info " swappiness : $(cat /proc/sys/vm/swappiness 2>/dev/null || echo 未知)"
    [[ -n $CONTAINER ]] && info " 环境       : 容器（$CONTAINER）"
    if [[ -n $(swapon --noheadings --show 2>/dev/null) ]]; then
        info ""
        swapon --show 2>/dev/null | sed 's/^/  /'
    fi
    info "=============================================================="
}

# -----------------------------------------------------------------------------
# 添加 / 删除
# -----------------------------------------------------------------------------
dd_file() { dd if=/dev/zero of="$SWAPFILE" bs=1M count="$1" status=progress; }

# make_file <MB> <文件系统类型>
make_file() {
    local mb=$1 fstype=$2
    rm -f -- "$SWAPFILE"
    if [[ $fstype == btrfs ]]; then
        # btrfs 上的 swap 文件必须关闭写时复制；新版 btrfs-progs 有专门的命令
        if command -v btrfs >/dev/null 2>&1 &&
           btrfs filesystem mkswapfile --size "${mb}m" "$SWAPFILE" >/dev/null 2>&1; then
            return 0
        fi
        touch "$SWAPFILE" && chattr +C "$SWAPFILE" || return 1
    fi
    fallocate -l "${mb}M" "$SWAPFILE" 2>/dev/null && return 0
    info "fallocate 不可用，改用 dd 写入（较慢，请稍候）..."
    dd_file "$mb"
}

# remove_swapfile：关闭并删除 /swapfile，同时去掉 fstab 里的那一行
remove_swapfile() {
    if [[ ! -e $SWAPFILE ]] && ! fstab_has_swapfile; then
        info "没有 $SWAPFILE，无需删除。"
        if [[ -n $(swapon --noheadings --show 2>/dev/null) ]]; then
            info "系统里的其他 swap（分区、zram 等）不是本脚本创建的，没有改动。"
        fi
        return 0
    fi

    if swapfile_active; then
        local used avail
        used=$(swapon --noheadings --bytes --show=NAME,USED 2>/dev/null |
               awk -v f="$SWAPFILE" '$1 == f { print int($2 / 1048576) }')
        avail=$(mem_mb MemAvailable)
        if (( ${used:-0} > avail )); then
            warn "$SWAPFILE 里有 $(human_mb "$used") 数据，但可用内存只有 $(human_mb "$avail")，现在关闭可能导致进程被系统杀掉。"
            ask_yn "仍要关闭吗？" n || { info "已取消，没有做任何修改。"; return 1; }
        fi
        info "正在关闭 $SWAPFILE（里面的数据会移回内存，可能需要一点时间）..."
        swapoff "$SWAPFILE" || { warn "swapoff 失败，没有做任何修改。"; return 1; }
    fi

    fstab_remove_swapfile
    rm -f -- "$SWAPFILE"
    ok "已删除 $SWAPFILE"
}

# add_swap <MB>：创建并启用 /swapfile；已存在时先删除再按新大小创建
add_swap() {
    local mb=$1 dir fstype avail_mb old_mb=0
    if [[ -n $CONTAINER ]]; then
        warn "当前在容器（$CONTAINER）里，容器没有权限启用 swap，需要在宿主机或 VPS 服务商的控制面板里调整。"
        return 1
    fi
    if (( mb < 64 )); then
        warn "swap 至少要 64M。"
        return 1
    fi

    dir=$(dirname "$SWAPFILE")
    fstype=$(findmnt -no FSTYPE --target "$dir" 2>/dev/null)
    case $fstype in
        zfs|tmpfs|overlay|nfs*|cifs|fuse*)
            warn "$dir 所在的文件系统是 $fstype，不支持 swap 文件。"
            return 1 ;;
    esac

    # 空间检查：替换时旧文件的空间也算可用；创建后至少给系统留 1G
    [[ -f $SWAPFILE ]] && old_mb=$(( $(stat -c %s "$SWAPFILE") / 1048576 ))
    avail_mb=$(df -Pm "$dir" | awk 'NR == 2 { print $4 + 0 }')
    if (( mb + 1024 > avail_mb + old_mb )); then
        warn "磁盘空间不够：$dir 可用 $(human_mb $(( avail_mb + old_mb )))，创建 $(human_mb "$mb") 后剩余不足 1G。"
        return 1
    fi

    if [[ -e $SWAPFILE ]] || fstab_has_swapfile; then
        info "先删除现有的 $SWAPFILE ..."
        remove_swapfile || return 1
    fi

    info "正在创建 $(human_mb "$mb") 的 $SWAPFILE ..."
    if ! make_file "$mb" "$fstype"; then
        rm -f -- "$SWAPFILE"
        warn "创建 $SWAPFILE 失败。"
        return 1
    fi
    chmod 600 "$SWAPFILE"

    if ! { mkswap "$SWAPFILE" >/dev/null && swapon "$SWAPFILE"; } 2>/dev/null; then
        # 部分文件系统不接受 fallocate 预分配的文件（swapon 报 "has holes"）
        warn "启用失败，改用 dd 重新写入后再试..."
        if ! { dd_file "$mb" && chmod 600 "$SWAPFILE" && mkswap "$SWAPFILE" >/dev/null && swapon "$SWAPFILE"; }; then
            rm -f -- "$SWAPFILE"
            warn "无法启用 $SWAPFILE。"
            return 1
        fi
    fi

    fstab_add_swapfile
    ok "已启用 $(human_mb "$mb") 的 $SWAPFILE，并写入 /etc/fstab，重启后自动生效。"
    swapon --show
}

# -----------------------------------------------------------------------------
# swappiness
# -----------------------------------------------------------------------------
set_swappiness() {
    local v=${1:-} others
    if [[ ! $v =~ ^[0-9]+$ ]] || (( 10#$v > 100 )); then
        warn "swappiness 必须是 0 到 100 之间的整数：$v"
        return 1
    fi
    v=$(( 10#$v ))
    sysctl -q -w vm.swappiness="$v" || { warn "设置失败（容器里通常无权修改）。"; return 1; }
    printf '# 由 Linux-tools swap.sh 生成\nvm.swappiness = %s\n' "$v" > "$SYSCTL_FILE"
    ok "swappiness 已设为 $v，并保存到 $SYSCTL_FILE"

    others=$(grep -lsE '^[[:space:]]*vm\.swappiness[[:space:]]*=' \
        /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null |
        grep -vxF "$SYSCTL_FILE")
    if [[ -n $others ]]; then
        warn "以下文件也设置了 vm.swappiness。开机时按文件名排序，排在最后的生效，$SYSCTL_FILE 一般排在最后："
        printf '      %s\n' $others >&2
    fi
}

# -----------------------------------------------------------------------------
# 交互式菜单
# -----------------------------------------------------------------------------
interactive_add() {
    local rec input mb
    rec=$(recommend_mb)
    printf '\n%s添加 swap%s\n' "$BOLD" "$NC"
    info "  建议大小：$(human_mb "$rec")（内存 ≤2G 取 2 倍，≤8G 取 1 倍，更大取 4G）"
    input=$(ask_value "  swap 大小（如 1G、512M，纯数字按 MB）" "${rec}M" '^[0-9]+[MmGg]?[Bb]?$')
    mb=$(parse_size "$input") || { warn "大小格式不对：$input"; return 1; }
    if [[ -e $SWAPFILE ]]; then
        ask_yn "  已有 $SWAPFILE，将改为 $(human_mb "$mb")（先关闭旧的再重新创建），继续吗？" y || return 0
    else
        ask_yn "  创建 $(human_mb "$mb") 的 $SWAPFILE 吗？" y || return 0
    fi
    add_swap "$mb"
}

interactive_remove() {
    printf '\n%s删除 swap%s\n' "$BOLD" "$NC"
    if [[ -e $SWAPFILE ]] || fstab_has_swapfile; then
        ask_yn "  删除 $SWAPFILE 吗？（swap 分区和 zram 不受影响）" n || return 0
    fi
    remove_swapfile
}

interactive_swappiness() {
    local v
    printf '\n%s设置 swappiness%s\n' "$BOLD" "$NC"
    info "  范围 0-100，数值越小，系统越晚开始使用 swap。Debian 默认 60，小内存 VPS 常用 10。"
    v=$(ask_value "  swappiness" "$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)" '^[0-9]+$')
    set_swappiness "$v"
}

menu() {
    while true; do
        printf '\n'
        show_status
        printf '  1) 添加 swap（已有 %s 时调整大小）\n' "$SWAPFILE"
        printf '  2) 删除 %s\n' "$SWAPFILE"
        printf '  3) 设置 swappiness\n'
        printf '  0) 退出\n'
        case $(ask_value "请选择" 0 '^[0-3]$') in
            1) interactive_add ;;
            2) interactive_remove ;;
            3) interactive_swappiness ;;
            *) return 0 ;;
        esac
    done
}

main() {
    local action='' arg='' mb
    case ${1:-} in
        -a|--add)        action=add;        arg=${2:-} ;;
        -r|--remove)     action=remove ;;
        -s|--swappiness) action=swappiness; arg=${2:-} ;;
        -h|--help)       usage; exit 0 ;;
        '') ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
    detect_container

    case $action in
        add)
            mb=$(parse_size "$arg") || die "大小格式不对：${arg:-（空）}，例：2G、512M、1024"
            add_swap "$mb" ;;
        remove)     remove_swapfile ;;
        swappiness) set_swappiness "$arg" ;;
        '')
            (( HAVE_TTY )) || die "需要交互式终端。非交互使用请加 --add / --remove / --swappiness。"
            menu ;;
    esac
}

main "$@"
