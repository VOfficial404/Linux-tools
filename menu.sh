#!/usr/bin/env bash
#
# Linux-tools 总控菜单
#
# 用法：
#   在仓库目录里：         sudo bash menu.sh
#   只下载这一个文件：     curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/menu.sh -o menu.sh && sudo bash menu.sh
#
# 把仓库里的各个脚本集中到一个交互式菜单里，输入编号即可执行。
# 子脚本仍然各自独立，也可以单独运行；本脚本只负责询问参数、调用和汇报结果。
#
# 子脚本按以下顺序查找，用到哪个才取哪个：
#   1. 本地仓库：menu.sh 旁边的 Debian/、update-motd/ 等目录
#   2. 整合版内置：由 build.sh 生成的 linux-tools.sh 里自带的副本
#   3. 在线下载：从 GitHub 仓库（LT_REPO_RAW）下载到临时目录，退出时删除
# 本文件是在线版（方案二）；整合版（方案一）linux-tools.sh 由 build.sh 从本文件生成，不要直接改整合版。

set -uo pipefail

# 通过管道或 bash -c 运行时没有脚本路径，此时不找本地仓库
BASE_DIR=''
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
    BASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

# 在线下载地址，可用环境变量改成自己的分支或镜像
REPO_RAW="${LT_REPO_RAW:-https://raw.githubusercontent.com/VOfficial404/Linux-tools/main}"

# 以下都是相对仓库根目录的路径
CLEAR="Debian/clear.sh"
XANMOD="Debian/xanmod-kernel.sh"
SINGBOX="Debian/singbox.sh"
Q_SH="Debian/q.sh"
GOLANG="Debian/golong.sh"
SWAP_SH="Debian/swap.sh"
SSH_KEYONLY="Debian/ssh-keyonly.sh"
HOSTNAME_SH="Debian/hostname.sh"
SSH_CHECK="ssh-check.sh"
MOTD_DIR="/etc/update-motd.d"
MOTD_BACKUP="/etc/motd.bak-linux-tools"

# 取到的子脚本放在这里，退出时整个删除
WORK_DIR=$(mktemp -d /tmp/linux-tools.XXXXXX) || { echo "无法创建临时目录" >&2; exit 1; }
trap 'rm -rf -- "$WORK_DIR"' EXIT

# GitHub 下载失败时，motd 文件再试一次这些短链接
declare -A MOTD_URL=(
    [20-DSH-32]="https://lnk.ixwx.de/dsh-32"
    [20-DSH-mono-32]="https://lnk.ixwx.de/dsh-mono-32"
    [25-sysinfo]="https://lnk.ixwx.de/sysinfo"
)

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 交互：一律从 /dev/tty 读，用 curl ... | bash 运行时也能正常提问
# -----------------------------------------------------------------------------
HAVE_TTY=0
{ : </dev/tty; } 2>/dev/null && HAVE_TTY=1

