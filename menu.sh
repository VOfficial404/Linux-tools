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
DOCKER_SH="Debian/docker.sh"
CVE_98432_SH="Debian/cve-2026-98432.sh"
SSH_CHECK="ssh-check.sh"

# 第三方脚本：不在本仓库里，也不打包进整合版，每次都从上游原样下载最新版运行，不做任何修改
TCPQUALITY_URL="https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh"
NODEQUALITY_URL="https://run.NodeQuality.com"
INSTALLNET_URL="https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh"
REINSTALL_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
REINSTALL_URL_CN="https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh"
INSTALLNET_DEFAULT_PW="LeitboGi0ro"

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

status_docker() {
    local v
    if command -v docker >/dev/null 2>&1; then
        v=$(docker --version 2>/dev/null | awk '{ gsub(",", "", $3); print $3 }')
        if systemctl is-active --quiet docker 2>/dev/null; then
            printf '%s%s · 运行中%s' "$GREEN" "$v" "$NC"
        else
            printf '%s%s · 未运行%s' "$YELLOW" "$v" "$NC"
        fi
    else
        printf '未安装'
    fi
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
    item 7 "内核漏洞 CVE-2026-98432（严重 9.8）" "检测，可升级内核修复或临时缓解"
    printf '\n %s软件安装%s\n' "$BOLD" "$NC"
    item 8 "sing-box（AnyTLS / AnyReality 节点）" "$(status_singbox)"
    item 9 "q（DNS 查询工具）" "$(status_q)"
    item 10 "Go 语言" "$(status_go)"
    item 11 "Docker + Docker Compose" "$(status_docker)"
    printf '\n %s登录界面%s\n' "$BOLD" "$NC"
    item 12 "登录面板（motd）" "$(status_motd)"
    printf '\n %s测试工具%s %s（第三方脚本，运行时从上游下载，不做修改）%s\n' "$BOLD" "$NC" "$DIM" "$NC"
    item 13 "TcpQuality（TCP 网络质量）" "ibsgss/TcpQuality"
    item 14 "NodeQuality（硬件 / IP / 网络综合测试）" "结果会上传到 nodequality.com"
    printf '\n %sDD 重装系统%s %s（第三方脚本，会清空系统盘）%s\n' "$BOLD" "$NC" "$DIM" "$NC"
    item 15 "InstallNET.sh" "leitbogioro/Tools"
    item 16 "reinstall.sh" "bin456789/reinstall"
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

# ---- 第三方脚本（测试工具、DD 重装系统）-------------------------------------
# 这里只负责下载、询问参数、调用和解释结果，脚本本身原样运行。

# fetch_remote <文件名> <网址> [备用网址...]：每次重新下载到临时目录，输出路径。
# 保存成真实文件再用 bash 运行，而不是 bash <(curl ...)：InstallNET.sh 出错时会执行 bash $0，
# reinstall.sh 会用 $0 读取自身，管道或 /dev/fd/63 都会出问题
fetch_remote() {
    local name=$1 out="$WORK_DIR/thirdparty/$1" url
    shift
    mkdir -p "$WORK_DIR/thirdparty"
    for url in "$@"; do
        info "下载 $url ..." >&2
        download "$url" "$out" && { printf '%s' "$out"; return; }
    done
    rm -f -- "$out"
    warn "下载 $name 失败，请检查网络"
    return 1
}

# run_remote <脚本路径> [参数...]：原样运行，返回它的退出码。
# 标准输入接到终端：这些脚本用普通的 read 提问，而用 curl ... | bash 打开菜单时 stdin 是管道
run_remote() {
    local path=$1 rc
    shift
    printf '\n%s==> 执行第三方脚本 %s %s%s\n\n' "$BOLD" "${path##*/}" "$(mask_args "$@")" "$NC"
    trap ':' INT
    bash "$path" "$@" </dev/tty
    rc=$?
    trap - INT
    printf '\n'
    return $rc
}

# read_args <提示>：读一行参数，按空格拆分放进 ARGS（不支持引号）
read_args() {
    ARGS=()
    read -r -a ARGS -p "$1" </dev/tty || ARGS=()
}

# mask_args <参数...>：显示用，把密码换成 ******
mask_args() {
    local out=() hide=0 a
    for a in "$@"; do
        if (( hide )); then out+=('******'); hide=0; continue; fi
        out+=("$a")
        [[ $a == -pwd || $a == -password || $a == --password ]] && hide=1
    done
    printf '%s' "${out[*]}"
}

has_arg() {
    local want=$1 a
    shift
    for a in "$@"; do [[ $a == "$want" ]] && return 0; done
    return 1
}

# ask_password <提示>：不回显，输入两次，结果放进 PASSWORD；直接回车得到空
ask_password() {
    local p1 p2 re='^[A-Za-z0-9_@%+=.,:-]{8,}$'
    while true; do
        read -r -s -p "$1: " p1 </dev/tty || p1=''
        printf '\n' >&2
        [[ -z $p1 ]] && { PASSWORD=''; return; }
        # InstallNET 把密码不加引号地传给 openssl，含空格、引号、$ 等字符会出错
        if [[ ! $p1 =~ $re ]]; then
            printf '  密码至少 8 位，只能包含字母、数字和 _@%%+=.,:-\n' >&2
            continue
        fi
        read -r -s -p "再输入一次: " p2 </dev/tty || p2=''
        printf '\n' >&2
        [[ $p1 == "$p2" ]] && { PASSWORD=$p1; return; }
        printf '  两次输入不一致。\n' >&2
    done
}

ask_port() {
    local p
    while true; do
        p=$(ask_value "$1" 22 '^[0-9]{1,5}$')
        (( p >= 1 && p <= 65535 )) && { printf '%s' "$p"; return; }
        printf '  端口范围是 1-65535。\n' >&2
    done
}

reboot_now() {
    info "系统将在 5 秒后重启（Ctrl-C 取消）..."
    sleep 5 && { systemctl reboot 2>/dev/null || reboot; }
}

do_tcpquality() {
    local path rc
    printf '\n%sTcpQuality：TCP 网络质量测试%s  %s第三方脚本 github.com/ibsgss/TcpQuality%s\n' "$BOLD" "$NC" "$DIM" "$NC"
    info "默认下载一个临时的 Debian 根文件系统，在里面测试，不往本机装软件，结束后自动删除。"
    info "常用参数：-v4（只测 IPv4）、--intl、--all、--no-rootfs（直接在本机运行）、--help（查看全部）。"
    read_args "附加参数（直接回车 = 默认）: "
    path=$(fetch_remote runTcpQuality.sh "$TCPQUALITY_URL") || { pause; return; }
    run_remote "$path" "${ARGS[@]}"
    rc=$?
    case $rc in
        0)   ok "TcpQuality 执行完毕" ;;
        130) warn "已中断（Ctrl-C）" ;;
        *)   warn "TcpQuality 退出码 $rc，请查看上面的输出" ;;
    esac
    pause
}

