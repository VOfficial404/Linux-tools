#!/usr/bin/env bash
#
# Debian 12 (bookworm) / Debian 13 (trixie) 交互式系统清理脚本
#
# 运行后先扫描系统，列出每一项可清理的内容和预计释放的空间，
# 由你勾选、确认之后才会真正删除。
#
# 用法：
#   sudo bash clear.sh             交互式清理（推荐）
#   sudo bash clear.sh --dry-run   照常选择，但只显示将执行的命令，不做任何修改
#   sudo bash clear.sh --yes       不提问，按默认勾选直接清理（适合 cron）
#
# 设计要点：
#   * 默认只勾选安全的项目；截断当前日志、清空用户缓存、Docker 需要手动勾选。
#   * 旧内核：永远保留正在运行的内核和已安装的最新内核。删除前先让 apt 模拟一遍，
#     如果会连带删除别的软件包，会列出来再问一次。
#   * Debian 13 的内核版本号带 "+"（如 6.12.38+deb13-amd64），一律按字面量比较，
#     不拿版本号当正则用，否则 "+" 会被当成量词，导致误删正在运行的内核。
#   * Debian 13 已移除 deborphan，两个版本统一用 apt-get autoremove 清理孤立依赖。
#   * Debian 13 的 /tmp 默认是内存盘（tmpfs），清理它释放的是内存，不是磁盘。

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

DRY_RUN=0
ASSUME_YES=0

# 默认参数，交互时可修改
JOURNAL_KEEP_DAYS=7
JOURNAL_MAX_SIZE=500M
TMP_MAX_AGE_DAYS=7
DOCKER_LEVEL=1   # 1=停止的容器、悬空镜像、构建缓存  2=再加所有未使用的镜像  3=再加未使用的数据卷

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; NC=''
fi

info() { printf '%s\n' "$*"; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法: sudo bash ${0##*/} [选项]

  -n, --dry-run   照常选择，但只显示将执行的命令，不做任何修改
  -y, --yes       不提问，按默认勾选直接清理（适合 cron）
  -h, --help      显示本帮助
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -n|--dry-run) DRY_RUN=1 ;;
            -y|--yes)     ASSUME_YES=1 ;;
            -h|--help)    usage; exit 0 ;;
            *) usage >&2; die "未知参数：$1" ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# 交互：一律从 /dev/tty 读，用 curl ... | bash 运行时也能正常提问
# -----------------------------------------------------------------------------
HAVE_TTY=0
{ : </dev/tty; } 2>/dev/null && HAVE_TTY=1

# ask_yn <提示> <默认 y|n>；--yes 模式直接取默认值
ask_yn() {
    local prompt=$1 def=$2 hint='[y/N]' reply=''
    [[ $def == y ]] && hint='[Y/n]'
    if (( ASSUME_YES )); then
        [[ $def == y ]]
        return
    fi
    read -r -p "$prompt $hint " reply </dev/tty || reply=''
    reply=${reply:-$def}
    [[ $reply =~ ^[Yy] ]]
}

# ask_value <提示> <默认值> <校验正则>；结果输出到 stdout
ask_value() {
    local prompt=$1 def=$2 re=$3 reply=''
    if (( ASSUME_YES )); then
        printf '%s' "$def"
        return
    fi
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
# 新装的 VPS 上 unattended-upgrades 经常持有 dpkg 锁，最多等 120 秒而不是直接失败
apt_get() { apt-get -o DPkg::Lock::Timeout=120 "$@"; }

# run：dry-run 只打印；平时静默执行，失败只警告不中断
run() {
    if (( DRY_RUN )); then
        printf '    %s[dry-run]%s %s\n' "$DIM" "$NC" "$*"
        return 0
    fi
    "$@" >/dev/null 2>&1 || { warn "命令执行失败（已继续）：$*"; return 1; }
}

human_kb() {
    awk -v k="${1:-0}" 'BEGIN {
        split("KB MB GB TB", u, " "); i = 1
        while (k >= 1024 && i < 4) { k /= 1024; i++ }
        if (i == 1) printf "%d %s", k, u[i]; else printf "%.1f %s", k, u[i]
    }'
}