# ask_yn <提示> <默认 y|n>
ask_yn() {
    local prompt=$1 def=$2 hint='[y/N]' reply=''
    [[ $def == y ]] && hint='[Y/n]'
    read -r -p "$prompt $hint " reply </dev/tty || reply=''
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

pause() { printf '\n'; read -r -p "按回车返回菜单..." _ </dev/tty || true; }

clear_screen() { [[ -t 1 ]] && printf '\033[H\033[2J'; return 0; }

# -----------------------------------------------------------------------------
# 取子脚本：本地仓库 -> 整合版内置 -> 在线下载
# -----------------------------------------------------------------------------
# 整合版里每个文件对应一个函数，如 Debian/clear.sh -> payload_Debian_clear_sh
payload_fn() { printf 'payload_%s' "${1//[^A-Za-z0-9]/_}"; }

# 当前用的是哪种来源（显示在菜单顶部）
script_source() {
    if [[ -n $BASE_DIR && -f $BASE_DIR/$CLEAR ]]; then
        printf '本地仓库 %s' "$BASE_DIR"
    elif declare -F "$(payload_fn "$CLEAR")" >/dev/null; then
        printf '整合版内置'
    else
        printf '在线下载 %s' "$REPO_RAW"
    fi
}

# download <网址> <输出文件>：确认拿到的是脚本（以 #! 开头）才算成功，
# 避免链接失效时把空文件或一张网页当脚本运行
download() {
    local url=$1 out=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 60 -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O "$out" "$url"
    else
        warn "没有 curl 也没有 wget，无法下载"
        return 1
    fi || return 1
    [[ -s $out && $(head -c 2 "$out") == '#!' ]]
}

# fetch_script <相对路径>：把子脚本准备好，输出它的完整路径
fetch_script() {
    local rel=$1 out="$WORK_DIR/$1" fn name
    if [[ -n $BASE_DIR && -f $BASE_DIR/$rel ]]; then
        printf '%s' "$BASE_DIR/$rel"
        return
    fi
    [[ -s $out ]] && { printf '%s' "$out"; return; }   # 本次运行已经取过
    mkdir -p "$(dirname "$out")"

    fn=$(payload_fn "$rel")
    if declare -F "$fn" >/dev/null; then
        "$fn" >"$out"
        printf '%s' "$out"
        return
    fi

    info "下载 $rel ..." >&2
    if download "$REPO_RAW/$rel" "$out"; then
        printf '%s' "$out"
        return
    fi
    name=${rel##*/}
    if [[ -n ${MOTD_URL[$name]:-} ]] && download "${MOTD_URL[$name]}" "$out"; then
        printf '%s' "$out"
        return
    fi
    rm -f -- "$out"
    warn "无法获取 $rel（本地没有，下载也失败）"
    return 1
}

# run_script [变量=值 ...] <相对路径> [参数...]
# 子脚本在独立进程里运行；Ctrl-C 只会中断子脚本，然后回到菜单
run_script() {
    local envs=() path rel rc
    while [[ ${1:-} =~ ^[A-Z_][A-Z0-9_]*= ]]; do envs+=("$1"); shift; done
    rel=$1; shift
    path=$(fetch_script "$rel") || return 127

    printf '\n%s==> 执行 %s%s\n\n' "$BOLD" "$rel" "$NC"
    trap ':' INT
    env "${envs[@]}" bash "$path" "$@"
    rc=$?
    trap - INT

    printf '\n'
    case $rc in
        0)   ok "$rel 执行完毕" ;;
        130) warn "$rel 已被中断（Ctrl-C）" ;;
        *)   warn "$rel 退出码 $rc，请查看上面的输出" ;;
    esac
    return $rc
}

# -----------------------------------------------------------------------------
# 系统信息与各项状态
# -----------------------------------------------------------------------------
detect_system() {
    OS_ID=''; OS_NAME='未知系统'
    if [[ -r /etc/os-release ]]; then
        # 用 "|" 分隔，避免空字段被吞掉
        IFS='|' read -r OS_ID OS_NAME < <(
            # shellcheck disable=SC1091
            . /etc/os-release
            printf '%s|%s\n' "${ID:-}" "${PRETTY_NAME:-未知系统}"
        )
    fi
    ARCH=$(uname -m)
    IS_CONTAINER=0
    if [[ -f /.dockerenv ]] || systemd-detect-virt --quiet --container 2>/dev/null; then
        IS_CONTAINER=1
    fi
}

status_kernel() {
    if [[ $(uname -r) == *xanmod* ]]; then
        printf '%s正在使用 XanMod%s' "$GREEN" "$NC"
    elif dpkg-query -W -f='${db:Status-Abbrev}\n' 'linux-xanmod*' 2>/dev/null | grep -q '^ii'; then
        printf '%s已安装 XanMod，尚未重启%s' "$YELLOW" "$NC"
    else
        printf '未安装'
    fi
}

status_singbox() {
    local v
    if command -v sing-box >/dev/null 2>&1; then
        v=$(sing-box version 2>/dev/null | awk 'NR == 1 { print $NF }')
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            printf '%s%s · 运行中%s' "$GREEN" "$v" "$NC"
        else
            printf '%s%s · 未运行%s' "$YELLOW" "$v" "$NC"
        fi
    else
        printf '未安装'
    fi
}

status_q() {
    if command -v q >/dev/null 2>&1; then
        printf '%s已安装%s' "$GREEN" "$NC"
    else
        printf '未安装'
    fi
}

status_swap() {
    local mb
    mb=$(awk '/^SwapTotal:/ { print int($2 / 1024); exit }' /proc/meminfo)
    if (( ${mb:-0} > 0 )); then
        printf '%s已启用 %s%s · swappiness %s' "$GREEN" \
            "$(awk -v m="$mb" 'BEGIN { if (m >= 1024) printf "%.1fG", m / 1024; else printf "%dM", m }')" \
            "$NC" "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
    else
        printf '%s未启用%s' "$YELLOW" "$NC"
    fi
}