do_nodequality() {
    local path rc
    printf '\n%sNodeQuality：硬件 / IP / 网络质量综合测试%s  %s第三方脚本 github.com/LloydAsp/NodeQuality%s\n' "$BOLD" "$NC" "$DIM" "$NC"
    info "会依次询问要做哪些测试：硬件质量、IP 质量、网络质量、回程路由（直接回车 = 都做）。"
    info "做法：下载一个临时测试系统到 /root/.nodequality<时间>，挂载 /proc /sys /dev 后 chroot 进去测试，结束后卸载并删除。"
    warn "测试结果会上传到 nodequality.com 生成分享链接，内容包括本机 IP 和 IP 质量检测结果。"
    info "可选参数：-4（只测 IPv4）、-6（只测 IPv6）、-E（英文输出）。"
    ask_yn "继续吗？" y || return 0
    read_args "附加参数（直接回车 = 默认）: "
    if has_arg -d "${ARGS[@]}" || has_arg -D "${ARGS[@]}"; then
        warn "工作目录固定为 /root，不能再传 -d，请去掉后重试。"
        pause; return
    fi
    path=$(fetch_remote NodeQuality.sh "$NODEQUALITY_URL") || { pause; return; }
    # -d：工作目录放在 /root，而不是打开菜单时所在的目录
    run_remote "$path" -d /root "${ARGS[@]}"
    rc=$?
    # NodeQuality 的清理函数最后写死了 exit 1，成功也返回 1，不能按退出码判断
    info "NodeQuality 已结束（它无论成功与否都返回退出码 $rc）。结果链接在上面的输出里。"
    if compgen -G '/root/.nodequality*' >/dev/null; then
        warn "/root 下留有 .nodequality* 目录，说明清理没有完成。请先重启，再删除这个目录（不要在挂载未卸载时删除）。"
    fi
    pause
}