bytes_to_kb()   { awk '{ s += $1 } END { printf "%d", s / 1024 }'; }
disk_avail_kb() { df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 + 0 }'; }

du_kb() {
    (( $# )) || { echo 0; return; }
    du -sxk "$@" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'
}

# 软件包安装后的大小（KB）
pkgs_kb() {
    (( $# )) || { echo 0; return; }
    dpkg-query -W -f='${Installed-Size}\n' "$@" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'
}

in_list() {
    local needle=$1 x; shift
    for x in "$@"; do [[ $x == "$needle" ]] && return 0; done
    return 1
}

# -----------------------------------------------------------------------------
# 系统识别
# -----------------------------------------------------------------------------
detect_system() {
    [[ -r /etc/os-release ]] || die "找不到 /etc/os-release，无法识别系统"
    local id ver name
    # 用 "|" 分隔：testing/sid 没有 VERSION_ID，用空格或制表符分隔时空字段会被吞掉、字段错位
    IFS='|' read -r id ver name < <(
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s|%s|%s\n' "${ID:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-未知系统}"
    )
    OS_NAME=$name

    case "$id:${ver%%.*}" in
        debian:12|debian:13) ;;
        debian:*)
            warn "检测到 $OS_NAME，本脚本只在 Debian 12/13 上设计和检查过。"
            ask_yn "仍要继续吗？" n || exit 1 ;;
        *)
            warn "当前系统不是 Debian（$OS_NAME），本脚本只为 Debian 12/13 设计。"
            ask_yn "仍要继续吗？" n || exit 1 ;;
    esac

    IS_CONTAINER=0
    if [[ -f /.dockerenv ]] || systemd-detect-virt --quiet --container 2>/dev/null; then
        IS_CONTAINER=1
    fi
    RUNNING_KERNEL=$(uname -r)
    TMP_IS_TMPFS=0
    [[ $(findmnt -no FSTYPE --target /tmp 2>/dev/null) == tmpfs ]] && TMP_IS_TMPFS=1
    return 0
}

print_banner() {
    info "=============================================================="
    info " Debian 12 / 13 交互式系统清理"
    info "=============================================================="
    info " 系统     : $OS_NAME"
    info " 运行内核 : $RUNNING_KERNEL"
    (( IS_CONTAINER )) && info " 环境     : 容器"
    info " 根分区   : $(df -Ph / | awk 'NR == 2 { printf "已用 %s / 共 %s（%s）", $3, $2, $5 }')"
    (( DRY_RUN )) && info " 模式     : DRY-RUN（只显示，不修改）"
    info "=============================================================="
}

# -----------------------------------------------------------------------------
# 清理项目表：编号即数组下标 + 1
# -----------------------------------------------------------------------------
ITEM_ID=(); ITEM_TITLE=(); ITEM_INFO=(); ITEM_ON=(); ITEM_AVAIL=(); ITEM_NOTE=()

# add_item <id> <标题> <概况> <默认勾选 0|1> <可用 0|1> <说明>
add_item() {
    ITEM_ID+=("$1"); ITEM_TITLE+=("$2"); ITEM_INFO+=("$3")
    ITEM_AVAIL+=("$5"); ITEM_NOTE+=("$6")
    if (( $5 )); then ITEM_ON+=("$4"); else ITEM_ON+=(0); fi
}

is_on() {
    local i
    for i in "${!ITEM_ID[@]}"; do
        [[ ${ITEM_ID[i]} == "$1" ]] && { (( ITEM_ON[i] )); return; }
    done
    return 1
}

# ---- 1. 旧内核 ---------------------------------------------------------------
# 从内核版本串里取出"上游版本 + Debian ABI"：
#   6.1.0-21-amd64 / 6.1.0-21-cloud-amd64 -> 6.1.0-21      （Debian 12）
#   6.12.38+deb13-amd64                   -> 6.12.38+deb13 （Debian 13）
kernel_abi() {
    [[ $1 =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9]+)?(\+[A-Za-z0-9.~]+)?) ]] && printf '%s' "${BASH_REMATCH[1]}"
}