status_ssh_login() {
    local sshd pw
    sshd=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
    [[ -x $sshd ]] || { printf '未安装 sshd'; return; }
    pw=$("$sshd" -T 2>/dev/null | awk '$1 == "passwordauthentication" { print $2; exit }')
    case $pw in
        no)  printf '%s已禁止密码登录%s' "$GREEN" "$NC" ;;
        yes) printf '%s允许密码登录%s' "$YELLOW" "$NC" ;;
        *)   printf '未知' ;;
    esac
}

status_go() {
    if [[ -x /usr/local/go/bin/go ]]; then
        printf '%s已安装 %s%s' "$GREEN" "$(/usr/local/go/bin/go version 2>/dev/null | awk '{ print $3 }')" "$NC"
    else
        printf '未安装'
    fi
}

# 当前安装的 logo 文件名（没有则为空）。
# 手动安装时常用小写的 20-dsh-32，所以大小写都要认
installed_logo() {
    local f
    for f in "$MOTD_DIR"/20-[Dd][Ss][Hh]*; do
        [[ -f $f ]] && { printf '%s' "${f##*/}"; return; }
    done
}

status_motd() {
    local logo parts=()
    logo=$(installed_logo)
    [[ -n $logo ]] && parts+=("logo $logo")
    [[ -f $MOTD_DIR/25-sysinfo ]] && parts+=("系统信息面板")
    if (( ${#parts[@]} )); then
        printf '%s已安装 %s%s' "$GREEN" "${parts[*]}" "$NC"
    else
        printf '未安装'
    fi
}

# -----------------------------------------------------------------------------
# 主菜单
# -----------------------------------------------------------------------------
# item <编号> <标题> <状态>
item() { printf '   %s%2s.%s %s  %s·%s %s\n' "$CYAN" "$1" "$NC" "$2" "$DIM" "$NC" "$3"; }

show_menu() {
    clear_screen
    info "=============================================================="
    info " ${BOLD}Linux-tools 工具箱${NC}"
    info "=============================================================="
    info " 系统 : $OS_NAME"
    info " 内核 : $(uname -r)（$ARCH）"
    info " 根区 : $(df -Ph / | awk 'NR == 2 { printf "已用 %s / 共 %s（%s）", $3, $2, $5 }')"
    (( IS_CONTAINER )) && info " 环境 : 容器"
    info " 脚本 : $(script_source)"
    [[ $OS_ID == debian ]] || info " ${YELLOW}注意：这些脚本为 Debian 12/13 编写，当前系统可能不完全兼容${NC}"
    info "=============================================================="
    printf '\n %s系统维护%s\n' "$BOLD" "$NC"
    item 1 "系统清理" "旧内核、日志、缓存、Docker，逐项勾选"
    item 2 "Swap 管理" "$(status_swap)"
    item 3 "安装 XanMod 内核 + 网络优化" "$(status_kernel)"
    item 4 "SSH 漏洞检查（CVE-2024-6387）" "只检查，不修改"
    item 5 "SSH 禁止密码登录" "$(status_ssh_login)"
    item 6 "修改主机名" "当前：$(hostname 2>/dev/null)"
    printf '\n %s软件安装%s\n' "$BOLD" "$NC"
    item 7 "sing-box（AnyTLS / AnyReality 节点）" "$(status_singbox)"
    item 8 "q（DNS 查询工具）" "$(status_q)"
    item 9 "Go 语言" "$(status_go)"
    printf '\n %s登录界面%s\n' "$BOLD" "$NC"
    item 10 "登录面板（motd）" "$(status_motd)"
    printf '\n'
    item 0 "退出" ""
    printf '\n'
}

# -----------------------------------------------------------------------------
# 各功能
# -----------------------------------------------------------------------------
do_clear() {
    printf '\n%s系统清理%s\n' "$BOLD" "$NC"
    printf '  1) 开始清理（扫描后逐项勾选，确认后才删除）\n'
    printf '  2) 预演（同样选择，只显示将执行的命令，不做修改）\n'
    printf '  0) 返回\n'
    case $(ask_value "请选择" 1 '^[012]$') in
        1) run_script "$CLEAR" ;;
        2) run_script "$CLEAR" --dry-run ;;
        *) return 0 ;;
    esac
    pause
}