# 两个重装脚本共用的检查和确认
dd_precheck() {
    if (( IS_CONTAINER )); then
        warn "当前在容器里，容器没有自己的内核和引导，无法重装系统。"
        return 1
    fi
    warn "重装会清空整块系统盘（所有分区、所有数据），无法恢复！"
    info "  开始前请确认：数据已经备份；会用服务商的 VNC / 控制台（网络配置不对时只能从那里救）。"
    if command -v lsblk >/dev/null 2>&1; then
        info "  本机磁盘："
        lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | sed 's/^/    /'
    fi
}

# dd_confirm <要显示的命令>：要求输入主机名确认
dd_confirm() {
    local name reply
    name=$(hostname 2>/dev/null)
    name=${name:-yes}
    printf '\n将要执行：%s%s%s\n' "$BOLD" "$1" "$NC"
    read -r -p "确认重装请输入本机主机名（${name}）: " reply </dev/tty || reply=''
    if [[ $reply != "$name" ]]; then
        info "输入不一致，已取消，没有做任何修改。"
        return 1
    fi
}

do_installnet() {
    local path rc c port args=()
    printf '\n%sDD 重装系统：InstallNET.sh%s  %s第三方脚本 github.com/leitbogioro/Tools%s\n' "$BOLD" "$NC" "$DIM" "$NC"
    dd_precheck || { pause; return; }
    info "通过网络安装官方系统。脚本只写好 GRUB 启动项，需要手动重启才开始重装。"
    printf '\n  1) Debian 13\n  2) Debian 12\n  3) 自定义参数（如 -ubuntu 24.04、-dd <镜像网址>、-mirror <镜像源>）\n  0) 返回\n'
    c=$(ask_value "请选择" 1 '^[0-3]$')
    case $c in
        1) args=(-debian 13) ;;
        2) args=(-debian 12) ;;
        3) read_args "参数: "; args=("${ARGS[@]}"); (( ${#args[@]} )) || return 0 ;;
        *) return 0 ;;
    esac
    if [[ $c != 3 ]]; then
        info "不设置密码时，InstallNET 会用它内置的公开默认密码 $INSTALLNET_DEFAULT_PW。"
        ask_password "新系统的 root 密码（直接回车 = 用默认密码）"
        [[ -n $PASSWORD ]] && args+=(-pwd "$PASSWORD")
        port=$(ask_port "新系统的 SSH 端口")
        args+=(-port "$port")
    fi
    if has_arg -alpine "${args[@]}"; then
        warn "装 Alpine 时 InstallNET 一律使用默认密码 $INSTALLNET_DEFAULT_PW（-pwd 无效），装好后请立刻修改。"
    elif ! has_arg -pwd "${args[@]}" && ! has_arg -password "${args[@]}"; then
        warn "没有设置密码，新系统的 root 密码将是公开的默认密码 $INSTALLNET_DEFAULT_PW，装好后请立刻修改。"
    fi
    dd_confirm "bash InstallNET.sh $(mask_args "${args[@]}")" || { pause; return; }
    path=$(fetch_remote InstallNET.sh "$INSTALLNET_URL") || { pause; return; }
    run_remote "$path" "${args[@]}"
    rc=$?
    if (( rc == 130 )); then
        warn "已中断（Ctrl-C）。重启前请确认 GRUB 默认启动项没有被改动。"
        pause; return
    fi
    # 准备成功时 InstallNET 也是 exit 1，只能看它的输出
    info "InstallNET 成功和失败都返回退出码 1，请看上面最后几行："
    info "  · [Finish] Input 'reboot' to continue ...  表示准备好了，重启后开始重装"
    info "  · [Error] ...                               表示失败，按提示处理"
    if ask_yn "已经看到 [Finish]，现在重启开始重装吗？" n; then
        reboot_now
    else
        info "稍后执行 reboot 即可开始重装。"
    fi
    pause
}

do_reinstall() {
    local path rc c port args=()
    printf '\n%sDD 重装系统：reinstall.sh%s  %s第三方脚本 github.com/bin456789/reinstall%s\n' "$BOLD" "$NC" "$DIM" "$NC"
    dd_precheck || { pause; return; }
    info "支持 Debian、Ubuntu、Alpine、RHEL 系、Arch、Windows、dd 镜像等。脚本只做准备，重启后才开始重装，重启前可以取消。"
    printf '\n  1) Debian 13\n  2) Debian 12\n  3) Ubuntu 24.04\n  4) 自定义参数（如 alpine 3.22、dd --img=<镜像网址>、--help 查看全部）\n  0) 返回\n'
    c=$(ask_value "请选择" 1 '^[0-4]$')
    case $c in
        1) args=(debian 13) ;;
        2) args=(debian 12) ;;
        3) args=(ubuntu 24.04) ;;
        4) read_args "参数: "; args=("${ARGS[@]}"); (( ${#args[@]} )) || return 0 ;;
        *) return 0 ;;
    esac
    if [[ $c != 4 ]]; then
        port=$(ask_port "新系统的 SSH 端口")
        [[ $port != 22 ]] && args+=(--ssh-port "$port")
        info "用户名和密码由 reinstall.sh 自己询问（输入时会显示在屏幕上；密码留空则随机生成，结束时显示）。"
        info "想用密钥登录请选「自定义参数」，加上 --ssh-key <公钥>。"
    fi
    if ! has_arg -h "${args[@]}" && ! has_arg --help "${args[@]}"; then
        dd_confirm "bash reinstall.sh $(mask_args "${args[@]}")" || { pause; return; }
    fi
    path=$(fetch_remote reinstall.sh "$REINSTALL_URL" "$REINSTALL_URL_CN") || { pause; return; }
    run_remote "$path" "${args[@]}"
    rc=$?
    case $rc in
        0)
            has_arg -h "${args[@]}" || has_arg --help "${args[@]}" || {
                printf '  1) 现在重启，开始重装\n  2) 取消这次重装（执行 reinstall.sh reset）\n  0) 稍后自己执行 reboot\n'
                case $(ask_value "请选择" 0 '^[0-2]$') in
                    1) reboot_now ;;
                    2) run_remote "$path" reset && ok "已取消，重启后仍是原系统" ;;
                    *) info "稍后执行 reboot 即可开始重装。想取消时运行：curl -fsSL $REINSTALL_URL -o reinstall.sh && bash reinstall.sh reset" ;;
                esac
            } ;;
        130) warn "已中断（Ctrl-C）" ;;
        *)   warn "reinstall.sh 退出码 $rc，没有准备好重装，请查看上面的输出" ;;
    esac
    pause
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
            7) run_script "$CVE_98432_SH" || pause ;;
            8) do_singbox ;;
            9) do_apt_install "q" "$Q_SH" "$(status_q)" ;;
            10) do_go ;;
            11) run_script "$DOCKER_SH" || pause ;;
            12) do_motd ;;
            13) do_tcpquality ;;
            14) do_nodequality ;;
            15) do_installnet ;;
            16) do_reinstall ;;
            0|q|Q) info "再见。"; exit 0 ;;
            '') ;;
            *) warn "无效编号：$choice"; sleep 1 ;;
        esac
    done
}

main "$@"