KERNEL_PURGE=(); KERNEL_KEEP=()
scan_kernels() {
    local title="旧内核"
    if (( IS_CONTAINER )); then
        add_item kernels "$title" "容器内不涉及内核" 0 0 ""
        return
    fi

    local running_abi newest_pkg='' newest_ver='' newest_abi pkg ver status abi found=0
    running_abi=$(kernel_abi "$RUNNING_KERNEL")

    while read -r pkg ver; do
        [[ -n $running_abi && $(kernel_abi "${pkg#linux-image-}") == "$running_abi" ]] && found=1
        if [[ -z $newest_ver ]] || dpkg --compare-versions "$ver" gt "$newest_ver"; then
            newest_pkg=$pkg; newest_ver=$ver
        fi
    done < <(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' 'linux-image-[0-9]*' 2>/dev/null |
             awk '$1 == "ii" { print $2, $3 }')

    # 正在运行的内核不是 apt 装的（自编译、OpenVZ 等）时，无法判断该保留哪个，直接跳过
    if (( ! found )); then
        add_item kernels "$title" "运行中的内核不是通过 apt 安装的，为安全起见跳过" 0 0 ""
        return
    fi
    newest_abi=$(kernel_abi "${newest_pkg#linux-image-}")

    # 同时处理只剩配置文件（rc 状态）的旧内核包
    while read -r status pkg; do
        abi=$(kernel_abi "${pkg#linux-*-}")
        [[ -n $abi ]] || continue        # linux-image-amd64 等元包不带版本号，永远不动
        if [[ $abi == "$running_abi" || $abi == "$newest_abi" ]]; then
            [[ $status == ii ]] && KERNEL_KEEP+=("$pkg")
        else
            KERNEL_PURGE+=("$pkg")
        fi
    done < <(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 'linux-image-[0-9]*' 'linux-headers-[0-9]*' 2>/dev/null |
             awk '$1 == "ii" || $1 == "rc" { print $1, $2 }')

    local keep="保留运行中的 $running_abi"
    [[ $newest_abi != "$running_abi" ]] && keep+=" 和最新的 $newest_abi（重启后生效）"
    if (( ${#KERNEL_PURGE[@]} )); then
        add_item kernels "$title" "${#KERNEL_PURGE[@]} 个软件包，约 $(human_kb "$(pkgs_kb "${KERNEL_PURGE[@]}")")" 1 1 "$keep"
    else
        add_item kernels "$title" "没有需要删除的" 0 0 ""
    fi
}

step_kernels() {
    local sim p extra=()
    if ! sim=$(LC_ALL=C apt-get -s purge "${KERNEL_PURGE[@]}" 2>&1); then
        warn "apt 模拟删除失败，跳过内核清理："
        printf '%s\n' "$sim" | tail -n 3 >&2
        return 1
    fi
    while read -r p; do
        in_list "$p" "${KERNEL_PURGE[@]}" || extra+=("$p")
    done < <(awk '$1 == "Purg" || $1 == "Remv" { print $2 }' <<<"$sim")

    if (( ${#extra[@]} )); then
        for p in "${extra[@]}"; do
            if in_list "$p" "${KERNEL_KEEP[@]}"; then
                warn "apt 会连带删除需要保留的 $p，已放弃内核清理。"
                return 1
            fi
        done
        warn "apt 表示还会连带删除以下软件包："
        printf '      %s\n' "${extra[@]}" >&2
        ask_yn "    仍然继续吗？" n || { info "    已跳过内核清理。"; return 0; }
    fi

    run apt_get purge -y "${KERNEL_PURGE[@]}"
    command -v update-grub >/dev/null 2>&1 && run update-grub
    return 0
}

# ---- 2. 不再需要的依赖包 -----------------------------------------------------
ORPHANS=()
scan_orphans() {
    local p
    while read -r p; do ORPHANS+=("$p"); done < <(
        LC_ALL=C apt-get -s autoremove --purge 2>/dev/null | awk '$1 == "Purg" || $1 == "Remv" { print $2 }')
    if (( ${#ORPHANS[@]} )); then
        add_item orphans "不再需要的依赖包" "${#ORPHANS[@]} 个，约 $(human_kb "$(pkgs_kb "${ORPHANS[@]}")")" 1 1 \
            "apt-get autoremove --purge（apt 自身也可能顺带清理部分旧内核）"
    else
        add_item orphans "不再需要的依赖包" "没有" 0 0 ""
    fi
}
step_orphans() { run apt_get autoremove --purge -y; }

# ---- 3. APT 下载缓存 ---------------------------------------------------------
scan_aptcache() {
    local kb
    kb=$(du_kb /var/cache/apt/archives /var/cache/apt/*.bin)
    if (( kb > 64 )); then
        add_item aptcache "APT 下载缓存" "约 $(human_kb "$kb")" 1 1 "apt-get clean，已下载的 .deb 安装包"
    else
        add_item aptcache "APT 下载缓存" "已经是空的" 0 0 ""
    fi
}
step_aptcache() { run apt_get clean; }

# ---- 4. systemd journal ------------------------------------------------------
scan_journal() {
    if command -v journalctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        local usage
        usage=$(LC_ALL=C journalctl --disk-usage 2>/dev/null | sed -n 's/.*take up \([^ ]*\) .*/\1/p')
        add_item journal "systemd 日志（journal）" "当前占用 ${usage:-未知}" 1 1 "按保留天数和总大小收缩，下一步可修改"
    else
        add_item journal "systemd 日志（journal）" "系统未以 systemd 运行" 0 0 ""
    fi
}
step_journal() {
    # 先 rotate，否则正在写入的日志文件无法被 vacuum 回收
    run journalctl --rotate
    run journalctl --vacuum-time="${JOURNAL_KEEP_DAYS}d" --vacuum-size="$JOURNAL_MAX_SIZE"
}

# ---- 5. 已轮转的旧日志 -------------------------------------------------------
# syslog.1、*.log.2.gz 之类 logrotate 留下的历史文件；不碰 /var/log/journal
ROTATED_FIND=(/var/log -xdev -path /var/log/journal -prune -o -type f
    '(' -name '*.gz' -o -name '*.xz' -o -name '*.zst' -o -name '*.old' -o -regex '.*\.[0-9]+' ')')
scan_rotated() {
    local kb
    kb=$(find "${ROTATED_FIND[@]}" -printf '%s\n' 2>/dev/null | bytes_to_kb)
    if (( kb > 0 )); then
        add_item rotated "已轮转的旧日志" "约 $(human_kb "$kb")" 1 1 "/var/log 下的 *.gz、*.1 等历史日志，当前日志不受影响"
    else
        add_item rotated "已轮转的旧日志" "没有" 0 0 ""
    fi
}
step_rotated() { run find "${ROTATED_FIND[@]}" -exec rm -f -- {} +; }

# ---- 6. 截断当前日志 ---------------------------------------------------------
ACTIVE_LOG_FIND=(/var/log -xdev -path /var/log/journal -prune -o -type f -size +0
    '(' -name '*.log' -o -name syslog -o -name messages -o -name debug ')')
scan_truncate() {
    local kb
    kb=$(find "${ACTIVE_LOG_FIND[@]}" -printf '%s\n' 2>/dev/null | bytes_to_kb)
    if (( kb > 0 )); then
        add_item truncate "清空当前日志文件" "约 $(human_kb "$kb")" 0 1 \
            "把 *.log、syslog 等清零（文件保留）。排查问题要用的记录会一起没掉，默认不选"
    else
        add_item truncate "清空当前日志文件" "没有" 0 0 ""
    fi
}
step_truncate() { run find "${ACTIVE_LOG_FIND[@]}" -exec truncate -s 0 -- {} +; }

# ---- 7. 临时文件 -------------------------------------------------------------
# 跳过：开启 PrivateTmp 的服务正在用的 systemd-private-*、X11/ICE 会话 socket 目录、tmux 目录
TMP_PRUNE=('(' -name 'systemd-private-*' -o -name 'snap-private-tmp' -o -name '.X11-unix'
    -o -name '.ICE-unix' -o -name '.XIM-unix' -o -name '.font-unix' -o -name 'tmux-*' ')' -prune)

# tmp_find <天数> <find 动作...>：列出既没被访问也没被修改超过 N 天的普通文件和链接
tmp_find() {
    local days=$1; shift
    find /tmp /var/tmp -xdev -mindepth 1 "${TMP_PRUNE[@]}" -o \
        '(' -type f -o -type l ')' -atime +"$days" -mtime +"$days" "$@" 2>/dev/null
}
scan_tmp() {
    local kb note="只删超过 N 天没用过的文件，正在使用的不动"
    kb=$(tmp_find "$TMP_MAX_AGE_DAYS" -printf '%s\n' | bytes_to_kb)
    (( TMP_IS_TMPFS )) && note+="；/tmp 是内存盘，清理它释放的是内存"
    if (( kb > 0 )); then
        add_item tmp "临时文件 /tmp、/var/tmp" "超过 ${TMP_MAX_AGE_DAYS} 天未用的约 $(human_kb "$kb")" 1 1 "$note"
    else
        add_item tmp "临时文件 /tmp、/var/tmp" "没有超过 ${TMP_MAX_AGE_DAYS} 天未用的文件" 0 0 ""
    fi
}
step_tmp() {
    run tmp_find "$TMP_MAX_AGE_DAYS" -exec rm -f -- {} +
    # 顺带删掉同样很久没动过的空目录
    run find /tmp /var/tmp -xdev -mindepth 1 "${TMP_PRUNE[@]}" -o \
        -type d -empty -mtime +"$TMP_MAX_AGE_DAYS" -exec rmdir -- {} +
}

# ---- 8. 用户缓存 -------------------------------------------------------------
CACHE_DIRS=()
scan_usercache() {
    local h kb
    for h in /root /home/*; do
        [[ -d $h && ! -L $h && -d $h/.cache && ! -L $h/.cache ]] && CACHE_DIRS+=("$h/.cache")
    done
    kb=$(du_kb "${CACHE_DIRS[@]}")
    if (( kb > 0 )); then
        add_item usercache "用户缓存 ~/.cache" "${#CACHE_DIRS[@]} 个用户，约 $(human_kb "$kb")" 0 1 \
            "pip、npm、浏览器等缓存，可重新生成，但下次使用会变慢"
    else
        add_item usercache "用户缓存 ~/.cache" "没有" 0 0 ""
    fi
}
step_usercache() {
    local d
    for d in "${CACHE_DIRS[@]}"; do
        run find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    done
}

# ---- 9. Docker ---------------------------------------------------------------
scan_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        add_item docker "Docker" "未安装" 0 0 ""
    elif ! docker info >/dev/null 2>&1; then
        add_item docker "Docker" "守护进程未运行" 0 0 ""
    else
        local df
        df=$(docker system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null |
             awk 'BEGIN { ORS = "" } { print (NR > 1 ? "；" : "") $0 }')
        add_item docker "Docker" "可回收：${df:-未知}" 0 1 "下一步选择清理程度"
    fi
}
step_docker() {
    case "$DOCKER_LEVEL" in
        1) run docker system prune -f ;;
        2) run docker system prune -a -f ;;
        3) run docker system prune -a -f --volumes ;;
    esac
}

scan_all() {
    scan_kernels
    scan_orphans
    scan_aptcache
    scan_journal
    scan_rotated
    scan_truncate
    scan_tmp
    scan_usercache
    scan_docker
}

# -----------------------------------------------------------------------------
# 菜单
# -----------------------------------------------------------------------------
show_menu() {
    local i mark
    printf '\n%s可清理的项目%s（[x] = 已选中，灰色 = 无需清理）\n\n' "$BOLD" "$NC"
    for i in "${!ITEM_ID[@]}"; do
        if (( ! ITEM_AVAIL[i] )); then
            printf '  %s[-] %d. %s：%s%s\n' "$DIM" "$((i + 1))" "${ITEM_TITLE[i]}" "${ITEM_INFO[i]}" "$NC"
            continue
        fi
        mark=' '
        (( ITEM_ON[i] )) && mark="${GREEN}x${NC}"
        printf '  [%s] %d. %s：%s\n' "$mark" "$((i + 1))" "${ITEM_TITLE[i]}" "${ITEM_INFO[i]}"
        [[ -n ${ITEM_NOTE[i]} ]] && printf '         %s%s%s\n' "$DIM" "${ITEM_NOTE[i]}" "$NC"
    done
}

choose_items() {
    (( ASSUME_YES )) && return
    local input tok i toks
    while true; do
        show_menu
        printf '\n输入编号切换选中（可输入多个，如 "5 8"），a = 全选，n = 全不选，回车 = 下一步，q = 退出\n'
        read -r -p '> ' input </dev/tty || input=q
        case "$input" in
            '')   return ;;
            q|Q)  info "已退出，没有做任何修改。"; exit 0 ;;
            a|A)  for i in "${!ITEM_ID[@]}"; do (( ITEM_AVAIL[i] )) && ITEM_ON[i]=1; done ;;
            n|N)  for i in "${!ITEM_ID[@]}"; do ITEM_ON[i]=0; done ;;
            *)
                read -ra toks <<<"${input//,/ }"
                for tok in "${toks[@]}"; do
                    if [[ $tok =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#ITEM_ID[@]} )); then
                        i=$((tok - 1))
                        if (( ITEM_AVAIL[i] )); then
                            ITEM_ON[i]=$((1 - ITEM_ON[i]))
                        else
                            warn "第 $tok 项没有需要清理的内容"
                        fi
                    else
                        warn "无效输入：$tok"
                    fi
                done
                ;;
        esac
    done
}

# 选中项目的细节设置
configure_selected() {
    (( ASSUME_YES )) && return
    if is_on kernels; then
        printf '\n%s旧内核%s\n  将删除：\n' "$BOLD" "$NC"
        printf '    %s\n' "${KERNEL_PURGE[@]}"
        printf '  将保留：\n'
        printf '    %s\n' "${KERNEL_KEEP[@]}"
    fi
    if is_on journal; then
        printf '\n%ssystemd 日志%s\n' "$BOLD" "$NC"
        JOURNAL_KEEP_DAYS=$(ask_value "  保留最近几天" "$JOURNAL_KEEP_DAYS" '^[0-9]+$')
        JOURNAL_MAX_SIZE=$(ask_value "  总大小上限（如 200M、1G）" "$JOURNAL_MAX_SIZE" '^[0-9]+[KMG]$')
    fi
    if is_on tmp; then
        printf '\n%s临时文件%s\n' "$BOLD" "$NC"
        TMP_MAX_AGE_DAYS=$(ask_value "  删除多少天没用过的文件" "$TMP_MAX_AGE_DAYS" '^[0-9]+$')
    fi
    if is_on docker; then
        printf '\n%sDocker 清理程度%s\n' "$BOLD" "$NC"
        printf '  1) 停止的容器、悬空镜像、构建缓存（最安全）\n'
        printf '  2) 再加上所有没被容器使用的镜像（之后需要重新拉取）\n'
        printf '  3) 再加上没被容器使用的数据卷（%s数据会永久丢失%s）\n' "$RED" "$NC"
        DOCKER_LEVEL=$(ask_value "  请选择" "$DOCKER_LEVEL" '^[123]$')
        if [[ $DOCKER_LEVEL == 3 ]] && ! ask_yn "  已停止容器的数据卷也会被删除且无法恢复，确定吗？" n; then
            DOCKER_LEVEL=2
            info "  已改为程度 2，保留数据卷。"
        fi
    fi
}

show_plan() {
    local i id extra
    printf '\n%s即将执行：%s\n' "$BOLD" "$NC"
    for i in "${!ITEM_ID[@]}"; do
        (( ITEM_ON[i] )) || continue
        id=${ITEM_ID[i]}; extra=''
        case "$id" in
            journal) extra="（保留 ${JOURNAL_KEEP_DAYS} 天，上限 ${JOURNAL_MAX_SIZE}）" ;;
            tmp)     extra="（超过 ${TMP_MAX_AGE_DAYS} 天未用）" ;;
            docker)  extra="（程度 ${DOCKER_LEVEL}）" ;;
        esac
        printf '  - %s%s\n' "${ITEM_TITLE[i]}" "$extra"
    done
}

# -----------------------------------------------------------------------------
# 执行
# -----------------------------------------------------------------------------
run_step() {
    local title=$1 fn=$2 before after delta
    before=$(disk_avail_kb)
    printf '\n==> %s\n' "$title"
    "$fn" || warn "「$title」执行时出现问题，已继续后续项目"
    (( DRY_RUN )) && return 0
    after=$(disk_avail_kb)
    delta=$((after - before))
    if (( delta > 0 )); then
        printf '    根分区可用空间增加 %s\n' "$(human_kb "$delta")"
    else
        printf '    根分区可用空间没有变化（内存盘或本来就很小）\n'
    fi
}

main() {
    parse_args "$@"
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
    (( ASSUME_YES || HAVE_TTY )) || die "没有可交互的终端。非交互运行请加 --yes（按默认勾选清理）。"

    detect_system
    print_banner
    info "正在扫描系统，请稍候..."
    scan_all

    choose_items
    local i count=0
    for i in "${!ITEM_ID[@]}"; do (( ITEM_ON[i] )) && count=$((count + 1)); done
    if (( count == 0 )); then
        info "没有选中任何项目，已退出。"
        exit 0
    fi

    configure_selected
    show_plan
    if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
        printf '\n'
        ask_yn "确认开始清理？" n || { info "已取消，没有做任何修改。"; exit 0; }
    fi

    local start_avail end_avail freed
    start_avail=$(disk_avail_kb)
    for i in "${!ITEM_ID[@]}"; do
        (( ITEM_ON[i] )) || continue
        run_step "${ITEM_TITLE[i]}" "step_${ITEM_ID[i]}"
    done

    printf '\n==============================================================\n'
    if (( DRY_RUN )); then
        info "DRY-RUN 结束，没有做任何修改。去掉 --dry-run 即可真正执行。"
        return 0
    fi
    end_avail=$(disk_avail_kb)
    freed=$((end_avail - start_avail))
    (( freed < 0 )) && freed=0
    info "清理完成，根分区共释放 $(human_kb "$freed")。"
    info "当前根分区：$(df -Ph / | awk 'NR == 2 { printf "已用 %s / 共 %s（%s）", $3, $2, $5 }')"
    is_on kernels && info "删除过旧内核，建议找时间重启一次，确认系统能正常启动。"
    return 0
}

main "$@"