# swap.sh 自带菜单，退出它就回到这里；只有出错时才停下来让你看输出
do_swap() {
    run_script "$SWAP_SH" || pause
}

# ssh-keyonly.sh 也自带菜单，出错时才停下来
do_ssh_keyonly() {
    run_script "$SSH_KEYONLY" || pause
}

do_xanmod() {
    printf '\n%s安装 XanMod 内核 + 网络优化%s\n' "$BOLD" "$NC"
    if [[ $ARCH != x86_64 ]]; then
        warn "XanMod 只提供 x86_64 内核，当前架构是 $ARCH。"
        pause; return
    fi
    if (( IS_CONTAINER )); then
        warn "当前在容器里，安装的内核不会被使用（容器共用宿主机内核）。"
        pause; return
    fi
    info "该脚本会："
    info "  - 添加 XanMod 软件源，并执行一次完整的系统升级（dist-upgrade）"
    info "  - 按 CPU 级别安装 XanMod 内核（会让你选择 LTS / MAIN / RT）"
    info "  - 没有交换空间时创建 1G 的 /swapfile"
    info "  - 写入网络优化参数 /etc/sysctl.d/99-xanmod-optimizations.conf（BBR 等）"
    info "  - 最后询问是否重启"
    ask_yn "确定继续吗？" n || return 0
    run_script "$XANMOD"
    pause
}

do_ssh_check() {
    local rc
    run_script "$SSH_CHECK"
    rc=$?
    case $rc in
        0) printf '%s结论：不受 regreSSHion 影响。%s\n' "$GREEN" "$NC" ;;
        1) printf '%s结论：受影响，请尽快升级 openssh-server：apt update && apt install openssh-server%s\n' "$RED" "$NC" ;;
        2) info "结论：系统里没有 sshd / ssh，无需处理。" ;;
        3) info "结论：无法识别 OpenSSH 版本，请手动执行 sshd -V 查看。" ;;
    esac
    pause
}

# singbox.sh 自带菜单（安装、配置节点、链接、卸载），出错时才停下来
do_singbox() {
    run_script "$SINGBOX" || pause
}

# 简单的软件源安装类：q
do_apt_install() {
    local name=$1 script=$2 status=$3
    printf '\n%s安装 %s%s  （当前：%s）\n' "$BOLD" "$name" "$NC" "$status"
    info "会添加 $name 官方 apt 软件源和签名密钥，然后用 apt 安装；已安装时会升级到最新版。"
    ask_yn "确定继续吗？" y || return 0
    run_script "$script"
    pause
}

do_go() {
    local ver
    printf '\n%s安装 Go 语言%s  （当前：%s）\n' "$BOLD" "$NC" "$(status_go)"
    info "安装到 /usr/local/go，PATH 写入 /etc/profile.d/go.sh。"
    ver=$(ask_value "  版本号（latest = 官方最新稳定版，如 1.23.4）" latest '^(latest|[0-9]+\.[0-9]+(\.[0-9]+)?)$')
    [[ $ver == latest ]] && ver=''
    run_script "GO_VERSION=$ver" "$GOLANG"
    pause
}

# ---- 登录面板 motd -----------------------------------------------------------
# 删除所有已安装的 logo，大小写两种文件名都删
remove_logos() { rm -f -- "$MOTD_DIR"/20-[Dd][Ss][Hh]*; }

motd_install_logo() {
    local logos=(20-DSH 20-DSH-32 20-DSH-mono 20-DSH-mono-32)
    local descs=("彩色 40×20" "彩色 32×16（窄屏）" "黑白 40×20（任何终端都能显示）" "黑白 32×16")
    local i choice f src
    printf '\n%s选择 logo%s（需要终端支持 256 色才能正常显示彩色版）\n' "$BOLD" "$NC"
    for i in "${!logos[@]}"; do
        printf '  %d) %-15s %s\n' "$((i + 1))" "${logos[i]}" "${descs[i]}"
    done
    printf '  5) 不要 logo（删除已安装的）\n  0) 返回\n'
    choice=$(ask_value "请选择" 0 '^[0-5]$')
    [[ $choice == 0 ]] && return

    if [[ $choice == 5 ]]; then
        remove_logos
        ok "已删除 logo"
        return
    fi

    f=${logos[choice - 1]}
    src=$(fetch_script "update-motd/$f") || return
    printf '\n%s预览：%s\n' "$DIM" "$NC"
    sh "$src"
    printf '\n'
    if ask_yn "安装这个 logo 吗？" y; then
        mkdir -p "$MOTD_DIR"
        # 只保留一个 logo，避免登录时连续打印两个（包括以前手动装的小写 20-dsh-*）
        remove_logos
        install -m 0755 "$src" "$MOTD_DIR/$f"
        ok "已安装 $MOTD_DIR/$f"
    fi
}

motd_install_sysinfo() {
    local src
    src=$(fetch_script update-motd/25-sysinfo) || return
    mkdir -p "$MOTD_DIR"
    install -m 0755 "$src" "$MOTD_DIR/25-sysinfo"
    ok "已安装 $MOTD_DIR/25-sysinfo"
    if ! command -v last >/dev/null 2>&1; then
        warn "没有 last 命令，面板里的登录记录会显示为空。Debian 13 可执行：apt install wtmpdb libpam-wtmpdb"
    fi
}

# Debian 默认会在登录时打印 uname 一行（10-uname）和 /etc/motd 里的免责声明
motd_hide_default() {
    [[ -f $MOTD_DIR/10-uname ]] && chmod -x "$MOTD_DIR/10-uname" && ok "已停用 $MOTD_DIR/10-uname"
    if [[ -s /etc/motd ]]; then
        [[ -e $MOTD_BACKUP ]] || cp -a /etc/motd "$MOTD_BACKUP"
        : > /etc/motd
        ok "已清空 /etc/motd（原内容备份在 $MOTD_BACKUP）"
    fi
}

motd_preview() {
    printf '\n%s---------- 登录时将显示 ----------%s\n' "$DIM" "$NC"
    if command -v run-parts >/dev/null 2>&1 && [[ -d $MOTD_DIR ]]; then
        run-parts "$MOTD_DIR"
    fi
    [[ -s /etc/motd ]] && cat /etc/motd
    printf '%s----------------------------------%s\n' "$DIM" "$NC"
}

motd_uninstall() {
    ask_yn "删除本工具安装的 logo 和系统信息面板，并恢复 Debian 默认内容？" n || return
    remove_logos
    rm -f -- "$MOTD_DIR/25-sysinfo"
    [[ -f $MOTD_DIR/10-uname ]] && chmod +x "$MOTD_DIR/10-uname"
    if [[ -f $MOTD_BACKUP ]]; then
        mv -f "$MOTD_BACKUP" /etc/motd
    fi
    ok "已卸载登录面板"
}

do_motd() {
    while true; do
        printf '\n%s登录面板（motd）%s  （当前：%s）\n' "$BOLD" "$NC" "$(status_motd)"
        printf '  1) 安装 / 更换 logo\n'
        printf '  2) 安装系统信息面板（负载、内存、磁盘、连接、流量、最近登录）\n'
        printf '  3) 隐藏 Debian 默认的内核版本行和 /etc/motd 免责声明\n'
        printf '  4) 预览登录面板\n'
        printf '  5) 卸载，恢复默认\n'
        printf '  0) 返回主菜单\n'
        case $(ask_value "请选择" 0 '^[0-5]$') in
            1) motd_install_logo ;;
            2) motd_install_sysinfo ;;
            3) motd_hide_default ;;
            4) motd_preview ;;
            5) motd_uninstall ;;
            *) return ;;
        esac
    done
}

# build.sh 在生成整合版时，会把所有子脚本的内容插到下面这一行（在线版里这一行什么都不做）
# @@LT_PAYLOADS@@

# -----------------------------------------------------------------------------
main() {
    case ${1:-} in
        -h|--help) info "用法: sudo bash ${0##*/}    打开交互式菜单"; exit 0 ;;
    esac
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
    (( HAVE_TTY )) || die "需要在交互式终端里运行。"

    detect_system
    local choice
    while true; do
        show_menu
        read -r -p "请输入编号: " choice </dev/tty || choice=0
        case $choice in
            1) do_clear ;;
            2) do_swap ;;
            3) do_xanmod ;;
            4) do_ssh_check ;;
            5) do_ssh_keyonly ;;
            6) run_script "$HOSTNAME_SH"; pause ;;
            7) do_singbox ;;
            8) do_apt_install "q" "$Q_SH" "$(status_q)" ;;
            9) do_go ;;
            10) do_motd ;;
            0|q|Q) info "再见。"; exit 0 ;;
            '') ;;
            *) warn "无效编号：$choice"; sleep 1 ;;
        esac
    done
}

main "$@"
