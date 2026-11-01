#!/usr/bin/env bash
#
# =============================================================================
#  Linux-tools 整合版：所有子脚本都已内置在本文件里，单独下载这一个文件即可使用。
#  本文件由 build.sh 自动生成，请不要直接修改。
#  要改功能，请修改 menu.sh 或对应的子脚本，然后重新运行 bash build.sh。
# =============================================================================
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
# ---- 以下为内置子脚本（共 16 个） ----
payload_Debian_clear_sh() {
cat <<'__LT_PAYLOAD_END__'
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
__LT_PAYLOAD_END__
}

payload_Debian_cve_2026_98432_sh() {
cat <<'__LT_PAYLOAD_END__'
#!/usr/bin/env bash
#
# CVE-2026-98432 检测与修复（Debian 12 / 13，也能判断 XanMod 等上游版本号的内核）
#
# 漏洞：Linux 内核 IPv4 TCP 握手时的 use-after-free（ipv4: free inet_opt and ireq_opt after
# an RCU grace period），CVSS 9.8。远程未认证的对端在 SYN 里带上 IP 选项（Record Route /
# Timestamp）就能触发，可能泄露内核内存、写坏内核内存或让内核崩溃。
# 影响 4.4 以来的内核，IPv6 不受第一种情况影响。
#
# 用法：
#   sudo bash cve-2026-98432.sh           交互式菜单
#   sudo bash cve-2026-98432.sh --check   只检测。返回码：0 不受影响  1 受影响
#                                          2 已装好修复版内核、等待重启  3 无法判断
#   sudo bash cve-2026-98432.sh --fix     不提问，升级内核（不会自动重启）
#
# 修复：升级到修复版内核并重启。
# 不能马上重启时可以先用临时缓解：在 prerouting 丢弃带 IP 选项的 IPv4 TCP 包，
# 漏洞所需的选项就进不到 TCP 握手里。正常流量几乎不带 IP 选项，一般不影响业务。
#
# 修复版本来源：
#   https://www.cve.org/CVERecord?id=CVE-2026-98432
#   https://security-tracker.debian.org/tracker/CVE-2026-98432（DSA-6568-1、DLA-4841-1、DLA-4850-1）

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

CVE="CVE-2026-98432"
NFT_TABLE="lt_cve_2026_98432"
NFT_FILE="/etc/linux-tools/cve-2026-98432.nft"
UNIT_NAME="lt-cve-2026-98432.service"
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"
SYSCTL_FILE="/etc/sysctl.d/99-linux-tools-cve-2026-98432.conf"

# 上游各稳定分支的修复版本（补丁号）；7.3 起主线已包含修复。表里没有的分支（已停止维护）不会再修
declare -A UPSTREAM_FIX=([5.10]=272 [5.15]=223 [6.1]=190 [6.6]=159 [6.12]=113 [6.18]=56 [7.2]=10)

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法: sudo bash ${0##*/} [选项]

  （不带参数）   打开交互式菜单
  --check        只检测。返回码 0 不受影响，1 受影响，2 等待重启，3 无法判断
  --fix          不提问，升级内核（不会自动重启）
  -h, --help     显示本帮助
EOF
}

# -----------------------------------------------------------------------------
# 交互：一律从 /dev/tty 读；--fix 模式不提问，取默认值
# -----------------------------------------------------------------------------
ASSUME_YES=0
HAVE_TTY=0
{ : </dev/tty; } 2>/dev/null && HAVE_TTY=1

ask_yn() {
    local prompt=$1 def=$2 hint='[y/N]' reply=''
    [[ $def == y ]] && hint='[Y/n]'
    if (( ASSUME_YES )); then
        [[ $def == y ]]
        return
    fi
    read -r -p "$prompt $hint " reply </dev/tty 2>/dev/null || reply=''
    reply=${reply:-$def}
    [[ $reply =~ ^[Yy] ]]
}

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

pause() { read -r -p "按回车继续..." _ </dev/tty || true; }

# 新装的 VPS 上 unattended-upgrades 经常持有 dpkg 锁，最多等 120 秒
apt_get() { apt-get -o DPkg::Lock::Timeout=120 "$@"; }

# -----------------------------------------------------------------------------
# 版本判断
# -----------------------------------------------------------------------------
# upstream_status <上游版本，如 6.12.50>：fixed / affected / nofix / unaffected / unknown
upstream_status() {
    local maj min pat fix
    [[ $1 =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))? ]] || { echo unknown; return; }
    maj=$((10#${BASH_REMATCH[1]})); min=$((10#${BASH_REMATCH[2]})); pat=$((10#${BASH_REMATCH[4]:-0}))
    if (( maj < 4 || (maj == 4 && min < 4) )); then echo unaffected; return; fi
    if (( maj > 7 || (maj == 7 && min >= 3) )); then echo fixed; return; fi
    fix=${UPSTREAM_FIX[$maj.$min]:-}
    [[ -n $fix ]] || { echo nofix; return; }
    if (( pat >= fix )); then echo fixed; else echo affected; fi
}

# debian_status <Debian 内核包版本，如 6.1.176-1>：按 Debian 安全公告的修复版本判断
debian_status() {
    local v=$1 fix=''
    case $v in
        6.1.*)         fix=6.1.190-1 ;;
        6.12.*~deb12*) fix=6.12.113-1~deb12u1 ;;   # bookworm 里的 linux-6.12
        6.12.*~bpo*)   ;;                         # backports 没有单独公告，按上游版本判断
        6.12.*)        fix=6.12.113-1 ;;
        7.2.*)         fix=7.2.10-1 ;;
    esac
    if [[ -n $fix ]]; then
        if dpkg --compare-versions "$v" ge "$fix"; then echo fixed; else echo affected; fi
        return
    fi
    upstream_status "$v"
}

# pkg_status <包名> <版本>：已安装的内核包
pkg_status() {
    local name=$1 ver=$2
    if [[ $name != *xanmod* && $ver =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9] ]]; then
        debian_status "$ver"
    else
        # XanMod、自编译内核：包名里带的就是上游版本号
        upstream_status "${name#linux-image-}"
    fi
}

status_text() {
    case $1 in
        fixed)      printf '%s已修复%s' "$GREEN" "$NC" ;;
        unaffected) printf '%s不受影响%s' "$GREEN" "$NC" ;;
        affected)   printf '%s受影响%s' "$RED" "$NC" ;;
        nofix)      printf '%s受影响（该分支已停止维护，不会再修，需要换到有修复的分支）%s' "$RED" "$NC" ;;
        *)          printf '%s无法判断%s' "$YELLOW" "$NC" ;;
    esac
}

# -----------------------------------------------------------------------------
# 环境信息
# -----------------------------------------------------------------------------
detect_env() {
    OS_ID=''; OS_CODENAME=''
    if [[ -r /etc/os-release ]]; then
        IFS='|' read -r OS_ID OS_CODENAME < <(
            # shellcheck disable=SC1091
            . /etc/os-release
            printf '%s|%s\n' "${ID:-}" "${VERSION_CODENAME:-}"
        )
    fi
    CONTAINER=$(systemd-detect-virt --container 2>/dev/null) || CONTAINER=''
    [[ -z $CONTAINER && -f /proc/user_beancounters ]] && CONTAINER=openvz
    KREL=$(uname -r)
}

# 正在运行的内核：RUN_VER 是用来判断的版本号，RUN_STATUS 是结论
eval_running() {
    RUN_VER=''
    RUN_STATUS=unknown
    if [[ $OS_ID == ubuntu ]]; then
        return      # Ubuntu 会把补丁移植到旧版本号上，不能按上游版本判断
    fi
    if [[ $(uname -v) =~ Debian\ ([0-9][^[:space:]]*) ]]; then
        RUN_VER=${BASH_REMATCH[1]}
        RUN_STATUS=$(debian_status "$RUN_VER")
    elif [[ $KREL =~ ^[0-9]+\.[0-9]+\.0-[0-9]+- ]]; then
        return      # Debian 风格的 ABI 名（6.1.0-41-amd64）看不出真实版本
    else
        RUN_VER=$KREL
        RUN_STATUS=$(upstream_status "$RUN_VER")
    fi
}

# 已安装的内核包：KPKGS 里每项是 "包名<TAB>版本<TAB>结论"；FIXED_INSTALLED=1 表示装了修复版
eval_installed() {
    local name ver
    KPKGS=()
    FIXED_INSTALLED=0
    while IFS=$'\t' read -r name ver; do
        [[ -n $name ]] || continue
        local st
        st=$(pkg_status "$name" "$ver")
        KPKGS+=("$name"$'\t'"$ver"$'\t'"$st")
        [[ $st == fixed ]] && FIXED_INSTALLED=1
    done < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 'linux-image-[0-9]*' 2>/dev/null |
             awk -F'\t' '$1 ~ /^ii/ && $2 !~ /-dbg$/ { print $2 "\t" $3 }')
}

mitigation_loaded() { command -v nft >/dev/null 2>&1 && nft list table ip "$NFT_TABLE" >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
# 检测
# -----------------------------------------------------------------------------
# show_check：打印检测结果，并按 --check 的约定返回 0/1/2/3
show_check() {
    local row name ver st mark migrate dropped
    eval_running
    eval_installed

    info "=============================================================="
    info " ${BOLD}$CVE 检测${NC}（Linux 内核 IPv4 TCP 握手 use-after-free，CVSS 9.8）"
    info "=============================================================="
    info " 运行内核 : $KREL${RUN_VER:+（版本 $RUN_VER）}"
    info " 结论     : $(status_text "$RUN_STATUS")"
    [[ -n $CONTAINER ]] && info " 环境     : 容器（$CONTAINER）。容器共用宿主机内核，上面是宿主机内核的结果，修复要在宿主机上做"

    if (( ${#KPKGS[@]} )); then
        info ""
        info " 已安装的内核："
        for row in "${KPKGS[@]}"; do
            IFS=$'\t' read -r name ver st <<<"$row"
            mark='  '
            [[ $name == "linux-image-$KREL" || $name == "linux-image-$KREL-unsigned" ]] && mark='* '
            printf '   %s%-40s %-22s %s\n' "$mark" "$name" "$ver" "$(status_text "$st")"
        done
        info "   ${DIM}* = 正在运行${NC}"
    fi

    info ""
    if mitigation_loaded; then
        dropped=$(nft list table ip "$NFT_TABLE" 2>/dev/null | grep -o 'packets [0-9]*' | head -n 1)
        info " 临时缓解 : ${GREEN}已生效${NC}（已拦截 ${dropped#packets } 个带 IP 选项的 TCP 包）"
    elif [[ -f $NFT_FILE ]]; then
        info " 临时缓解 : ${YELLOW}已配置但当前没有生效${NC}（可能被 nftables 重载清掉了，菜单 3 可重新应用）"
    else
        info " 临时缓解 : 未应用"
    fi
    migrate=$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || true)
    if [[ $migrate == 1 ]]; then
        info " tcp_migrate_req : ${RED}1${NC}（开启了请求迁移，会多一条触发路径，建议改成 0）"
    elif [[ -n $migrate ]]; then
        info " tcp_migrate_req : 0"
    fi
    info "=============================================================="

    case $RUN_STATUS in
        fixed|unaffected)
            info "当前运行的内核不受 $CVE 影响。"
            return 0 ;;
        affected|nofix)
            if (( FIXED_INSTALLED )); then
                warn "已经装好修复版内核，但还没重启，现在运行的仍是有漏洞的内核。重启后生效。"
                return 2
            fi
            warn "当前内核受 $CVE 影响，请升级内核（菜单 2）并重启；暂时不能重启可以先用临时缓解（菜单 3）。"
            return 1 ;;
        *)
            if [[ $OS_ID == ubuntu ]]; then
                warn "Ubuntu 会把补丁移植到旧版本号上，无法按版本号判断。请查看 https://ubuntu.com/security/$CVE ，或执行 pro fix $CVE。"
            else
                warn "无法从内核版本号判断（uname -v：$(uname -v)）。"
            fi
            return 3 ;;
    esac
}

# -----------------------------------------------------------------------------
# 升级内核
# -----------------------------------------------------------------------------
# 已安装的内核元包（linux-image-amd64、linux-image-cloud-amd64、linux-xanmod-lts-x64v3 等）
kernel_metas() {
    dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-*' 'linux-xanmod*' 2>/dev/null |
        awk -F'\t' '$1 ~ /^ii/ && $2 !~ /^linux-image-[0-9]/ && $2 !~ /-dbg$/ { print $2 }'
}

has_security_source() {
    grep -rqsE 'security\.debian\.org|debian-security' /etc/apt/sources.list /etc/apt/sources.list.d/
}

fix_kernel() {
    local metas=() m meta arch
    if [[ -n $CONTAINER ]]; then
        warn "当前在容器（$CONTAINER）里，容器用的是宿主机内核，请在宿主机上升级内核。"
        return 1
    fi
    if [[ $OS_ID == ubuntu ]]; then
        info "Ubuntu 请执行：apt update && apt full-upgrade，然后重启。"
        return 1
    fi

    while read -r m; do [[ -n $m ]] && metas+=("$m"); done < <(kernel_metas)

    info "更新软件包列表..."
    apt_get update -qq || { warn "apt update 失败，请检查网络和软件源"; return 1; }

    if (( ${#metas[@]} )); then
        info "升级内核元包：${metas[*]}"
        apt_get install -y --only-upgrade "${metas[@]}" || { warn "升级内核失败"; return 1; }
    else
        arch=$(dpkg --print-architecture)
        meta="linux-image-$arch"
        [[ $KREL == *-cloud-* ]] && meta="linux-image-cloud-$arch"
        warn "没有安装内核元包，内核不会随 apt upgrade 自动更新。"
        ask_yn "安装 $meta（以后内核会跟着系统更新）吗？" y || return 1
        apt_get install -y "$meta" || { warn "安装 $meta 失败"; return 1; }
    fi

    eval_running
    eval_installed
    if [[ $RUN_STATUS == fixed || $RUN_STATUS == unaffected ]]; then
        ok "当前运行的内核已经不受影响。"
        return 0
    fi
    if (( FIXED_INSTALLED )); then
        ok "修复版内核已安装，重启后生效。"
        if ask_yn "现在重启吗？" n; then
            info "系统将在 5 秒后重启..."
            sleep 5
            systemctl reboot
        fi
        return 0
    fi

    warn "软件源里还没有修复版内核。"
    if [[ $OS_ID == debian ]] && ! has_security_source; then
        warn "没有配置 Debian 安全更新源，修复版内核只在安全源里。在 /etc/apt/sources.list 里加上这一行后重试："
        info "  deb http://security.debian.org/debian-security ${OS_CODENAME:-<代号>}-security main"
    fi
    if [[ $KREL == *xanmod* ]]; then
        info "XanMod：请换到 LTS 分支，或等 XanMod 发布修复版（需要上游 6.12.113 / 6.18.56 / 7.2.10 及以上）。"
    fi
    info "在此之前可以先用临时缓解（菜单 3）。"
    return 1
}

# -----------------------------------------------------------------------------
# 临时缓解
# -----------------------------------------------------------------------------
apply_mitigation() {
    local nft migrate
    if ! command -v nft >/dev/null 2>&1; then
        ask_yn "临时缓解需要 nftables，现在安装吗？" y || return 1
        { apt_get update -qq && apt_get install -y nftables; } || { warn "安装 nftables 失败"; return 1; }
    fi
    nft=$(command -v nft)

    install -d -m 755 "$(dirname "$NFT_FILE")"
    # 先建空表再删掉，保证重复加载时不会叠加规则
    cat > "$NFT_FILE" <<EOF
# 由 Linux-tools cve-2026-98432.sh 生成：$CVE 临时缓解
# 丢弃带 IP 选项（IP 头长度不是 20 字节）的 IPv4 TCP 包。在 prerouting 最早阶段执行，
# 早于内核解析 IP 选项。升级到修复版内核并重启后，可以在菜单里移除。
table ip $NFT_TABLE
delete table ip $NFT_TABLE
table ip $NFT_TABLE {
    chain prerouting {
        type filter hook prerouting priority -300; policy accept;
        ip protocol tcp ip hdrlength != 5 counter drop comment "$CVE"
    }
}
EOF
    if ! "$nft" -f "$NFT_FILE"; then
        warn "加载 nftables 规则失败（容器里通常没有权限）。"
        return 1
    fi

    # 开机自动加载；排在 nftables.service 之后，免得被它的 flush ruleset 清掉
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Linux-tools: $CVE mitigation (drop IPv4 TCP packets carrying IP options)
After=nftables.service firewalld.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nft -f $NFT_FILE
ExecStop=-$nft delete table ip $NFT_TABLE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$UNIT_NAME" >/dev/null 2>&1
    ok "临时缓解已生效，开机会自动加载（$UNIT_NAME）。"
    info "  注意：执行 systemctl reload nftables 或 nft flush ruleset 会把它清掉，之后用菜单 3 重新应用即可。"

    migrate=$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || true)
    if [[ $migrate == 1 ]] && ask_yn "net.ipv4.tcp_migrate_req 是 1，会多一条触发路径。改成 0 吗？" y; then
        sysctl -q -w net.ipv4.tcp_migrate_req=0 &&
            printf '# 由 Linux-tools cve-2026-98432.sh 生成\nnet.ipv4.tcp_migrate_req = 0\n' > "$SYSCTL_FILE" &&
            ok "已设为 0，并保存到 $SYSCTL_FILE"
    fi
    info "  临时缓解只是挡住远程触发的条件，彻底修复仍需升级内核并重启。"
}

remove_mitigation() {
    if [[ ! -f $UNIT_FILE && ! -f $NFT_FILE ]] && ! mitigation_loaded; then
        info "没有应用过临时缓解。"
        return 0
    fi
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1
    command -v nft >/dev/null 2>&1 && nft delete table ip "$NFT_TABLE" 2>/dev/null
    rm -f -- "$UNIT_FILE" "$NFT_FILE"
    rmdir --ignore-fail-on-non-empty "$(dirname "$NFT_FILE")" 2>/dev/null
    systemctl daemon-reload
    if [[ -f $SYSCTL_FILE ]] && ask_yn "同时删除 $SYSCTL_FILE（tcp_migrate_req=0 的设置）吗？" n; then
        rm -f -- "$SYSCTL_FILE"
    fi
    ok "已移除临时缓解。"
}

# -----------------------------------------------------------------------------
# 菜单
# -----------------------------------------------------------------------------
menu() {
    while true; do
        printf '\n'
        show_check
        printf '\n'
        printf '  %s1)%s 重新检测\n' "$CYAN" "$NC"
        printf '  %s2)%s 升级内核修复（需要重启）\n' "$CYAN" "$NC"
        printf '  %s3)%s 临时缓解：丢弃带 IP 选项的 IPv4 TCP 包（不用重启）\n' "$CYAN" "$NC"
        printf '  %s4)%s 移除临时缓解\n' "$CYAN" "$NC"
        printf '  %s0)%s 退出\n' "$CYAN" "$NC"
        case $(ask_value "请选择" 0 '^[0-4]$') in
            1) ;;
            2) fix_kernel; pause ;;
            3) apply_mitigation; pause ;;
            4) ask_yn "移除临时缓解吗？（内核还没修复时不建议）" n && remove_mitigation; pause ;;
            *) return 0 ;;
        esac
    done
}

main() {
    local action=''
    case ${1:-} in
        --check) action=check ;;
        --fix)   action=fix ;;
        -h|--help) usage; exit 0 ;;
        '') ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
    detect_env
    command -v dpkg >/dev/null 2>&1 || die "本脚本只支持 Debian / Ubuntu。"

    case $action in
        check)
            show_check
            exit $? ;;
        fix)
            [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
            ASSUME_YES=1
            fix_kernel
            exit $? ;;
        '')
            [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
            (( HAVE_TTY )) || die "需要交互式终端。非交互使用请加 --check 或 --fix。"
            menu ;;
    esac
}

main "$@"
__LT_PAYLOAD_END__
}

payload_Debian_docker_sh() {
cat <<'__LT_PAYLOAD_END__'
#!/usr/bin/env bash
#
# Docker + Docker Compose 一键安装（Debian 12 / 13，也支持 Ubuntu）
#
# 用法：
#   sudo bash docker.sh                                  交互式菜单
#   sudo bash docker.sh --install                        按默认选项直接安装 / 升级（官方源）
#   sudo DOCKER_MIRROR=aliyun bash docker.sh --install   用阿里云镜像安装（也可以是 tuna）
#   sudo bash docker.sh --uninstall                      卸载
#
# 做法与 Docker 官方文档一致：添加 Docker 的 apt 源，安装
#   docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# Docker Compose 是 v2 插件，命令是 docker compose（中间是空格）。
# 可以顺带装一个 docker-compose 兼容命令，转调 docker compose，方便还在用旧命令的脚本。
#
# 与 get.docker.com 一键脚本的不同：
#   * 安装前列出与 Docker 冲突的系统包（docker.io、podman-docker 等），确认后才卸载
#   * 先确认 Docker 软件源里有当前系统代号；没有时（比如很新的 Debian）询问是否改用 bookworm 的包
#   * 可选国内镜像源（阿里云、清华）
#   * 可选配置容器日志轮转：默认的 json-file 日志不限大小，跑久了会把磁盘写满
#   * 把用户加入 docker 组之前提醒：docker 组等同于 root 权限

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

KEYRING="/etc/apt/keyrings/docker.asc"
SOURCE_LIST="/etc/apt/sources.list.d/docker.list"
DAEMON_JSON="/etc/docker/daemon.json"
COMPOSE_SHIM="/usr/local/bin/docker-compose"
SHIM_MARK="由 Linux-tools docker.sh 生成"
PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
EXTRA_PACKAGES=(docker-ce-rootless-extras)
# Docker 官方文档要求先卸载的发行版自带包
CONFLICTS=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)

MIRROR=${DOCKER_MIRROR:-official}
ASSUME_YES=0

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'
else
    BOLD=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法: sudo bash ${0##*/} [选项]

  （不带参数）   打开交互式菜单
  --install      按默认选项直接安装 / 升级 Docker 和 Docker Compose
  --uninstall    卸载
  -h, --help     显示本帮助

环境变量 DOCKER_MIRROR：official（默认）、aliyun、tuna
EOF
}

# -----------------------------------------------------------------------------
# 交互：一律从 /dev/tty 读；--install 模式不提问，直接取默认值
# -----------------------------------------------------------------------------
HAVE_TTY=0
{ : </dev/tty; } 2>/dev/null && HAVE_TTY=1

# ask_yn <提示> <默认 y|n>
ask_yn() {
    local prompt=$1 def=$2 hint='[y/N]' reply=''
    [[ $def == y ]] && hint='[Y/n]'
    if (( ASSUME_YES )); then
        [[ $def == y ]]
        return
    fi
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

pause() { read -r -p "按回车继续..." _ </dev/tty || true; }

# -----------------------------------------------------------------------------
# 工具函数
# -----------------------------------------------------------------------------
# 新装的 VPS 上 unattended-upgrades 经常持有 dpkg 锁，最多等 120 秒
apt_get() { apt-get -o DPkg::Lock::Timeout=120 "$@"; }

pkg_installed() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'; }

mirror_base() {
    case $1 in
        aliyun) echo "https://mirrors.aliyun.com/docker-ce/linux" ;;
        tuna)   echo "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux" ;;
        *)      echo "https://download.docker.com/linux" ;;
    esac
}

mirror_name() {
    case $1 in
        aliyun) echo "阿里云镜像" ;;
        tuna)   echo "清华大学镜像" ;;
        *)      echo "Docker 官方源" ;;
    esac
}

docker_version()  { docker --version 2>/dev/null | awk '{ gsub(",", "", $3); print $3 }'; }
compose_version() { docker compose version --short 2>/dev/null; }

detect_os() {
    [[ -r /etc/os-release ]] || die "找不到 /etc/os-release，无法识别系统"
    IFS='|' read -r OS_ID OS_CODENAME OS_NAME < <(
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s|%s|%s\n' "${ID:-}" "${VERSION_CODENAME:-}" "${PRETTY_NAME:-未知系统}"
    )
    case $OS_ID in
        debian|ubuntu) ;;
        *) die "本脚本只支持 Debian / Ubuntu，当前系统是 $OS_NAME" ;;
    esac
    [[ -n $OS_CODENAME ]] || die "无法识别系统代号（/etc/os-release 里没有 VERSION_CODENAME）"
}

# -----------------------------------------------------------------------------
# 安装
# -----------------------------------------------------------------------------
install_docker() {
    local arch ctr codename base tmp p f u
    local conflicts=() missing=() others=()

    arch=$(dpkg --print-architecture)
    case $arch in
        amd64|arm64|armhf|ppc64el|s390x) ;;
        *) warn "Docker 软件源不提供 $arch 架构的包。"; return 1 ;;
    esac

    ctr=$(systemd-detect-virt --container 2>/dev/null) || ctr=''
    [[ -z $ctr && -f /proc/user_beancounters ]] && ctr=openvz
    if [[ -n $ctr ]]; then
        warn "当前在容器（$ctr）里。LXC 需要在宿主机上开启 nesting 才能运行 Docker，OpenVZ 通常无法运行。"
        ask_yn "仍要继续吗？" n || return 1
    fi

    # ---- 冲突的软件包 -------------------------------------------------------
    for p in "${CONFLICTS[@]}"; do
        pkg_installed "$p" && conflicts+=("$p")
    done
    if (( ${#conflicts[@]} )); then
        warn "以下软件包与 Docker 官方版冲突，需要先卸载：${conflicts[*]}"
        info "  /var/lib/docker 里的镜像、容器和数据卷会保留，但用旧版跑着的容器会停止。"
        ask_yn "卸载这些软件包并继续吗？" n || { info "已取消，没有做任何修改。"; return 1; }
        apt_get remove -y "${conflicts[@]}" || { warn "卸载冲突的软件包失败"; return 1; }
    fi

    # ---- 依赖 ---------------------------------------------------------------
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v gpg  >/dev/null 2>&1 || missing+=(gpg)
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
    if (( ${#missing[@]} )); then
        info "安装依赖：${missing[*]} ..."
        { apt_get update -qq && apt_get install -y -qq "${missing[@]}"; } || { warn "依赖安装失败"; return 1; }
    fi

    # ---- 软件源 -------------------------------------------------------------
    base="$(mirror_base "$MIRROR")/$OS_ID"
    codename=$OS_CODENAME
    info "使用 $(mirror_name "$MIRROR")：$base"
    if ! curl -fsI --max-time 15 "$base/dists/$codename/Release" >/dev/null 2>&1; then
        warn "Docker 软件源里没有 $codename（也可能是网络不通）。"
        if [[ $OS_ID == debian && $codename != bookworm ]] &&
           ask_yn "改用 bookworm（Debian 12）的软件包吗？一般可以正常使用" n; then
            codename=bookworm
        else
            return 1
        fi
    fi

    install -d -m 755 /etc/apt/keyrings
    tmp=$(mktemp) || return 1
    if ! curl -fsSL --max-time 30 "$base/gpg" -o "$tmp" || ! gpg --show-keys "$tmp" >/dev/null 2>&1; then
        rm -f -- "$tmp"
        warn "下载或校验签名密钥失败：$base/gpg"
        return 1
    fi
    install -m 644 "$tmp" "$KEYRING"
    rm -f -- "$tmp"

    # 以前按别的教程加过的 Docker 源（signed-by 不同）会让 apt update 报冲突，先停用
    while IFS= read -r f; do others+=("$f"); done < <(
        grep -lsE 'docker-ce|download\.docker\.com' /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null |
        grep -vxF "$SOURCE_LIST")
    if (( ${#others[@]} )); then
        for f in "${others[@]}"; do
            mv -f -- "$f" "$f.linux-tools.bak"
            info "已停用以前的 Docker 软件源：$f（改名为 $f.linux-tools.bak）"
        done
    fi

    printf 'deb [arch=%s signed-by=%s] %s %s stable\n' "$arch" "$KEYRING" "$base" "$codename" > "$SOURCE_LIST"
    chmod 644 "$SOURCE_LIST"

    # ---- 安装 ---------------------------------------------------------------
    info "安装 Docker 和 Docker Compose（已安装时会升级到最新版）..."
    apt_get update -qq || { warn "apt update 失败，请检查网络和 $SOURCE_LIST"; return 1; }
    apt_get install -y "${PACKAGES[@]}" || { warn "Docker 安装失败"; return 1; }
    hash -r

    systemctl enable --now containerd docker >/dev/null 2>&1
    if ! systemctl is-active --quiet docker; then
        warn "docker 服务没有启动，最近的日志："
        journalctl -u docker -n 20 --no-pager >&2
        return 1
    fi

    # ---- 可选设置 -----------------------------------------------------------
    if [[ ! -s $DAEMON_JSON ]]; then
        if ask_yn "配置容器日志轮转（每个容器最多保留 3 个 10M 的日志文件）吗？" y; then
            install -d -m 755 /etc/docker
            cat > "$DAEMON_JSON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
            systemctl restart docker && ok "已写入 $DAEMON_JSON（只对之后新建的容器生效）"
        fi
    else
        info "已存在 $DAEMON_JSON，没有修改。"
    fi

    if ! command -v docker-compose >/dev/null 2>&1 &&
       ask_yn "安装 docker-compose 兼容命令（转调 docker compose，方便旧脚本）吗？" y; then
        printf '#!/bin/sh\n# %s：兼容旧的 docker-compose 命令\nexec docker compose "$@"\n' "$SHIM_MARK" > "$COMPOSE_SHIM"
        chmod 755 "$COMPOSE_SHIM"
        ok "已安装 $COMPOSE_SHIM"
    fi

    u=${SUDO_USER:-}
    if [[ -n $u && $u != root ]] && ! id -nG "$u" 2>/dev/null | grep -qw docker; then
        warn "docker 组的成员不用输密码就能控制 Docker，相当于拥有 root 权限。"
        if ask_yn "把用户 $u 加入 docker 组（以后不用 sudo 就能运行 docker）吗？" n; then
            usermod -aG docker "$u" && ok "已把 $u 加入 docker 组，重新登录后生效"
        fi
    fi

    printf '\n'
    ok "Docker $(docker_version)，Docker Compose $(compose_version)"
    info "注意：docker run -p 发布的端口会绕过 ufw 直接对外开放。只想本机访问时写成 -p 127.0.0.1:8080:80。"
}

# -----------------------------------------------------------------------------
# 卸载
# -----------------------------------------------------------------------------
uninstall_docker() {
    local p running installed=()
    ask_yn "卸载 Docker 和 Docker Compose 吗？" n || return 0

    running=$(docker ps -q 2>/dev/null | wc -l)
    if (( running )); then
        warn "当前有 $running 个容器在运行，卸载会把它们停掉。"
        ask_yn "仍要继续吗？" n || return 0
    fi

    systemctl disable --now docker.socket docker.service containerd >/dev/null 2>&1
    for p in "${PACKAGES[@]}" "${EXTRA_PACKAGES[@]}"; do
        pkg_installed "$p" && installed+=("$p")
    done
    if (( ${#installed[@]} )); then
        apt_get purge -y "${installed[@]}" || warn "卸载软件包失败"
    fi
    if [[ -f $COMPOSE_SHIM ]] && grep -qF "$SHIM_MARK" "$COMPOSE_SHIM"; then
        rm -f -- "$COMPOSE_SHIM"
    fi

    warn "下一步会永久删除所有镜像、容器和数据卷（/var/lib/docker、/var/lib/containerd），无法恢复。"
    if ask_yn "删除 Docker 的数据吗？" n; then
        rm -rf -- /var/lib/docker /var/lib/containerd
        ok "已删除 Docker 数据"
    else
        info "数据保留在 /var/lib/docker，重新安装后还能用。"
    fi
    if ask_yn "删除 Docker 的配置（/etc/docker）和 apt 软件源吗？" y; then
        rm -rf -- /etc/docker
        rm -f -- "$SOURCE_LIST" "$KEYRING"
    fi
    ok "卸载完成"
}

# -----------------------------------------------------------------------------
# 菜单
# -----------------------------------------------------------------------------
show_status() {
    local st src='未配置'
    info "=============================================================="
    info " ${BOLD}Docker + Docker Compose${NC}"
    info "=============================================================="
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker 2>/dev/null; then st="${GREEN}运行中${NC}"; else st="${YELLOW}未运行${NC}"; fi
        info " Docker   : $(docker_version) · $st"
        st=$(compose_version)
        info " Compose  : ${st:-未安装}"
    else
        info " Docker   : 未安装"
    fi
    [[ -f $SOURCE_LIST ]] && src=$(awk '{ print $(NF - 2) }' "$SOURCE_LIST" | head -n 1)
    info " 软件源   : $src"
    info "=============================================================="
}

interactive_install() {
    local c
    printf '\n%s选择软件源%s\n' "$BOLD" "$NC"
    printf '  1) Docker 官方源（download.docker.com）\n'
    printf '  2) 阿里云镜像（国内服务器推荐）\n'
    printf '  3) 清华大学镜像\n'
    printf '  0) 返回\n'
    c=$(ask_value "请选择" 1 '^[0-3]$')
    case $c in
        1) MIRROR=official ;;
        2) MIRROR=aliyun ;;
        3) MIRROR=tuna ;;
        *) return 0 ;;
    esac
    install_docker
}

menu() {
    while true; do
        printf '\n'
        show_status
        printf '  %s1)%s 安装 / 升级 Docker 和 Docker Compose\n' "$CYAN" "$NC"
        printf '  %s2)%s 卸载\n' "$CYAN" "$NC"
        printf '  %s0)%s 退出\n' "$CYAN" "$NC"
        case $(ask_value "请选择" 0 '^[0-2]$') in
            1) interactive_install; pause ;;
            2) uninstall_docker; pause ;;
            *) return 0 ;;
        esac
    done
}

main() {
    local action=''
    case ${1:-} in
        --install)   action=install ;;
        --uninstall) action=uninstall ;;
        -h|--help)   usage; exit 0 ;;
        '') ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
    detect_os

    case $action in
        install)
            ASSUME_YES=1
            install_docker ;;
        uninstall)
            (( HAVE_TTY )) || die "卸载需要交互式终端确认。"
            uninstall_docker ;;
        '')
            (( HAVE_TTY )) || die "需要交互式终端。非交互安装请加 --install。"
            menu ;;
    esac
}

main "$@"
__LT_PAYLOAD_END__
}

payload_Debian_golong_sh() {
cat <<'__LT_PAYLOAD_END__'
#!/bin/bash
#
# Go 语言安装 / 升级脚本（Debian / Ubuntu）
#
# 用法：
#   sudo bash golong.sh              # 安装官方最新稳定版
#   sudo GO_VERSION=1.23.4 bash golong.sh   # 安装指定版本
#
# 安装到 /usr/local/go，PATH 写入 /etc/profile.d/go.sh（对所有用户生效）。
# GOPATH 使用 Go 默认值 $HOME/go，无需额外配置。

set -euo pipefail

INSTALL_DIR="/usr/local"
PROFILE_SNIPPET="/etc/profile.d/go.sh"
GO_VERSION="${GO_VERSION:-}"

die() { echo "错误：$*" >&2; exit 1; }

# 从终端读取输入，兼容 curl ... | bash 的用法
ask() {
  local prompt=$1 reply=''
  if [ -r /dev/tty ]; then
    read -r -p "$prompt" reply </dev/tty || true
  fi
  [[ $reply =~ ^[Yy]$ ]]
}

[ "$(id -u)" -eq 0 ] || die "请使用 sudo 或 root 权限运行此脚本"

for cmd in curl tar sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
done

# 架构检测
case "$(uname -m)" in
  x86_64)        ARCH="linux-amd64" ;;
  aarch64|arm64) ARCH="linux-arm64" ;;
  armv6l|armv7l) ARCH="linux-armv6l" ;;
  i386|i686)     ARCH="linux-386" ;;
  *) die "不支持的架构：$(uname -m)" ;;
esac

# 未指定版本时取官方最新稳定版（输出第一行形如 go1.23.4）
if [ -z "$GO_VERSION" ]; then
  GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n 1 | sed 's/^go//') \
    || die "无法获取最新版本号，请用 GO_VERSION=x.y.z 指定"
fi
[[ $GO_VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "版本号格式不对：$GO_VERSION"

# 已安装版本检查（直接用绝对路径，不依赖当前 PATH）
GO_BIN="$INSTALL_DIR/go/bin/go"
if [ -x "$GO_BIN" ]; then
  current=$("$GO_BIN" version | awk '{print $3}')
  if [ "$current" = "go$GO_VERSION" ]; then
    echo "已经是 $current，无需安装。"
    exit 0
  fi
  echo "检测到已安装版本：$current，目标版本：go$GO_VERSION"
  ask "是否替换为 go$GO_VERSION？(y/n) " || { echo "保留现有安装"; exit 0; }
fi

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

package="go$GO_VERSION.$ARCH.tar.gz"
url="https://dl.google.com/go/$package"

echo "正在下载 $package ..."
curl -fL --progress-bar -o "$temp_dir/$package" "$url" || die "下载失败：$url"

# 官方 .sha256 文件里只有哈希值，没有文件名，需要拼成 "哈希  文件名" 再校验
echo "验证文件完整性..."
expected=$(curl -fsSL "$url.sha256") || die "无法下载校验文件"
(cd "$temp_dir" && echo "$expected  $package" | sha256sum -c --quiet -) \
  || die "校验和不匹配！文件可能损坏或被篡改"

# 官方建议：先删除旧目录再解压，避免新旧文件混在一起
echo "正在安装到 $INSTALL_DIR/go ..."
rm -rf "$INSTALL_DIR/go"
tar -C "$INSTALL_DIR" -xzf "$temp_dir/$package"

cat > "$PROFILE_SNIPPET" <<'EOF'
# Go 环境变量（由 golong.sh 生成）
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
EOF
chmod 644 "$PROFILE_SNIPPET"

echo "验证安装..."
"$GO_BIN" version

# 用 go run 跑一个单文件程序，模块模式下不需要 go.mod
cat > "$temp_dir/hello.go" <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("Go 安装成功！")
}
EOF
GOCACHE="$temp_dir/cache" GOPATH="$temp_dir/gopath" "$GO_BIN" run "$temp_dir/hello.go"

echo "安装完成！重新登录或执行 'source $PROFILE_SNIPPET' 后即可直接使用 go 命令。"
__LT_PAYLOAD_END__
}

payload_Debian_hostname_sh() {
cat <<'__LT_PAYLOAD_END__'
#!/usr/bin/env bash
#
# 修改主机名（Debian 12 / 13）
#
# 用法：
#   sudo bash hostname.sh            交互式输入新主机名
#   sudo bash hostname.sh <新主机名>  直接修改，如 web01 或 web01.example.com
#
# 除了 hostnamectl set-hostname，还会：
#   * 同步 /etc/hosts 里的 127.0.1.1 一行（Debian 的约定）。不改的话 sudo 每次都会提示
#     "unable to resolve host <新主机名>"
#   * 云服务器上 cloud-init 默认会在重启时把主机名改回去，检测到时询问是否让它保留新主机名
#   * 没有 systemd 的环境（部分容器）里改用 /etc/hostname + hostname 命令

set -uo pipefail

HOSTS="/etc/hosts"
CLOUD_CFG_DIR="/etc/cloud/cloud.cfg.d"
CLOUD_KEEP="$CLOUD_CFG_DIR/99-linux-tools-hostname.cfg"

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
else
    BOLD=''; RED=''; GREEN=''; YELLOW=''; NC=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

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

# 合法主机名：每段 1-63 个字符，只含字母、数字和 -，不能以 - 开头或结尾；总长不超过 253
valid_hostname() {
    local h=$1 label labels=()
    [[ -n $h && ${#h} -le 253 && $h != *. && $h != .* ]] || return 1
    IFS='.' read -ra labels <<<"$h"
    for label in "${labels[@]}"; do
        [[ $label =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
    done
}

current_hostname() { hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || hostname; }

set_hostname() {
    local new=$1
    if command -v hostnamectl >/dev/null 2>&1 && hostnamectl set-hostname "$new" 2>/dev/null; then
        return 0
    fi
    # 没有 systemd（或 hostnamectl 不可用）时的做法
    printf '%s\n' "$new" > /etc/hostname && hostname "$new"
}

# 把 /etc/hosts 的 127.0.1.1 一行改成新主机名，没有就加一行
update_hosts() {
    local new=$1 old=$2 short=${1%%.*} entry tmp b
    [[ -f $HOSTS ]] || return 0
    if [[ $new == *.* ]]; then entry="127.0.1.1	$new $short"; else entry="127.0.1.1	$new"; fi

    b="$HOSTS.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a "$HOSTS" "$b"
    tmp=$(mktemp) || return 1
    if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]' "$HOSTS"; then
        awk -v e="$entry" '$1 == "127.0.1.1" && !done { print e; done = 1; next } { print }' "$HOSTS" > "$tmp"
    else
        cat "$HOSTS" > "$tmp"
        printf '%s\n' "$entry" >> "$tmp"
    fi
    # 用 cat 写回，保留原文件的权限和属主
    cat "$tmp" > "$HOSTS"
    rm -f -- "$tmp"
    info "已更新 $HOSTS：$entry（原文件备份在 $b）"

    # 其他行里还出现旧主机名时只提醒，不擅自修改
    if [[ -n $old && $old != "$new" ]] &&
       grep -vE '^[[:space:]]*(#|127\.0\.1\.1[[:space:]])' "$HOSTS" | grep -qwF -- "$old"; then
        warn "$HOSTS 的其他行里还有旧主机名 $old，请自行检查："
        grep -nwF -- "$old" "$HOSTS" | grep -v '127\.0\.1\.1' >&2
    fi
}

# cloud-init 的 preserve_hostname 默认是 false，重启时会把主机名改回服务商设置的值
keep_with_cloud_init() {
    [[ -d /etc/cloud ]] || return 0
    command -v cloud-init >/dev/null 2>&1 || return 0
    if grep -rqsE '^[[:space:]]*preserve_hostname:[[:space:]]*true' /etc/cloud/cloud.cfg "$CLOUD_CFG_DIR"; then
        return 0
    fi
    warn "检测到 cloud-init，它默认会在重启时把主机名改回服务商面板里的名字。"
    if ask_yn "让 cloud-init 保留新主机名吗？（写入 $CLOUD_KEEP）" y; then
        mkdir -p "$CLOUD_CFG_DIR"
        printf '# 由 Linux-tools hostname.sh 生成：重启时不要改回主机名\npreserve_hostname: true\n' > "$CLOUD_KEEP"
        ok "已写入 $CLOUD_KEEP"
    else
        info "没有修改 cloud-init，重启后主机名可能会被改回去。"
    fi
}

main() {
    local old new input
    case ${1:-} in
        -h|--help) info "用法: sudo bash ${0##*/} [新主机名]"; exit 0 ;;
    esac
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"

    old=$(current_hostname)
    printf '%s修改主机名%s\n' "$BOLD" "$NC"
    info "  当前主机名：$old"

    input=${1:-}
    if [[ -z $input ]]; then
        (( HAVE_TTY )) || die "需要交互式终端，或者直接把新主机名写在参数里。"
        info "  只能用字母、数字、- 和 .，例如 web01 或 web01.example.com"
        read -r -p "  新主机名（直接回车取消）: " input </dev/tty || input=''
        [[ -n $input ]] || { info "已取消，没有做任何修改。"; exit 0; }
    fi

    new=${input,,}
    [[ $new != "$input" ]] && info "  主机名不区分大小写，统一用小写：$new"
    valid_hostname "$new" || die "主机名不合法：$input（每段 1-63 个字母、数字或 -，不能以 - 开头或结尾）"
    if [[ $new == "$old" ]]; then
        info "主机名已经是 $new，无需修改。"
        exit 0
    fi

    set_hostname "$new" || die "修改主机名失败。"
    ok "主机名已改为 $new"
    update_hosts "$new" "$old"
    keep_with_cloud_init
    info "当前 shell 的提示符要重新登录后才会显示新主机名。"
}

main "$@"
__LT_PAYLOAD_END__
}

payload_Debian_q_sh() {
cat <<'__LT_PAYLOAD_END__'
#!/bin/bash

# 启用严格错误检查模式
set -euo pipefail

# 定义常量
KEYRINGS_DIR="/etc/apt/keyrings"
REPO_NAME="natesales"
GPG_KEY_URL="https://repo.natesales.net/apt/gpg.key"
GPG_KEY_PATH="$KEYRINGS_DIR/$REPO_NAME.gpg"
SOURCE_LIST_PATH="/etc/apt/sources.list.d/$REPO_NAME.list"
REPO_ENTRY="deb [signed-by=$GPG_KEY_PATH] https://repo.natesales.net/apt * *"

# 检查依赖项
check_deps() {
  local missing=()
  command -v curl &> /dev/null || missing+=(curl)
  command -v gpg  &> /dev/null || missing+=(gpg)
  if (( ${#missing[@]} )); then
    echo "正在安装依赖项: ${missing[*]}..."
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}"
  fi
}

# 检查 root 权限
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本" >&2
    exit 1
  fi
}

# 创建密钥目录
create_keyring_dir() {
  if [ ! -d "$KEYRINGS_DIR" ]; then
    echo "创建密钥目录: $KEYRINGS_DIR"
    mkdir -p "$KEYRINGS_DIR"
    chmod 755 "$KEYRINGS_DIR"
  fi
}

# 导入 GPG 密钥
import_gpg_key() {
  echo "下载并验证 GPG 密钥..."
  # 全局变量 + EXIT trap：任何一步失败退出时都能删掉临时文件
  temp_key=$(mktemp)
  trap 'rm -f "$temp_key"' EXIT

  # 下载密钥并验证状态码
  if ! curl -fsSL "$GPG_KEY_URL" -o "$temp_key"; then
    echo "错误：无法下载 GPG 密钥" >&2
    exit 1
  fi

  # 验证密钥格式（--show-keys 只解析，不写入 root 的密钥环）
  if ! gpg --show-keys "$temp_key" &> /dev/null; then
    echo "错误：无效的 GPG 密钥格式" >&2
    exit 1
  fi

  # 转换并安装密钥
  gpg --dearmor --yes -o "$GPG_KEY_PATH" "$temp_key"
  chmod 644 "$GPG_KEY_PATH"
}

# 添加软件源
add_repository() {
  echo "添加软件源..."
  echo "$REPO_ENTRY" | tee "$SOURCE_LIST_PATH" >/dev/null
  chmod 644 "$SOURCE_LIST_PATH"
}

# 安装软件包
install_package() {
  echo "更新软件包列表..."
  apt-get update -qq

  if ! apt-get install -y -qq q; then
    echo "错误：软件包安装失败" >&2
    echo "建议操作："
    echo "1. 检查仓库配置: $SOURCE_LIST_PATH"
    echo "2. 确认网络连接正常"
    exit 1
  fi

  echo "验证安装结果..."
  if ! command -v q &> /dev/null; then
    echo "错误：软件包安装后未找到可执行文件" >&2
    exit 1
  fi

  echo "安装版本信息："
  q -V
}

# 主流程
main() {
  check_root
  check_deps
  create_keyring_dir
  import_gpg_key
  add_repository
  install_package
  echo "安装完成"
}

# 执行主函数
main
__LT_PAYLOAD_END__
}

payload_Debian_singbox_sh() {
cat <<'__LT_PAYLOAD_END__'
#!/usr/bin/env bash
#
# sing-box 安装与 AnyTLS / AnyReality 节点配置（Debian 12 / 13）
#
# 在 fixed_script.sh（Manus AI 生成的 AnyTLS/AnyReality 配置脚本）的基础上优化，
# 同时保留原 singbox.sh 的功能：从 sing-box 官方 apt 源安装 / 升级程序。
#
# 用法：
#   sudo bash singbox.sh             交互式菜单
#   sudo bash singbox.sh --install   只安装 / 升级 sing-box 程序
#   sudo bash singbox.sh --link      显示节点链接
#
# 与 fixed_script.sh 的不同：
#   * 从官方 apt 源安装稳定版并校验签名密钥；原脚本用 curl | sh 安装测试版（--beta）
#   * 选错配置模式时直接返回；原脚本会写出一个没有任何入站的配置并重启服务
#   * 写入前备份原配置，写入后先用 sing-box check 检查，不通过就恢复原配置、不重启
#   * 端口检查改用系统自带的 ss，不再安装 net-tools；重新配置时 sing-box 自己占着的端口不算冲突
#   * 取公网 IP 的函数不再叫 ip（原脚本把系统的 ip 命令覆盖了），并有多个备用地址；
#     IPv6 地址在链接里加方括号，密码做 URL 编码
#   * 配置、私钥、节点信息（含密码）只有 root 和 sing-box 服务用户能读
#   * 卸载用 apt 删除软件包，删除配置和软件源前分别确认
#   * 所有提问从 /dev/tty 读，用 bash <(curl ...) 或从主菜单调用时都能正常交互

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

SB_DIR="/etc/sing-box"
CONFIG_FILE="$SB_DIR/config.json"
TLS_DIR="$SB_DIR/anytls/tls"
INFO_FILE="/root/.sb_info.json"
SERVICE="sing-box"

KEYRING="/etc/apt/keyrings/sagernet.asc"
SOURCE_LIST="/etc/apt/sources.list.d/sagernet.list"
GPG_KEY_URL="https://sing-box.app/gpg.key"

DEFAULT_SNI="genshin.hoyoverse.com"
MIN_VERSION="1.12.0"   # AnyTLS 入站从 1.12.0 开始支持

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'
else
    BOLD=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法: sudo bash ${0##*/} [选项]

  （不带参数）   打开交互式菜单
  --install      只安装 / 升级 sing-box 程序（官方 apt 源）
  --link         显示节点链接
  -h, --help     显示本帮助
EOF
}

# -----------------------------------------------------------------------------
# 交互：一律从 /dev/tty 读
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

# ask_value <提示> <默认值> <校验正则>；结果输出到 stdout。默认值为空时不显示 []
ask_value() {
    local prompt=$1 def=$2 re=$3 reply='' shown=''
    [[ -n $def ]] && shown=" [$def]"
    while true; do
        read -r -p "$prompt$shown: " reply </dev/tty || reply=''
        reply=${reply:-$def}
        if [[ $reply =~ $re ]]; then
            printf '%s' "$reply"
            return
        fi
        printf '  输入无效，请重新输入。\n' >&2
    done
}

pause() { read -r -p "按回车继续..." _ </dev/tty || true; }

# -----------------------------------------------------------------------------
# 工具函数
# -----------------------------------------------------------------------------
# 新装的 VPS 上 unattended-upgrades 经常持有 dpkg 锁，最多等 120 秒
apt_get() { apt-get -o DPkg::Lock::Timeout=120 "$@"; }

sb_installed() { command -v sing-box >/dev/null 2>&1; }
sb_version()   { sing-box version 2>/dev/null | awk 'NR == 1 { print $NF }'; }

# 端口被其他程序占用时返回 0；sing-box 自己占着的不算，重新配置后会重启它
port_busy() {
    local out
    out=$(ss -Htulnp "sport = :$1" 2>/dev/null) || return 1
    [[ -n $out ]] && grep -qv '"sing-box"' <<<"$out"
}

# 公网 IP，IPv6 带方括号；多个地址依次尝试
SERVER_HOST=''
public_host() {
    [[ -n $SERVER_HOST ]] && { printf '%s' "$SERVER_HOST"; return; }
    local u a
    for u in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
        a=$(curl -fs4 --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
        [[ $a =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { SERVER_HOST=$a; printf '%s' "$a"; return; }
    done
    for u in https://api64.ipify.org https://ifconfig.me https://ipv6.icanhazip.com; do
        a=$(curl -fs6 --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
        [[ $a =~ ^[0-9A-Fa-f:]+$ && $a == *:* ]] && { SERVER_HOST="[$a]"; printf '%s' "$SERVER_HOST"; return; }
    done
    return 1
}

# 含私钥和密码的文件：只给 root 和 sing-box 服务用户读
protect() {
    local user group
    user=$(systemctl show -p User --value "$SERVICE" 2>/dev/null)
    if [[ -n $user && $user != root ]] && group=$(id -gn "$user" 2>/dev/null); then
        chown root:"$group" "$@" && chmod 640 "$@"
    else
        chown root:root "$@" && chmod 600 "$@"
    fi
}

# -----------------------------------------------------------------------------
# 安装 sing-box（官方 apt 源）
# -----------------------------------------------------------------------------
install_singbox() {
    local missing=() tmp
    command -v curl    >/dev/null 2>&1 || missing+=(curl)
    command -v gpg     >/dev/null 2>&1 || missing+=(gpg)
    command -v jq      >/dev/null 2>&1 || missing+=(jq)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    if (( ${#missing[@]} )); then
        info "安装依赖：${missing[*]} ..."
        { apt_get update -qq && apt_get install -y -qq "${missing[@]}"; } || { warn "依赖安装失败"; return 1; }
    fi

    info "配置 sing-box 官方软件源..."
    install -d -m 755 /etc/apt/keyrings
    tmp=$(mktemp) || return 1
    if ! curl -fsSL "$GPG_KEY_URL" -o "$tmp" || ! gpg --show-keys "$tmp" >/dev/null 2>&1; then
        rm -f -- "$tmp"
        warn "下载或校验签名密钥失败：$GPG_KEY_URL"
        return 1
    fi
    install -m 644 "$tmp" "$KEYRING"
    rm -f -- "$tmp"
    printf 'deb [arch=%s signed-by=%s] https://deb.sagernet.org/ * *\n' \
        "$(dpkg --print-architecture)" "$KEYRING" > "$SOURCE_LIST"
    chmod 644 "$SOURCE_LIST"

    info "安装 sing-box..."
    apt_get update -qq || { warn "apt update 失败，请检查网络和 $SOURCE_LIST"; return 1; }
    apt_get install -y sing-box || { warn "sing-box 安装失败"; return 1; }
    hash -r
    sb_installed || { warn "安装后找不到 sing-box 命令"; return 1; }
    ok "sing-box $(sb_version) 已安装"
}

# -----------------------------------------------------------------------------
# 配置节点
# -----------------------------------------------------------------------------
# ask_port <名称> <默认端口> [不能相同的端口]
ask_port() {
    local label=$1 def=$2 other=${3:-} p
    while true; do
        p=$(ask_value "  $label 端口" "$def" '^[0-9]{1,5}$')
        p=$((10#$p))
        if (( p < 1 || p > 65535 )); then warn "端口必须在 1-65535 之间"; continue; fi
        if [[ $p == "$other" ]]; then warn "两个协议不能用同一个端口"; continue; fi
        if port_busy "$p"; then
            warn "端口 $p 已被其他程序占用："
            ss -Htulnp "sport = :$p" >&2
            continue
        fi
        printf '%s' "$p"
        return
    done
}

ask_password() {
    local pw
    pw=$(ask_value "  $1 密码（回车随机生成）" "" '^[^[:space:]]{0,128}$')
    [[ -n $pw ]] || pw=$(openssl rand -hex 16)
    printf '%s' "$pw"
}

gen_cert() {
    install -d -m 755 "$TLS_DIR"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.crt" \
        -subj "/CN=$1" -addext "subjectAltName=DNS:$1" -days 3650 >/dev/null 2>&1 || return 1
    protect "$TLS_DIR/server.key"
    chmod 644 "$TLS_DIR/server.crt"
}

# 防火墙：ufw 开着时询问是否放行（AnyTLS 只用 TCP）
open_firewall() {
    local p
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q '^Status: active' || return 0
    if ask_yn "检测到 ufw 防火墙已开启，放行端口 $* (TCP) 吗？" y; then
        for p in "$@"; do ufw allow "$p/tcp" >/dev/null && info "  已放行 $p/tcp"; done
    fi
}

configure() {
    local mode rp='' rpw rsni kp priv pub sid ap='' apw asni
    local ib='[]' ci='{}' bak='' out others c

    if ! sb_installed; then
        install_singbox || return 1
    fi
    if ! dpkg --compare-versions "$(sb_version)" ge "$MIN_VERSION" 2>/dev/null; then
        warn "当前 sing-box 版本 $(sb_version) 不支持 AnyTLS（需要 $MIN_VERSION 以上），请先用菜单升级。"
        return 1
    fi
    for c in jq openssl; do
        command -v "$c" >/dev/null 2>&1 || { warn "缺少 $c，请先用菜单「安装 / 升级 sing-box」"; return 1; }
    done

    printf '\n%s配置模式%s\n' "$BOLD" "$NC"
    printf '  1) 仅 AnyReality（借用目标网站的证书，不需要域名）\n'
    printf '  2) 仅 AnyTLS（自签证书，客户端需跳过证书验证）\n'
    printf '  3) 双协议（AnyReality + AnyTLS）\n'
    printf '  0) 返回\n'
    mode=$(ask_value "请选择" 1 '^[0-3]$')
    [[ $mode == 0 ]] && return 0

    if [[ $mode == 1 || $mode == 3 ]]; then
        printf '\n%sAnyReality%s\n' "$BOLD" "$NC"
        rp=$(ask_port AnyReality 1443)
        rpw=$(ask_password AnyReality)
        rsni=$(ask_value "  Reality 目标网站（需支持 TLS 1.3）" "$DEFAULT_SNI" '^[A-Za-z0-9.-]+$')
        kp=$(sing-box generate reality-keypair 2>/dev/null)
        priv=$(awk '/^PrivateKey/ { print $2 }' <<<"$kp")
        pub=$(awk '/^PublicKey/ { print $2 }' <<<"$kp")
        [[ -n $priv && -n $pub ]] || { warn "生成 Reality 密钥失败"; return 1; }
        sid=$(openssl rand -hex 8)

        ib=$(jq --arg p "$rp" --arg w "$rpw" --arg s "$rsni" --arg k "$priv" --arg id "$sid" '. + [{
            type: "anytls",
            tag: "anyreality-in",
            listen: "::",
            listen_port: ($p | tonumber),
            users: [{name: "user", password: $w}],
            padding_scheme: ["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
            tls: {
                enabled: true,
                server_name: $s,
                reality: {
                    enabled: true,
                    handshake: {server: $s, server_port: 443},
                    private_key: $k,
                    short_id: [$id]
                }
            }
        }]' <<<"$ib")
        ci=$(jq --arg p "$rp" --arg w "$rpw" --arg s "$rsni" --arg pk "$pub" --arg id "$sid" \
            '. + {reality: {port: $p, pwd: $w, sni: $s, pk: $pk, id: $id}}' <<<"$ci")
    fi

    if [[ $mode == 2 || $mode == 3 ]]; then
        printf '\n%sAnyTLS%s\n' "$BOLD" "$NC"
        ap=$(ask_port AnyTLS 2026 "$rp")
        apw=$(ask_password AnyTLS)
        asni=$(ask_value "  证书域名（自签证书，随便填）" "$DEFAULT_SNI" '^[A-Za-z0-9.-]+$')
        info "  生成自签 TLS 证书（CN=$asni）..."
        gen_cert "$asni" || { warn "生成证书失败"; return 1; }

        ib=$(jq --arg p "$ap" --arg w "$apw" --arg cert "$TLS_DIR/server.crt" --arg key "$TLS_DIR/server.key" '. + [{
            type: "anytls",
            tag: "anytls-in",
            listen: "::",
            listen_port: ($p | tonumber),
            users: [{password: $w}],
            padding_scheme: ["stop=6","0=23-23","1=50-200","2=330-400,c,500-600,c,700-750,c,780-790,c,800-1200","3=1-1,2800-998","4=670-1800","5=340-600"],
            tls: {
                enabled: true,
                certificate_path: $cert,
                key_path: $key
            }
        }]' <<<"$ib")
        ci=$(jq --arg p "$ap" --arg w "$apw" --arg s "$asni" \
            '. + {anytls: {port: $p, pwd: $w, sni: $s}}' <<<"$ci")
    fi

    # ---- 写入配置：先备份，检查不通过就恢复 ---------------------------------
    install -d -m 755 "$SB_DIR"
    if [[ -f $CONFIG_FILE ]]; then
        bak="$CONFIG_FILE.bak"
        cp -a "$CONFIG_FILE" "$bak"
    fi
    jq -n --argjson ib "$ib" '{log: {level: "info", timestamp: true}, inbounds: $ib}' > "$CONFIG_FILE"
    protect "$CONFIG_FILE"

    # 官方服务用 -C /etc/sing-box 运行，目录里所有 .json 都会合并加载，这里按同样方式检查
    others=$(find "$SB_DIR" -maxdepth 1 -name '*.json' ! -name config.json 2>/dev/null)
    [[ -n $others ]] && warn "$SB_DIR 里还有其他 .json 文件，sing-box 会一起加载：$(tr '\n' ' ' <<<"$others")"
    if ! out=$(sing-box check -C "$SB_DIR" 2>&1); then
        warn "sing-box check 未通过，已恢复原配置，服务没有重启："
        printf '%s\n' "$out" >&2
        if [[ -n $bak ]]; then mv -f "$bak" "$CONFIG_FILE"; else rm -f -- "$CONFIG_FILE"; fi
        return 1
    fi

    printf '%s\n' "$ci" > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
    [[ -n $bak ]] && info "上一次的配置备份在 $bak"

    systemctl enable "$SERVICE" >/dev/null 2>&1
    systemctl restart "$SERVICE"
    sleep 1
    if ! systemctl is-active --quiet "$SERVICE"; then
        warn "sing-box 启动失败，最近的日志："
        journalctl -u "$SERVICE" -n 20 --no-pager >&2
        return 1
    fi
    ok "sing-box 已按新配置启动"
    open_firewall $rp $ap      # 故意不加引号：没配置的协议端口为空，不传
    show_links
}

# -----------------------------------------------------------------------------
# 节点链接
# -----------------------------------------------------------------------------
show_links() {
    local host name p w s k d
    [[ -f $INFO_FILE ]] || { warn "还没有配置过节点（找不到 $INFO_FILE）"; return 1; }
    command -v jq >/dev/null 2>&1 || { warn "缺少 jq，请先用菜单「安装 / 升级 sing-box」"; return 1; }
    host=$(public_host) || { warn "获取公网 IP 失败，链接里用 <服务器IP> 代替"; host='<服务器IP>'; }
    name=${host//[\[\]]/}

    if jq -e .reality "$INFO_FILE" >/dev/null 2>&1; then
        read -r p w s k d < <(jq -r '.reality | [.port, (.pwd | @uri), .sni, .pk, .id] | @tsv' "$INFO_FILE")
        printf '\n%s[AnyReality]%s\n' "$GREEN" "$NC"
        printf 'anytls://%s@%s:%s/?sni=%s&fp=chrome&pbk=%s&sid=%s#AnyReality_%s\n' "$w" "$host" "$p" "$s" "$k" "$d" "$name"
    fi
    if jq -e .anytls "$INFO_FILE" >/dev/null 2>&1; then
        read -r p w s < <(jq -r '.anytls | [.port, (.pwd | @uri), .sni] | @tsv' "$INFO_FILE")
        printf '\n%s[AnyTLS]%s\n' "$GREEN" "$NC"
        printf 'anytls://%s@%s:%s/?sni=%s&insecure=1#AnyTLS_%s\n' "$w" "$host" "$p" "$s" "$name"
    fi
    printf '\n'
}

# -----------------------------------------------------------------------------
# 服务管理 / 卸载
# -----------------------------------------------------------------------------
manage_service() {
    printf '  1) 启动  2) 停止  3) 重启  0) 返回\n'
    case $(ask_value "请选择" 0 '^[0-3]$') in
        1) systemctl start "$SERVICE" && ok "已启动" ;;
        2) systemctl stop "$SERVICE" && ok "已停止" ;;
        3) systemctl restart "$SERVICE" && ok "已重启" ;;
    esac
}

show_logs() {
    systemctl status "$SERVICE" --no-pager 2>&1 | head -n 12
    printf '\n%s最近 50 行日志：%s\n' "$BOLD" "$NC"
    journalctl -u "$SERVICE" -n 50 --no-pager
}

uninstall() {
    local pkg
    ask_yn "卸载 sing-box 吗？" n || return 0
    systemctl disable --now "$SERVICE" >/dev/null 2>&1
    # 原脚本用 install.sh --beta 装的是 sing-box-beta 包，一并处理
    for pkg in sing-box sing-box-beta; do
        dpkg -s "$pkg" >/dev/null 2>&1 && apt_get purge -y "$pkg"
    done
    if ask_yn "同时删除配置、证书和节点信息（$SB_DIR、$INFO_FILE）吗？" y; then
        rm -rf -- "$SB_DIR"
        rm -f -- "$INFO_FILE"
    fi
    if ask_yn "同时删除 sing-box 的 apt 软件源吗？" y; then
        rm -f -- "$SOURCE_LIST" "$KEYRING"
    fi
    systemctl daemon-reload
    ok "卸载完成"
}

# -----------------------------------------------------------------------------
# 菜单
# -----------------------------------------------------------------------------
show_status() {
    local v st nodes=''
    info "=============================================================="
    info " ${BOLD}sing-box 管理（AnyTLS / AnyReality）${NC}"
    info "=============================================================="
    if sb_installed; then
        v=$(sb_version)
        if systemctl is-active --quiet "$SERVICE"; then st="${GREEN}运行中${NC}"; else st="${YELLOW}未运行${NC}"; fi
        info " sing-box : $v · $st"
    else
        info " sing-box : 未安装"
    fi
    if [[ -f $INFO_FILE ]] && command -v jq >/dev/null 2>&1; then
        nodes=$(jq -r '[(if .reality then "AnyReality 端口 \(.reality.port)" else empty end),
                        (if .anytls then "AnyTLS 端口 \(.anytls.port)" else empty end)] | join("，")' "$INFO_FILE" 2>/dev/null)
    fi
    info " 节点     : ${nodes:-未配置}"
    info "=============================================================="
}

menu() {
    while true; do
        printf '\n'
        show_status
        printf '  %s1)%s 安装 / 重新配置节点\n' "$CYAN" "$NC"
        printf '  %s2)%s 显示节点链接\n' "$CYAN" "$NC"
        printf '  %s3)%s 启动 / 停止 / 重启服务\n' "$CYAN" "$NC"
        printf '  %s4)%s 查看状态和日志\n' "$CYAN" "$NC"
        printf '  %s5)%s 只安装 / 升级 sing-box 程序\n' "$CYAN" "$NC"
        printf '  %s6)%s 卸载\n' "$CYAN" "$NC"
        printf '  %s0)%s 退出\n' "$CYAN" "$NC"
        case $(ask_value "请选择" 0 '^[0-6]$') in
            1) configure; pause ;;
            2) show_links; pause ;;
            3) manage_service ;;
            4) show_logs; pause ;;
            5) install_singbox; pause ;;
            6) uninstall; pause ;;
            *) return 0 ;;
        esac
    done
}

main() {
    local action=''
    case ${1:-} in
        --install) action=install ;;
        --link)    action=link ;;
        -h|--help) usage; exit 0 ;;
        '') ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"

    case $action in
        install) install_singbox ;;
        link)    show_links ;;
        '')
            (( HAVE_TTY )) || die "需要交互式终端。"
            menu ;;
    esac
}

main "$@"
__LT_PAYLOAD_END__
}

payload_Debian_ssh_keyonly_sh() {
cat <<'__LT_PAYLOAD_END__'
#!/usr/bin/env bash
#
# SSH 禁止密码登录，只允许密钥登录（Debian 12 / 13）
#
# 用法：
#   sudo bash ssh-keyonly.sh            交互式菜单
#   sudo bash ssh-keyonly.sh --status   只查看当前实际生效的登录设置
#   sudo bash ssh-keyonly.sh --restore  删除本脚本的配置，恢复原来的登录方式
#
# 做法：不改 /etc/ssh/sshd_config 本身，只写一个单独的文件
# /etc/ssh/sshd_config.d/00-linux-tools-keyonly.conf，恢复时删掉它即可。
#   * sshd 对同一个选项只认第一次出现的值。Debian 的 sshd_config 开头就 Include 了 sshd_config.d/*.conf，
#     文件名用 00 开头，能排在 cloud-init 写的 50-cloud-init.conf（常见内容 PasswordAuthentication yes）前面
#
# 与常见教程的不同：
#   * 不设 UsePAM no。Debian 上关掉 PAM 后，登录面板（pam_motd）、资源限制（pam_limits）、
#     systemd 登录会话都会失效。关掉 KbdInteractiveAuthentication 后，PAM 就不会再询问密码
#   * ChallengeResponseAuthentication 从 OpenSSH 8.7 起改名为 KbdInteractiveAuthentication，这里用新名字
#   * 应用前检查各用户有没有可用的公钥，一把都没有就拒绝，避免把自己锁在外面
#   * 写入后先用 sshd -t 检查语法、用 sshd -T 确认真的生效，不对就自动撤销；最后 reload 而不是 restart，
#     已经连着的会话不受影响。Debian 的服务名是 ssh，sshd 只是别名

set -uo pipefail

CONF_DIR="/etc/ssh/sshd_config.d"
CONF="$CONF_DIR/00-linux-tools-keyonly.conf"
MAIN_CONF="/etc/ssh/sshd_config"
SSHD=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)

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

  （不带参数）   打开交互式菜单
  --status       查看当前实际生效的 SSH 登录设置
  --restore      删除本脚本的配置，恢复原来的登录方式
  -h, --help     显示本帮助
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
# 读取 sshd 实际生效的配置
# -----------------------------------------------------------------------------
# sshd -t / -T 需要这个目录；sshd 没在运行时可能不存在
prep_sshd() { [[ -d /run/sshd ]] || mkdir -p -m 0755 /run/sshd; }

SSHD_T=''
load_effective() { prep_sshd; SSHD_T=$("$SSHD" -T 2>/dev/null) || SSHD_T=''; }

# eff <选项名，小写>：取 sshd -T 输出里的值
eff() { awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' <<<"$SSHD_T"; }

yn_text() {
    case $1 in
        yes) printf '允许' ;;
        no)  printf '禁止' ;;
        *)   printf '%s' "${1:-未知}" ;;
    esac
}

# 当前是哪个用户在操作（通过 sudo 时取原用户）
current_user() { printf '%s' "${SUDO_USER:-root}"; }

# 可以登录的用户：root，以及 UID ≥ 1000、shell 不是 nologin/false 的普通用户
login_users() {
    getent passwd | awk -F: '$1 == "root" || ($3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/) { print $1 }'
}

# keys_of <用户>：该用户 authorized_keys 里有效公钥的数量（按 sshd 的 AuthorizedKeysFile 设置查找）
keys_of() {
    local user=$1 home files f n=0
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -n $home ]] || { echo 0; return; }
    files=$(eff authorizedkeysfile)
    [[ -n $files ]] || files=".ssh/authorized_keys .ssh/authorized_keys2"
    for f in $files; do      # 这里需要按空格拆分，故意不加引号
        f=${f//"%h"/$home}
        f=${f//"%u"/$user}
        [[ $f == /* ]] || f="$home/$f"
        [[ -f $f ]] || continue
        n=$(( n + $(ssh-keygen -lf "$f" 2>/dev/null | wc -l) ))
    done
    echo "$n"
}

show_status() {
    local pw
    load_effective
    info "=============================================================="
    info " ${BOLD}SSH 登录方式${NC}（当前实际生效的设置）"
    info "=============================================================="
    if [[ -z $SSHD_T ]]; then
        warn "无法读取 sshd 配置（sshd -T 失败），配置文件可能有错误。"
        info "=============================================================="
        return 1
    fi
    pw=$(eff passwordauthentication)
    if [[ $pw == no ]]; then
        info " 密码登录         : ${GREEN}禁止${NC}"
    else
        info " 密码登录         : ${YELLOW}$(yn_text "$pw")${NC}"
    fi
    info " 键盘交互登录     : $(yn_text "$(eff kbdinteractiveauthentication)")（PAM 通过它询问密码）"
    info " 密钥登录         : $(yn_text "$(eff pubkeyauthentication)")"
    info " 空密码登录       : $(yn_text "$(eff permitemptypasswords)")"
    info " root 登录        : $(eff permitrootlogin)"
    if [[ -f $CONF ]]; then
        info " 本脚本配置       : 已应用（$CONF）"
    else
        info " 本脚本配置       : 未应用"
    fi
    info "=============================================================="
}

# -----------------------------------------------------------------------------
# 应用 / 恢复
# -----------------------------------------------------------------------------
reload_ssh() {
    local unit
    for unit in ssh sshd; do
        if systemctl is-active --quiet "$unit.service" 2>/dev/null; then
            systemctl reload "$unit.service" && return 0
            warn "systemctl reload $unit 失败"
            return 1
        fi
    done
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        info "ssh 由 ssh.socket 按需启动，新连接会自动使用新配置。"
        return 0
    fi
    warn "没有找到正在运行的 ssh 服务，配置会在 ssh 下次启动时生效。"
}

# apply_keyonly <root 登录方式：prohibit-password | no | keep>
apply_keyonly() {
    local root_mode=$1 me u n total=0 out had_old=0 old=''
    me=$(current_user)
    load_effective
    [[ -n $SSHD_T ]] || { warn "无法读取 sshd 配置（sshd -T 失败），请先修好现有配置。"; return 1; }

    # ---- 防止把自己锁在外面 -------------------------------------------------
    info "各用户已配置的公钥："
    while read -r u; do
        n=$(keys_of "$u")
        if [[ $u == root && $root_mode == no ]]; then
            printf '  %-16s %s 把（root 将被完全禁止登录）\n' "$u" "$n"
            continue
        fi
        total=$(( total + n ))
        if (( n )); then
            printf '  %-16s %s 把\n' "$u" "$n"
        else
            printf '  %-16s %s没有公钥，禁止密码后将无法登录%s\n' "$u" "$YELLOW" "$NC"
        fi
    done < <(login_users)

    if (( total == 0 )); then
        warn "没有任何可登录的用户配置了公钥，现在禁止密码登录会把所有人锁在外面，已取消。"
        warn "请先用菜单里的「添加公钥」，并确认用密钥能登录。"
        return 1
    fi
    if [[ ! ($me == root && $root_mode == no) ]] && (( $(keys_of "$me") == 0 )); then
        warn "你当前使用的用户 $me 没有公钥，禁止密码登录后 $me 将无法登录。"
        ask_yn "仍要继续吗？" n || { info "已取消，没有做任何修改。"; return 1; }
    fi
    if grep -qsiE '^[[:space:]]*Match[[:space:]]' "$MAIN_CONF" "$CONF_DIR"/*.conf; then
        warn "sshd 配置里有 Match 段，它可能为部分用户或来源重新打开密码登录，请自行检查。"
    fi

    printf '\n'
    ask_yn "确认禁止 SSH 密码登录吗？" n || { info "已取消，没有做任何修改。"; return 1; }

    # ---- 确保 sshd_config 会读取 sshd_config.d ------------------------------
    if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN_CONF"; then
        local b
        b="$MAIN_CONF.bak.$(date +%Y%m%d_%H%M%S)"
        cp -a "$MAIN_CONF" "$b"
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN_CONF"
        info "$MAIN_CONF 里没有 Include sshd_config.d，已加在第一行（原文件备份在 $b）"
    fi

    # ---- 写入配置，检查不通过就撤销 -----------------------------------------
    mkdir -p "$CONF_DIR"
    if [[ -f $CONF ]]; then had_old=1; old=$(cat "$CONF"); fi
    {
        echo "# 由 Linux-tools ssh-keyonly.sh 生成。删除本文件并执行 systemctl reload ssh 即可恢复。"
        echo "PubkeyAuthentication yes"
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "PermitEmptyPasswords no"
        [[ $root_mode != keep ]] && echo "PermitRootLogin $root_mode"
    } > "$CONF"
    chmod 644 "$CONF"

    rollback() {
        if (( had_old )); then printf '%s\n' "$old" > "$CONF"; else rm -f -- "$CONF"; fi
    }
    if ! out=$("$SSHD" -t 2>&1); then
        warn "sshd 配置检查失败，已撤销本次修改："
        printf '%s\n' "$out" >&2
        rollback
        return 1
    fi
    load_effective
    if [[ $(eff passwordauthentication) != no || $(eff kbdinteractiveauthentication) != no ]]; then
        warn "写入后检查发现密码登录仍然开启（可能被 $MAIN_CONF 里更靠前的设置覆盖），已撤销本次修改。"
        rollback
        return 1
    fi

    reload_ssh || return 1
    ok "已禁止 SSH 密码登录，现在只能用密钥登录。"
    printf '\n%s不要关闭当前这个 SSH 窗口！%s先另开一个终端测试：\n' "$RED" "$NC"
    info "  1. 用密钥能登录：  ssh $me@<服务器IP>"
    info "  2. 密码会被拒绝：  ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password $me@<服务器IP>"
    info "     应该提示 Permission denied (publickey)"
    info "  如果登不上，在当前窗口（或服务商的 VNC / 控制台）执行下面这行即可恢复："
    info "     rm -f $CONF && systemctl reload ssh"
}

restore_login() {
    if [[ ! -f $CONF ]]; then
        info "没有应用过本脚本的配置，无需恢复。"
        return 0
    fi
    rm -f -- "$CONF"
    prep_sshd
    "$SSHD" -t || warn "sshd 配置检查有问题，请查看上面的输出。"
    reload_ssh
    ok "已删除 $CONF，恢复为系统原来的登录设置。"
    load_effective
    if [[ $(eff passwordauthentication) == no ]]; then
        info "注意：系统的其他配置本身就禁止了密码登录，所以现在仍然是禁止的。"
    fi
}

# -----------------------------------------------------------------------------
# 添加公钥
# -----------------------------------------------------------------------------
add_key() {
    local user home group key tmp dir file fp
    printf '\n%s添加公钥%s\n' "$BOLD" "$NC"
    info "  在你自己的电脑上执行 ssh-keygen -t ed25519 生成密钥，然后把 .pub 文件里的那一行粘贴到这里。"
    user=$(ask_value "  给哪个用户添加" "$(current_user)" '^[a-z_][a-z0-9_.-]*$')
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -n $home && -d $home ]] || { warn "用户 $user 不存在或没有家目录。"; return 1; }
    group=$(id -gn "$user")

    read -r -p "  公钥（以 ssh-ed25519、ssh-rsa 等开头）: " key </dev/tty || return 1
    if [[ $key == -----* ]]; then
        warn "这是私钥！私钥不要发给任何服务器，请粘贴 .pub 文件里的公钥。"
        return 1
    fi
    tmp=$(mktemp) || return 1
    printf '%s\n' "$key" > "$tmp"
    if ! fp=$(ssh-keygen -lf "$tmp" 2>/dev/null); then
        rm -f -- "$tmp"
        warn "这不是有效的公钥，没有添加。"
        return 1
    fi
    rm -f -- "$tmp"

    dir="$home/.ssh"
    file="$dir/authorized_keys"
    # sshd 默认的 StrictModes 要求 .ssh 是 700、authorized_keys 不能被别人写
    install -d -m 700 -o "$user" -g "$group" "$dir"
    if [[ -f $file ]] && grep -qxF -- "$key" "$file"; then
        info "  这把公钥已经在 $file 里了。"
        return 0
    fi
    # 原文件最后一行没有换行时先补上，否则新公钥会接在上一行末尾
    [[ -s $file && -n $(tail -c 1 "$file") ]] && echo >> "$file"
    printf '%s\n' "$key" >> "$file"
    chown "$user:$group" "$file"
    chmod 600 "$file"
    ok "已添加到 $file（$(awk '{ print $2, $NF }' <<<"$fp")）"
}

# -----------------------------------------------------------------------------
# 交互式菜单
# -----------------------------------------------------------------------------
interactive_apply() {
    local c mode
    printf '\n%s禁止密码登录%s\n' "$BOLD" "$NC"
    info "  root 的登录方式："
    info "    1) 只允许 root 用密钥登录（prohibit-password，推荐）"
    info "    2) 完全禁止 root 登录（no，需要另有一个能 sudo 的普通用户）"
    info "    3) 不修改 root 的设置"
    c=$(ask_value "  请选择" 1 '^[123]$')
    case $c in
        1) mode=prohibit-password ;;
        2) mode=no ;;
        *) mode=keep ;;
    esac
    if [[ $mode == no && $(current_user) == root ]]; then
        warn "你现在是用 root 登录的，完全禁止 root 后将不能再用 root 登录。"
        ask_yn "  仍要继续吗？" n || return 0
    fi
    apply_keyonly "$mode"
}

menu() {
    while true; do
        printf '\n'
        show_status
        printf '  1) 禁止密码登录（只允许密钥）\n'
        printf '  2) 添加公钥\n'
        printf '  3) 恢复原来的登录方式\n'
        printf '  0) 退出\n'
        case $(ask_value "请选择" 0 '^[0-3]$') in
            1) interactive_apply ;;
            2) add_key ;;
            3) ask_yn "  删除本脚本的配置，恢复原来的登录方式吗？" n && restore_login ;;
            *) return 0 ;;
        esac
    done
}

main() {
    local action=''
    case ${1:-} in
        --status)  action=status ;;
        --restore) action=restore ;;
        -h|--help) usage; exit 0 ;;
        '') ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
    [[ -x $SSHD ]] || die "没有找到 sshd，请先安装 openssh-server。"

    case $action in
        status)  show_status ;;
        restore) restore_login ;;
        '')
            (( HAVE_TTY )) || die "需要交互式终端。"
            menu ;;
    esac
}

main "$@"
__LT_PAYLOAD_END__
}

payload_Debian_swap_sh() {
cat <<'__LT_PAYLOAD_END__'
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
__LT_PAYLOAD_END__
}

payload_Debian_xanmod_kernel_sh() {
cat <<'__LT_PAYLOAD_END__'
#!/bin/bash

# XanMod Kernel 安装脚本 (修复版)
# 适用于 Debian 12+ (bookworm, trixie, sid)

# 启用严格错误检查
set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# apt 全程非交互；配置文件冲突时保留本地版本
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# 从终端读取单个字符，兼容 curl ... | bash 的用法；无终端时返回空
ask() {
  REPLY=''
  if [ -r /dev/tty ]; then
    read -r -p "$1" -n 1 REPLY </dev/tty || true
    echo
  fi
}

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
  log_error "请使用root权限运行此脚本"
  echo "使用方法: sudo bash $0"
  exit 1
fi

# 检测 Debian 版本
if [ ! -f /etc/os-release ]; then
  log_error "无法检测系统版本"
  exit 1
fi

source /etc/os-release

if [ "$ID" != "debian" ]; then
  log_error "此脚本仅支持 Debian 系统，当前系统: $ID"
  exit 1
fi

log_info "检测到系统: $PRETTY_NAME"

# 获取发行版代号：优先用 os-release，没有时再退回 lsb_release
DEBIAN_CODENAME="${VERSION_CODENAME:-}"
if [ -z "$DEBIAN_CODENAME" ]; then
  if ! command -v lsb_release &> /dev/null; then
    log_warn "lsb_release 未安装，正在安装..."
    apt-get update -qq
    apt-get install -y lsb-release
  fi
  DEBIAN_CODENAME=$(lsb_release -sc)
fi
log_info "发行版代号: $DEBIAN_CODENAME"

# 检查是否支持的版本
case "$DEBIAN_CODENAME" in
  bookworm|trixie|forky|sid)
    log_info "✓ 此版本受 XanMod 支持"
    ;;
  *)
    log_warn "警告: $DEBIAN_CODENAME 可能不被 XanMod 官方支持"
    ask "是否继续? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
    ;;
esac

# 创建交换空间函数
create_swap() {
  log_info "未检测到SWAP，正在创建1G的交换空间..."

  if ! fallocate -l 1G /swapfile 2>/dev/null; then
    log_warn "fallocate 失败，尝试使用 dd 创建交换文件..."
    dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
  fi

  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  # 备份并添加到 fstab
  if ! grep -q '/swapfile' /etc/fstab; then
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
  fi

  # swappiness 统一由后面的 /etc/sysctl.d/99-xanmod-optimizations.conf 设置
  # （Debian 13 已不再读取 /etc/sysctl.conf）

  swapon --show
  log_info "✓ SWAP 创建成功"
}

# 检查现有交换空间：有任何一行输出就说明已有交换（分区、文件、zram 都算）
if [ -z "$(swapon --noheadings --show 2>/dev/null)" ]; then
  create_swap
else
  log_info "✓ 已存在 SWAP 空间"
  swapon --show
fi

# 更新系统并安装依赖
log_info "更新软件包列表..."
apt-get update -y

log_info "安装必要依赖..."
apt-get install -y --no-install-recommends \
  curl \
  wget \
  gpg \
  lsb-release \
  apt-transport-https \
  ca-certificates

log_info "升级系统软件包..."
apt-get "${APT_OPTS[@]}" dist-upgrade -y

# 处理 XanMod GPG 密钥
keyring_path="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
temp_key=$(mktemp)

cleanup() {
  rm -f "$temp_key"
}
trap cleanup EXIT

# 创建 keyrings 目录
mkdir -p /etc/apt/keyrings

log_info "正在下载 XanMod 官方 GPG 密钥..."
# mktemp 已经创建了文件，必须加 --yes，否则 gpg 会停下来询问是否覆盖
if ! wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o "$temp_key"; then
  log_error "密钥下载或转换失败"
  exit 1
fi

# 验证密钥有效性
if ! gpg --no-default-keyring --keyring "$temp_key" --list-keys &> /dev/null; then
  log_error "无效的 GPG 密钥格式"
  exit 1
fi

# 安装已验证的密钥
mv -f "$temp_key" "$keyring_path"
chmod 644 "$keyring_path"
log_info "✓ GPG 密钥安装成功"

# 添加软件源
sources_list="/etc/apt/sources.list.d/xanmod-release.list"
log_info "配置 XanMod 软件源..."
echo "deb [signed-by=$keyring_path] http://deb.xanmod.org $DEBIAN_CODENAME main" | tee "$sources_list"

# 检测 CPU 微架构级别
log_info "检测 CPU 微架构级别..."

# 按 x86-64 psABI 的定义检查整组指令集，只看到 avx2 / avx512 字样并不够
# （部分虚拟机会暴露 avx2 却缺 bmi2/fma，装 v3 内核后无法启动）
detect_cpu_level() {
  local flags
  flags=" $(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2) "
  has() {
    local f
    for f in "$@"; do [[ $flags == *" $f "* ]] || return 1; done
  }
  if ! has cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; then
    echo "x64v1"
  elif ! has avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; then
    echo "x64v2"
  elif ! has avx512f avx512bw avx512cd avx512dq avx512vl; then
    echo "x64v3"
  else
    echo "x64v4"
  fi
}

CPU_LEVEL=$(detect_cpu_level)
log_info "检测到 CPU 级别: $CPU_LEVEL"

# 让用户选择内核分支
echo ""
echo "请选择内核分支:"
echo "1) LTS (长期支持，推荐用于生产环境)"
echo "2) MAIN (主线，最新特性)"
echo "3) RT (实时内核，用于低延迟场景)"
kernel_choice=''
if [ -r /dev/tty ]; then
  read -r -p "请输入选项 [1-3] (默认: 1): " kernel_choice </dev/tty || true
fi

case "${kernel_choice:-1}" in
  1) BRANCH="lts" ;;
  2) BRANCH="main" ;;
  3) BRANCH="rt" ;;
  *) log_warn "无效选择，使用默认 LTS 内核"; BRANCH="lts" ;;
esac

log_info "更新软件包列表..."
apt-get update

# 并非每个分支都提供所有级别（例如 x64v4 已停止单独构建），
# 依次尝试 本级别 -> 更低级别 -> LTS，选第一个软件源里真实存在的包
pkg_name() {
  if [ "$1" = "main" ]; then echo "linux-xanmod-$2"; else echo "linux-xanmod-$1-$2"; fi
}
levels=()
for lv in x64v4 x64v3 x64v2 x64v1; do
  [[ ${#levels[@]} -gt 0 || $lv == "$CPU_LEVEL" ]] && levels+=("$lv")
done

KERNEL_PACKAGE=''
for br in "$BRANCH" lts; do
  for lv in "${levels[@]}"; do
    candidate=$(pkg_name "$br" "$lv")
    if apt-cache show "$candidate" >/dev/null 2>&1; then
      KERNEL_PACKAGE=$candidate
      break 2
    fi
  done
done

if [ -z "$KERNEL_PACKAGE" ]; then
  log_error "软件源里找不到适合 $CPU_LEVEL 的 XanMod 内核包"
  log_error "请检查 $sources_list 以及 $DEBIAN_CODENAME 是否受 XanMod 支持"
  exit 1
fi
[ "$KERNEL_PACKAGE" = "$(pkg_name "$BRANCH" "$CPU_LEVEL")" ] \
  || log_warn "软件源中没有 $(pkg_name "$BRANCH" "$CPU_LEVEL")，改用 $KERNEL_PACKAGE"

log_info "将安装: $KERNEL_PACKAGE"

log_info "正在安装 XanMod 内核..."
if apt-get "${APT_OPTS[@]}" install -y "$KERNEL_PACKAGE"; then
  log_info "✓ XanMod 内核安装成功"
else
  log_error "内核安装失败"
  log_error "请检查错误信息并重试"
  exit 1
fi

# 应用网络优化配置
log_info "正在应用网络优化配置..."

sysctl_conf="/etc/sysctl.d/99-xanmod-optimizations.conf"

cat > "$sysctl_conf" <<'EOF'
# XanMod 网络优化配置

# TCP BBR 拥塞控制算法
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq_pie

# 网络缓冲区大小
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536

# TCP 缓冲区调优
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864

# 连接队列
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

# TCP 优化
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_max_tw_buckets = 16384
net.ipv4.tcp_max_orphans = 16384
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3

# 路由优化
net.ipv4.route.gc_timeout = 100

# 文件系统
fs.file-max = 1000000
fs.inotify.max_user_instances = 256
fs.inotify.max_user_watches = 524288

# 虚拟内存
vm.swappiness = 60
vm.vfs_cache_pressure = 50
EOF

# 应用配置。当前还在旧内核上，个别参数可能暂不支持，失败不应中断脚本，重启后会自动生效
if sysctl -p "$sysctl_conf" >/dev/null; then
  log_info "✓ 网络优化配置已应用"
else
  log_warn "部分参数在当前内核上未能应用，重启进入 XanMod 内核后会自动生效"
fi

# 显示已安装的内核
log_info "当前已安装的内核:"
dpkg -l | grep -E 'linux-image|linux-xanmod' | grep ^ii || true

# 显示当前内核
log_info "当前运行的内核: $(uname -r)"

# 完成提示
echo ""
echo "=========================================="
log_info "✓ XanMod 内核安装完成！"
echo "=========================================="
echo ""
echo "已安装的包: $KERNEL_PACKAGE"
echo "优化配置: $sysctl_conf"
echo ""
log_warn "重要: 需要重启系统以使用新内核"
echo ""

# 重启提示
ask "是否现在重启系统？(y/n) "
case "$REPLY" in
  y|Y)
    log_info "系统将在 5 秒后重启..."
    sleep 5
    reboot
    ;;
  *)
    log_info "请稍后手动重启系统"
    echo "重启后可以使用以下命令验证:"
    echo "  uname -r"
    echo "  cat /proc/version"
    ;;
esac
__LT_PAYLOAD_END__
}

payload_ssh_check_sh() {
cat <<'__LT_PAYLOAD_END__'
#!/bin/bash
#
# 检查 sshd 是否受 regreSSHion（CVE-2024-6387）影响
#
# 受影响的上游版本：< 4.4p1，以及 8.5p1 <= 版本 < 9.8p1
# Debian / Ubuntu 会把补丁移植回旧版本号，所以先按发行版的软件包版本判断。
#
# 返回码（与旧版保持一致）：
#   0 = 不受影响   1 = 受影响   2 = 未找到 sshd/ssh   3 = 无法解析版本号

# 各发行版里修复该漏洞的 openssh-server 版本
declare -A FIXED_PKG=(
  [debian:bookworm]="1:9.2p1-2+deb12u3"
  [ubuntu:jammy]="1:8.9p1-3ubuntu0.10"
  [ubuntu:noble]="1:9.6p1-3ubuntu13.3"
)

# 1) 发行版软件包版本（有补丁移植信息，最准确）
if [ -r /etc/os-release ] && command -v dpkg-query >/dev/null 2>&1; then
  distro=$( . /etc/os-release; echo "${ID:-}:${VERSION_CODENAME:-}" )
  pkg_ver=$(dpkg-query -W -f='${Version}' openssh-server 2>/dev/null)
  fixed=${FIXED_PKG[$distro]:-}
  if [ -n "$pkg_ver" ] && [ -n "$fixed" ]; then
    if dpkg --compare-versions "$pkg_ver" lt "$fixed"; then
      echo "受影响：openssh-server $pkg_ver（$distro 的修复版本为 $fixed），请执行 apt update && apt install openssh-server"
      exit 1
    fi
    echo "不受影响：openssh-server $pkg_ver（$distro 已包含修复）"
    exit 0
  fi
fi

# 2) 退回按上游版本号判断；优先看服务端 sshd，没有再看 ssh 客户端
sshd_bin=$(command -v sshd 2>/dev/null || true)
[ -z "$sshd_bin" ] && [ -x /usr/sbin/sshd ] && sshd_bin=/usr/sbin/sshd
if [ -n "$sshd_bin" ]; then
  # 旧版 sshd 不认识 -V，但会在用法说明的第一行打印版本号
  version_str=$("$sshd_bin" -V 2>&1)
elif command -v ssh >/dev/null 2>&1; then
  version_str=$(ssh -V 2>&1)
else
  echo "未找到 sshd 或 ssh"
  exit 2
fi

if [[ ! $version_str =~ OpenSSH_([0-9]+)\.([0-9]+) ]]; then
  echo "无法解析版本号：$version_str"
  exit 3
fi
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
v=$(( major * 100 + minor ))

if (( v < 404 || (v >= 805 && v < 908) )); then
  echo "受影响：OpenSSH $major.$minor（若发行版已移植补丁，这可能是误报）"
  exit 1
fi
echo "不受影响：OpenSSH $major.$minor"
exit 0
__LT_PAYLOAD_END__
}

payload_update_motd_20_DSH() {
cat <<'__LT_PAYLOAD_END__'
#!/bin/sh
# /etc/update-motd.d/20-DSH
# Prints the ASCII logo.  Install:
#   install -m 0755 20-DSH /etc/update-motd.d/20-DSH
#   run-parts /etc/update-motd.d          # preview
# 256-colour half-block art, 40x20
cat <<'DSH_LOGO'
           [38;5;24m▄[38;5;24m▄[38;5;25m▄[38;5;61m▄[38;5;24m▄[38;5;24m▄[0m                       
        [38;5;24m▄[38;5;24m▀[38;5;24m▀[38;5;24m▀[38;5;24m▀[38;5;24m▀[38;5;24m▀[38;5;61m[48;5;18m▀[38;5;61m[48;5;24m▀[38;5;24m[48;5;61m▀[0m                      
       [38;5;23m▀[0m   [38;5;252m▄[38;5;231m▄[38;5;188m[48;5;231m▀[38;5;255m[48;5;231m▀[38;5;254m[48;5;231m▀[38;5;60m[48;5;252m▀[38;5;25m[48;5;61m▀[38;5;109m[48;5;251m▀[38;5;255m[48;5;231m▀[38;5;254m[48;5;255m▀[38;5;254m[48;5;231m▀[38;5;251m[48;5;231m▀[0m[38;5;250m▄[0m                
       [38;5;253m▄[38;5;252m[48;5;231m▀[38;5;254m[48;5;231m▀[38;5;251m[48;5;231m▀[38;5;254m[48;5;252m▀[38;5;231m[48;5;251m▀[38;5;231m[48;5;103m▀[38;5;255m[48;5;61m▀[38;5;254m[48;5;61m▀[38;5;188m[48;5;61m▀[38;5;146m[48;5;103m▀[0m[38;5;254m█[38;5;255m█[38;5;255m█[48;5;231m▀[38;5;255m[48;5;253m▀[0m[38;5;254m█[38;5;252m[48;5;255m▀[38;5;251m[48;5;231m▀[38;5;254m[48;5;231m▀[0m[38;5;231m▄[38;5;251m▄[0m           
     [38;5;253m▄[38;5;250m[48;5;251m▀[38;5;231m[48;5;253m▀[38;5;255m[48;5;146m▀[38;5;188m[48;5;61m▀[38;5;110m[48;5;24m▀[38;5;61m[48;5;25m▀[38;5;24m[48;5;61m▀[38;5;25m[48;5;24m▀[38;5;24m[48;5;17m▀[0m[38;5;18m█[38;5;17m[48;5;24m▀[38;5;18m[48;5;24m▀[38;5;60m[48;5;24m▀[38;5;61m[48;5;24m▀[38;5;67m[48;5;24m▀[38;5;104m[48;5;24m▀[38;5;252m[48;5;24m▀[38;5;254m[48;5;61m▀[38;5;254m[48;5;251m▀[0m[38;5;255m█[38;5;255m█[38;5;255m█[38;5;231m[48;5;255m▀[0m           
   [38;5;254m▄[38;5;255m[48;5;231m▀[38;5;231m[48;5;110m▀[38;5;251m[48;5;61m▀[38;5;61m[48;5;25m▀[38;5;24m[48;5;61m▀[0m[38;5;25m█[38;5;61m█[38;5;61m[48;5;24m▀[0m[38;5;24m█[38;5;18m[48;5;25m▀[38;5;24m[48;5;61m▀[0m[38;5;25m█[38;5;61m█[38;5;61m█[38;5;61m██[38;5;61m█[38;5;24m[48;5;61m▀[38;5;17m[48;5;25m▀[0m[38;5;18m█[38;5;24m[48;5;24m▀[38;5;103m[48;5;24m▀[38;5;255m[48;5;67m▀[0m[38;5;255m█[38;5;253m█[38;5;145m[48;5;254m▀[0m[38;5;231m▄[38;5;252m▄[0m        
 [38;5;17m▄[38;5;237m[48;5;238m▀[38;5;251m[48;5;61m▀[38;5;103m[48;5;24m▀[38;5;24m[48;5;24m▀[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;25m█[38;5;24m█[38;5;24m[48;5;25m▀[0m[38;5;25m█[38;5;61m█[38;5;25m[48;5;61m▀[38;5;61m[48;5;62m▀[38;5;25m[48;5;61m▀[0m[38;5;61m████[38;5;25m█[38;5;61m█[38;5;24m█[38;5;24m[48;5;24m▀[38;5;60m[48;5;24m▀[38;5;24m[48;5;61m▀[38;5;67m[48;5;24m▀[38;5;255m[48;5;110m▀[38;5;255m[48;5;231m▀[0m[38;5;255m█[38;5;231m█[38;5;253m▄[0m       
[38;5;17m[48;5;17m▀[38;5;17m[48;5;24m▀[38;5;24m[48;5;61m▀[38;5;25m[48;5;18m▀[38;5;24m[48;5;61m▀[38;5;61m[48;5;61m▀[38;5;61m[48;5;61m▀[0m[38;5;25m█[38;5;25m█[38;5;24m█[38;5;24m█[38;5;61m█[38;5;61m[48;5;24m▀[0m[38;5;24m█[38;5;61m█[38;5;62m█[38;5;61m█[38;5;61m[48;5;62m▀[38;5;25m[48;5;61m▀[38;5;25m[48;5;61m▀[0m[38;5;25m█[38;5;25m█[38;5;25m█[38;5;25m█[38;5;61m█[38;5;24m[48;5;24m▀[0m[38;5;24m█[38;5;25m█[38;5;61m[48;5;24m▀[38;5;253m[48;5;103m▀[38;5;255m[48;5;254m▀[38;5;255m[48;5;252m▀[38;5;103m[48;5;103m▀[0m       
[38;5;17m[48;5;24m▀[0m[38;5;24m█[38;5;24m[48;5;17m▀[38;5;24m[48;5;25m▀[0m[38;5;61m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;24m█[38;5;25m█[38;5;61m[48;5;24m▀[38;5;24m[48;5;102m▀[38;5;60m[48;5;139m▀[38;5;61m[48;5;25m▀[38;5;61m[48;5;61m▀[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;61m█[38;5;68m[48;5;61m▀[0m[38;5;61m█[38;5;24m█[38;5;24m█[38;5;25m█[38;5;61m█[38;5;25m█[38;5;24m█[38;5;25m█[38;5;24m█[38;5;61m[48;5;24m▀[38;5;253m[48;5;146m▀[38;5;254m[48;5;231m▀[0m[38;5;231m█[38;5;102m[48;5;103m▀[0m      
[38;5;24m[48;5;61m▀[0m[38;5;24m█[38;5;24m[48;5;25m▀[0m[38;5;61m█[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;25m█[38;5;24m█[38;5;60m█[38;5;25m[48;5;61m▀[38;5;61m[48;5;223m▀[38;5;223m[48;5;224m▀[38;5;139m[48;5;145m▀[0m[38;5;25m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;61m[48;5;25m▀[38;5;61m[48;5;61m▀[38;5;60m[48;5;103m▀[0m[38;5;25m█[38;5;25m█[38;5;25m█[38;5;24m█[38;5;24m█[38;5;61m█[38;5;24m█[38;5;103m[48;5;61m▀[38;5;255m[48;5;146m▀[38;5;255m[48;5;146m▀[38;5;61m[48;5;24m▀[38;5;17m[48;5;17m▀[0m     
[38;5;103m[48;5;61m▀[38;5;24m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;25m█[38;5;61m█[38;5;24m█[38;5;24m[48;5;96m▀[38;5;61m[48;5;248m▀[38;5;251m[48;5;224m▀[38;5;224m[48;5;224m▀[38;5;230m[48;5;224m▀[38;5;146m[48;5;251m▀[38;5;25m[48;5;61m▀[38;5;61m[48;5;67m▀[0m[38;5;61m█[48;5;61m▀[0m[38;5;61m█[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;25m[48;5;61m▀[38;5;103m[48;5;252m▀[38;5;181m[48;5;224m▀[38;5;25m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;24m█[38;5;24m█[38;5;25m█[38;5;25m█[38;5;24m█[38;5;68m[48;5;61m▀[38;5;68m[48;5;68m▀[38;5;24m[48;5;68m▀[38;5;61m[48;5;68m▀[38;5;67m[48;5;75m▀[0m    
[38;5;17m[48;5;24m▀[0m[38;5;25m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;25m█[38;5;61m[48;5;145m▀[38;5;223m[48;5;224m▀[38;5;253m[48;5;224m▀[38;5;255m[48;5;224m▀[0m[38;5;181m▀[0m [38;5;251m[48;5;224m▀[38;5;67m[48;5;146m▀[38;5;103m[48;5;250m▀[38;5;61m[48;5;67m▀[0m[38;5;61m█[38;5;61m█[38;5;61m[48;5;61m▀[38;5;61m[48;5;103m▀[38;5;103m[48;5;188m▀[0m[38;5;224m█[38;5;224m█[38;5;248m[48;5;188m▀[38;5;25m[48;5;61m▀[0m[38;5;61m█[38;5;25m█[38;5;24m█[38;5;61m██[38;5;24m█[38;5;61m█[38;5;68m[48;5;67m▀[38;5;61m[48;5;17m▀[38;5;68m[48;5;61m▀[38;5;68m[48;5;68m▀[0m    
[38;5;24m[48;5;18m▀[38;5;61m[48;5;24m▀[38;5;61m[48;5;24m▀[0m[38;5;61m█[38;5;61m█[38;5;61m█[38;5;146m[48;5;146m▀[0m[38;5;224m█[38;5;255m█[38;5;252m[48;5;181m▀[0m [38;5;181m▄[38;5;224m[48;5;255m▀[38;5;224m[48;5;224m▀[38;5;253m[48;5;224m▀[38;5;103m[48;5;252m▀[38;5;61m[48;5;252m▀[38;5;61m[48;5;103m▀[38;5;250m[48;5;252m▀[38;5;188m[48;5;224m▀[0m[38;5;224m█[38;5;224m[48;5;181m▀[0m[38;5;224m▀[38;5;224m█[38;5;103m[48;5;253m▀[38;5;25m[48;5;61m▀[38;5;60m[48;5;24m▀[0m[38;5;24m█[38;5;61m█[38;5;61m██[38;5;24m[48;5;17m▀[0m[38;5;17m█[38;5;17m[48;5;17m▀[0m[38;5;17m█[38;5;24m[48;5;17m▀[0m    
[38;5;18m[48;5;24m▀[38;5;18m[48;5;24m▀[38;5;24m[48;5;24m▀[38;5;61m[48;5;61m▀[38;5;68m[48;5;61m▀[38;5;61m[48;5;68m▀[38;5;68m[48;5;139m▀[38;5;224m[48;5;181m▀[38;5;224m[48;5;217m▀[38;5;252m[48;5;224m▀[0m[38;5;224m▄[38;5;224m[48;5;224m▀[0m[38;5;224m█[38;5;224m█[38;5;224m█[38;5;224m█[38;5;224m█[38;5;224m█[38;5;224m[48;5;224m▀[0m[38;5;224m█[38;5;224m[48;5;187m▀[0m  [38;5;224m[48;5;255m▀[0m[38;5;230m█[38;5;145m[48;5;181m▀[38;5;24m[48;5;24m▀[0m[38;5;61m█[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;61m[48;5;25m▀[38;5;24m[48;5;60m▀[38;5;17m[48;5;67m▀[38;5;17m[48;5;238m▀[38;5;17m[48;5;17m▀[0m[38;5;17m█[38;5;17m[48;5;17m▀[0m   
[38;5;61m█[38;5;24m[48;5;61m▀[38;5;61m[48;5;67m▀[0m[38;5;61m█[38;5;24m[48;5;25m▀[38;5;103m[48;5;60m▀[38;5;224m[48;5;224m▀[38;5;217m[48;5;224m▀[38;5;217m[48;5;224m▀[38;5;223m[48;5;224m▀[0m[38;5;224m█[38;5;224m███████[38;5;224m█[38;5;255m█[38;5;181m▄[0m [38;5;181m[48;5;224m▀[38;5;255m[48;5;224m▀[0m[38;5;224m█[38;5;251m[48;5;103m▀[38;5;25m[48;5;61m▀[38;5;61m[48;5;68m▀[0m[38;5;61m█[38;5;61m█[38;5;24m[48;5;24m▀[38;5;61m[48;5;60m▀[38;5;146m[48;5;146m▀[38;5;146m[48;5;252m▀[38;5;60m[48;5;146m▀[38;5;17m[48;5;103m▀[38;5;17m[48;5;60m▀[38;5;17m[48;5;17m▀[0m[38;5;17m▄[0m 
[38;5;61m█[38;5;24m█[38;5;61m[48;5;24m▀[0m[38;5;68m█[38;5;61m[48;5;68m▀[38;5;24m[48;5;61m▀[38;5;103m[48;5;24m▀[38;5;230m[48;5;145m▀[0m[38;5;224m█[38;5;224m█[38;5;224m█████████[38;5;224m█[38;5;224m[48;5;217m▀[38;5;224m[48;5;217m▀[38;5;224m[48;5;217m▀[38;5;224m[48;5;250m▀[38;5;251m[48;5;68m▀[0m[38;5;67m█[38;5;68m█[38;5;68m█[38;5;61m█[38;5;61m[48;5;24m▀[38;5;24m[48;5;24m▀[38;5;24m[48;5;24m▀[0m[38;5;17m█[38;5;103m[48;5;17m▀[0m[38;5;252m▀[38;5;146m▀[38;5;146m▀[38;5;60m▀[38;5;17m▀[0m 
[38;5;61m[48;5;61m▀[38;5;24m[48;5;68m▀[38;5;17m[48;5;61m▀[38;5;61m[48;5;68m▀[0m[38;5;68m█[38;5;68m[48;5;68m▀[38;5;103m[48;5;110m▀[38;5;252m[48;5;253m▀[38;5;188m[48;5;252m▀[38;5;188m[48;5;103m▀[38;5;224m[48;5;249m▀[38;5;224m[48;5;224m▀[0m[38;5;224m█[38;5;224m██████[38;5;224m█[38;5;223m[48;5;224m▀[38;5;217m[48;5;224m▀[38;5;181m[48;5;224m▀[38;5;68m[48;5;146m▀[0m[38;5;68m█[38;5;68m[48;5;61m▀[38;5;68m[48;5;24m▀[38;5;61m[48;5;24m▀[38;5;25m[48;5;24m▀[38;5;24m[48;5;61m▀[0m[38;5;61m█[38;5;24m[48;5;25m▀[38;5;24m[48;5;61m▀[38;5;24m[48;5;25m▀[38;5;17m[48;5;24m▀[0m     
[38;5;24m[48;5;17m▀[38;5;67m[48;5;24m▀[0m[38;5;68m█[38;5;68m█[38;5;68m█[38;5;68m█[38;5;110m[48;5;110m▀[0m[38;5;255m█[38;5;146m[48;5;103m▀[38;5;60m[48;5;17m▀[38;5;103m[48;5;17m▀[38;5;217m[48;5;102m▀[38;5;223m[48;5;216m▀[38;5;224m[48;5;217m▀[38;5;224m[48;5;181m▀[38;5;224m[48;5;248m▀[38;5;224m[48;5;103m▀[38;5;224m[48;5;145m▀[38;5;224m[48;5;248m▀[38;5;224m[48;5;60m▀[38;5;224m[48;5;238m▀[38;5;145m[48;5;24m▀[38;5;60m[48;5;25m▀[38;5;24m[48;5;61m▀[38;5;25m[48;5;68m▀[0m[38;5;24m█[38;5;24m[48;5;24m▀[38;5;24m[48;5;61m▀[0m[38;5;24m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;25m█[38;5;61m[48;5;24m▀[38;5;61m[48;5;24m▀[38;5;24m[48;5;61m▀[0m[38;5;24m▄[0m   
[38;5;24m[48;5;24m▀[0m[38;5;68m█[38;5;68m█[38;5;68m[48;5;61m▀[38;5;68m[48;5;110m▀[38;5;68m[48;5;146m▀[38;5;188m[48;5;253m▀[38;5;255m[48;5;231m▀[0m[38;5;249m█[38;5;17m[48;5;17m▀[38;5;17m[48;5;17m▀[38;5;60m[48;5;60m▀[38;5;109m[48;5;60m▀[38;5;59m[48;5;17m▀[38;5;60m[48;5;17m▀[38;5;60m[48;5;17m▀[38;5;103m[48;5;248m▀[38;5;146m[48;5;254m▀[38;5;146m[48;5;251m▀[38;5;24m[48;5;68m▀[38;5;25m[48;5;68m▀[0m[38;5;68m█[38;5;68m█[38;5;68m[48;5;68m▀[38;5;61m[48;5;24m▀[38;5;24m[48;5;61m▀[38;5;61m[48;5;61m▀[38;5;61m[48;5;24m▀[0m[38;5;24m█[38;5;61m[48;5;62m▀[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;24m[48;5;61m▀[0m [38;5;24m▀[38;5;61m[48;5;61m▀[38;5;24m[48;5;61m▀[0m  
[38;5;18m█[38;5;68m[48;5;24m▀[38;5;67m[48;5;61m▀[38;5;17m[48;5;17m▀[38;5;145m[48;5;60m▀[0m[38;5;254m█[38;5;255m[48;5;231m▀[38;5;248m[48;5;60m▀[38;5;238m[48;5;17m▀[38;5;17m[48;5;239m▀[38;5;238m[48;5;252m▀[38;5;251m[48;5;231m▀[38;5;239m[48;5;60m▀[0m[38;5;17m█[38;5;17m[48;5;60m▀[38;5;103m[48;5;255m▀[0m[38;5;254m█[38;5;255m[48;5;253m▀[38;5;110m[48;5;67m▀[0m[38;5;68m█[38;5;68m█[38;5;68m█[38;5;68m█[38;5;68m[48;5;68m▀[38;5;61m[48;5;68m▀[38;5;61m[48;5;67m▀[38;5;61m[48;5;24m▀[0m[38;5;24m█[38;5;24m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;61m[48;5;68m▀[38;5;61m[48;5;61m▀[38;5;24m[48;5;61m▀[38;5;17m[48;5;24m▀[0m[38;5;24m█[38;5;61m[48;5;24m▀[0m  
DSH_LOGO
__LT_PAYLOAD_END__
}

payload_update_motd_20_DSH_32() {
cat <<'__LT_PAYLOAD_END__'
#!/bin/sh
# /etc/update-motd.d/20-DSH-32
# Prints the ASCII logo.  Install:
#   install -m 0755 20-DSH-32 /etc/update-motd.d/20-DSH-32
#   run-parts /etc/update-motd.d          # preview
# 256-colour half-block art, compact 32x16
cat <<'DSH_LOGO'
        [38;5;24m▄[38;5;24m▄[38;5;61m▄[38;5;61m▄[38;5;61m▄[38;5;24m▄[0m                  
      [38;5;24m█[38;5;24m▀[0m  [38;5;254m▄[38;5;255m▄[38;5;24m[48;5;250m▀[38;5;61m[48;5;24m▀[38;5;24m[48;5;61m▀[0m[38;5;254m▄[38;5;254m▄[38;5;253m▄[0m              
      [38;5;188m▄[38;5;255m▄[38;5;253m▄[38;5;253m[48;5;255m▀[38;5;231m[48;5;254m▀[48;5;252m▀[38;5;231m[48;5;146m▀[38;5;140m[48;5;146m▀[38;5;104m[48;5;253m▀[0m[38;5;231m█[38;5;255m█[38;5;231m[48;5;255m▀[38;5;253m[48;5;254m▀[0m[38;5;188m▄[38;5;253m▄[38;5;255m▄[0m          
    [38;5;188m▄[38;5;252m[48;5;188m▀[38;5;231m[48;5;252m▀[38;5;255m[48;5;61m▀[38;5;251m[48;5;25m▀[38;5;67m[48;5;25m▀[38;5;61m[48;5;24m▀[38;5;24m[48;5;24m▀[38;5;24m[48;5;24m▀[0m[38;5;24m█[38;5;61m[48;5;24m▀[38;5;110m[48;5;24m▀[38;5;146m[48;5;24m▀[38;5;188m[48;5;24m▀[38;5;254m[48;5;61m▀[38;5;255m[48;5;146m▀[0m[38;5;255m█[38;5;231m█[38;5;255m█[38;5;251m▄[0m        
  [38;5;251m▄[38;5;255m[48;5;255m▀[38;5;231m[48;5;61m▀[38;5;103m[48;5;24m▀[38;5;25m[48;5;61m▀[38;5;25m[48;5;61m▀[0m[38;5;61m█[38;5;24m[48;5;24m▀[38;5;24m[48;5;24m▀[38;5;24m[48;5;61m▀[0m[38;5;25m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;24m[48;5;61m▀[38;5;17m[48;5;24m▀[38;5;24m[48;5;24m▀[38;5;103m[48;5;24m▀[38;5;255m[48;5;67m▀[0m[38;5;254m█[38;5;146m[48;5;255m▀[0m[38;5;231m▄[38;5;252m▄[0m      
[38;5;17m▄[38;5;17m[48;5;17m▀[38;5;61m[48;5;24m▀[38;5;61m[48;5;24m▀[38;5;24m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;25m█[38;5;24m█[38;5;25m█[38;5;61m█[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;25m[48;5;61m▀[0m[38;5;25m█[38;5;61m█[38;5;25m█[38;5;25m█[38;5;61m█[38;5;24m[48;5;25m▀[0m[38;5;24m█[38;5;24m[48;5;61m▀[38;5;103m[48;5;24m▀[38;5;231m[48;5;252m▀[0m[38;5;255m█[38;5;255m[48;5;252m▀[0m      
[38;5;17m[48;5;24m▀[0m[38;5;24m█[38;5;24m[48;5;24m▀[38;5;24m[48;5;61m▀[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;25m█[38;5;24m█[38;5;61m[48;5;25m▀[38;5;24m[48;5;60m▀[38;5;24m[48;5;61m▀[38;5;61m[48;5;61m▀[38;5;62m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;61m[48;5;62m▀[38;5;61m[48;5;61m▀[0m[38;5;25m█[38;5;25m█[38;5;61m█[38;5;24m█[38;5;24m█[38;5;24m█[38;5;67m[48;5;61m▀[38;5;254m[48;5;188m▀[38;5;182m[48;5;231m▀[38;5;60m[48;5;251m▀[0m     
[38;5;24m[48;5;61m▀[0m[38;5;24m█[38;5;24m[48;5;61m▀[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;24m█[38;5;24m█[38;5;25m[48;5;61m▀[38;5;60m[48;5;223m▀[38;5;217m[48;5;224m▀[38;5;61m[48;5;61m▀[0m[38;5;25m█[38;5;61m█[38;5;61m█[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;61m[48;5;25m▀[38;5;24m[48;5;61m▀[38;5;24m[48;5;60m▀[0m[38;5;61m█[38;5;25m█[38;5;24m█[38;5;61m█[38;5;24m█[38;5;146m[48;5;61m▀[38;5;231m[48;5;252m▀[38;5;146m[48;5;61m▀[0m[38;5;17m█[0m    
[38;5;103m[48;5;60m▀[38;5;24m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;61m█[38;5;24m[48;5;60m▀[38;5;61m[48;5;250m▀[38;5;250m[48;5;255m▀[38;5;230m[48;5;188m▀[38;5;224m[48;5;224m▀[38;5;61m[48;5;104m▀[38;5;61m[48;5;67m▀[38;5;61m[48;5;61m▀[38;5;61m[48;5;61m▀[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;25m[48;5;67m▀[38;5;181m[48;5;230m▀[38;5;103m[48;5;249m▀[0m[38;5;25m█[38;5;61m█[38;5;24m█[38;5;24m█[38;5;61m█[38;5;25m█[38;5;68m[48;5;67m▀[38;5;61m[48;5;68m▀[38;5;61m[48;5;68m▀[38;5;67m[48;5;68m▀[0m   
[38;5;24m[48;5;24m▀[0m[38;5;61m█[38;5;61m█[38;5;61m█[38;5;61m[48;5;61m▀[38;5;181m[48;5;253m▀[0m[38;5;224m█[38;5;224m[48;5;224m▀[0m [38;5;252m▄[38;5;146m[48;5;255m▀[38;5;103m[48;5;252m▀[38;5;67m[48;5;103m▀[38;5;67m[48;5;61m▀[38;5;61m[48;5;103m▀[38;5;61m[48;5;252m▀[38;5;251m[48;5;224m▀[0m[38;5;224m█[38;5;224m[48;5;230m▀[38;5;61m[48;5;103m▀[38;5;61m[48;5;25m▀[0m[38;5;24m█[38;5;24m█[38;5;61m█[38;5;24m█[38;5;67m[48;5;24m▀[38;5;25m[48;5;17m▀[38;5;61m[48;5;24m▀[38;5;68m[48;5;24m▀[0m   
[38;5;24m█[38;5;24m█[38;5;61m[48;5;24m▀[38;5;61m[48;5;68m▀[38;5;61m[48;5;68m▀[38;5;252m[48;5;248m▀[38;5;231m[48;5;224m▀[38;5;252m[48;5;224m▀[0m[38;5;252m▄[38;5;224m[48;5;224m▀[38;5;255m[48;5;224m▀[0m[38;5;224m█[38;5;188m[48;5;224m▀[38;5;146m[48;5;224m▀[38;5;146m[48;5;224m▀[0m[38;5;224m█[38;5;224m[48;5;252m▀[0m [38;5;224m[48;5;252m▀[38;5;255m[48;5;231m▀[38;5;61m[48;5;248m▀[0m[38;5;24m█[38;5;61m█[38;5;61m█[38;5;61m█[38;5;17m[48;5;60m▀[0m[38;5;17m█[38;5;237m█[38;5;17m[48;5;238m▀[0m   
[38;5;24m█[38;5;24m[48;5;61m▀[38;5;61m[48;5;61m▀[0m[38;5;25m█[38;5;110m[48;5;103m▀[38;5;217m[48;5;224m▀[38;5;217m[48;5;224m▀[38;5;223m[48;5;224m▀[38;5;255m[48;5;224m▀[0m[38;5;224m███[38;5;224m█[38;5;224m█[38;5;224m█[38;5;255m█[0m [38;5;181m▄[38;5;224m[48;5;255m▀[0m[38;5;230m█[38;5;249m[48;5;103m▀[38;5;25m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;24m[48;5;24m▀[38;5;103m[48;5;103m▀[38;5;103m[48;5;252m▀[38;5;238m[48;5;146m▀[38;5;17m[48;5;103m▀[38;5;17m[48;5;239m▀[0m[38;5;17m▄[0m 
[38;5;61m█[38;5;24m[48;5;17m▀[38;5;68m[48;5;24m▀[38;5;61m[48;5;68m▀[38;5;24m[48;5;61m▀[38;5;248m[48;5;60m▀[38;5;224m[48;5;253m▀[0m[38;5;224m█[38;5;224m█[38;5;224m██████[38;5;224m█[38;5;224m[48;5;217m▀[38;5;224m[48;5;217m▀[38;5;224m[48;5;146m▀[38;5;251m[48;5;68m▀[38;5;68m[48;5;68m▀[0m[38;5;68m█[38;5;61m█[38;5;61m[48;5;24m▀[38;5;24m[48;5;24m▀[38;5;17m[48;5;24m▀[38;5;60m[48;5;18m▀[38;5;146m[48;5;17m▀[0m[38;5;251m▀[38;5;103m▀[38;5;17m▀[0m 
[38;5;67m[48;5;24m▀[38;5;24m[48;5;68m▀[38;5;61m[48;5;68m▀[0m[38;5;68m█[38;5;68m█[38;5;146m[48;5;146m▀[0m[38;5;188m█[38;5;250m[48;5;61m▀[38;5;252m[48;5;103m▀[38;5;224m[48;5;217m▀[38;5;224m[48;5;224m▀[0m[38;5;224m██[38;5;224m█[38;5;224m█[38;5;224m█[38;5;224m[48;5;224m▀[38;5;224m[48;5;247m▀[38;5;251m[48;5;60m▀[38;5;68m[48;5;25m▀[38;5;68m[48;5;24m▀[38;5;61m[48;5;24m▀[0m[38;5;24m█[38;5;61m█[38;5;61m█[38;5;24m█[38;5;60m█[38;5;17m[48;5;61m▀[0m[38;5;24m▄[0m   
[38;5;17m[48;5;61m▀[38;5;61m[48;5;68m▀[0m[38;5;68m█[38;5;68m[48;5;68m▀[38;5;68m[48;5;110m▀[38;5;188m[48;5;255m▀[38;5;251m[48;5;255m▀[38;5;17m[48;5;237m▀[38;5;237m[48;5;17m▀[38;5;138m[48;5;66m▀[38;5;181m[48;5;60m▀[38;5;181m[48;5;237m▀[38;5;248m[48;5;60m▀[38;5;103m[48;5;146m▀[38;5;249m[48;5;252m▀[38;5;60m[48;5;61m▀[38;5;24m[48;5;68m▀[38;5;24m[48;5;68m▀[38;5;61m[48;5;68m▀[38;5;67m[48;5;61m▀[0m[38;5;24m█[38;5;24m[48;5;61m▀[0m[38;5;25m█[38;5;61m[48;5;61m▀[0m[38;5;61m█[38;5;61m█[38;5;24m[48;5;61m▀[0m[38;5;24m▀[38;5;61m[48;5;24m▀[38;5;24m[48;5;61m▀[0m  
[38;5;24m[48;5;18m▀[38;5;68m[48;5;61m▀[38;5;24m[48;5;24m▀[38;5;103m[48;5;60m▀[38;5;254m[48;5;255m▀[38;5;254m[48;5;252m▀[38;5;103m[48;5;17m▀[38;5;17m[48;5;17m▀[38;5;238m[48;5;252m▀[38;5;245m[48;5;251m▀[38;5;17m[48;5;17m▀[38;5;17m[48;5;60m▀[38;5;60m[48;5;255m▀[0m[38;5;254m█[38;5;253m[48;5;146m▀[38;5;68m[48;5;68m▀[0m[38;5;68m█[38;5;68m█[38;5;68m█[38;5;61m[48;5;68m▀[0m[38;5;61m█[38;5;61m[48;5;24m▀[0m[38;5;24m█[38;5;61m█[38;5;61m█[38;5;61m[48;5;67m▀[38;5;61m[48;5;61m▀[38;5;24m[48;5;61m▀[0m[38;5;24m▄[38;5;61m[48;5;61m▀[0m[38;5;24m▀[0m 
DSH_LOGO
__LT_PAYLOAD_END__
}

payload_update_motd_20_DSH_mono() {
cat <<'__LT_PAYLOAD_END__'
#!/bin/sh
# /etc/update-motd.d/20-DSH-mono
# Prints the ASCII logo.  Install:
#   install -m 0755 20-DSH-mono /etc/update-motd.d/20-DSH-mono
#   run-parts /etc/update-motd.d          # preview
# colour-free grey-block art, 40x20 (works anywhere)
cat <<'DSH_LOGO'
           ░░░░░░
        ░░░░░░░░░░
       ░   █████▒░▓████▓
       ██████▓▓▓▓▓██████████▓
     █▓██▒▒░░░░░░░░░░▒▒▓█████
   ███▒░░░░░░░░░░░░░░░░░░▒▓██▓█▓
  ░▒▒░░░░░░░░░░▒░░░░░░░░░░░░▓████
 ░░░░░░░░░░░░░░▒▒░░░░░░░░░░░░▓██▒
░░░░░░░░░░░░▒░░░▒▒▒▒░░░░░░░░░░▓██▒
░░░░░░░░░░▓█▓░░░░░░░░░▒░░░░░░░▒█▓░
▒░░░░░░░▒███▓░▒░▒░░░░▓█░░░░░░░░▒▒░▒▒
░░░░░░▒███▓ █▒▓▒▒▒▒▒▓██▓░░░░░░░░▒░▒▒
░░░░░░▓██▓ ▓███▓▓▒▓█████▓░░░░░░░  ░░
░░░░▒▒▒██████████████  ██▓░░░░░░░░ ░
░░▒░░▒██████████████▓ ███▓░▒░░░▒▓▓▒░░
░░░▒▒░░▓████████████████▓▒▒▒░░░░ ░▓▓▓░
░░░▒▒▒▒█▓▓▓████████████▓▒▒░░░░░░░░
░░▒▒▒▒▓█▓░░▓▓██▓▓▓▓▓▒▒░░░░░░░░░░░░░░░
░▒▒▒▒▓██▓  ░▒░░░▓▓▓░▒▒▒▒░░░░░▒░░░░ ░░░
░░▒ ▒██▒  ▒█░ ░▓██▒▒▒▒▒▒▒▒░░░▒▒▒▒░░ ░░
DSH_LOGO
__LT_PAYLOAD_END__
}

payload_update_motd_20_DSH_mono_32() {
cat <<'__LT_PAYLOAD_END__'
#!/bin/sh
# /etc/update-motd.d/20-DSH-mono-32
# Prints the ASCII logo.  Install:
#   install -m 0755 20-DSH-mono-32 /etc/update-motd.d/20-DSH-mono-32
#   run-parts /etc/update-motd.d          # preview
# colour-free grey-block art, compact 32x16
cat <<'DSH_LOGO'
        ░░░░░░
      ░░  ██▒░░███
      ███████▓▓███████
    ███▓▒░░░░░░▒▒▒▓████▓
  ▓█▓▒░░░░░░░░░░░░░░▒▓███▓
  ░░░░░░░░░░▒░░░░░░░░░▒███
░░░░░░░░░░░░▒▒▒▒░░░░░░░▒██▒
░░░░░░░░▓█▒░░░░░░░░░░░░░▒█▒
▒░░░░░▒███▒▒▒▒▒░▒█▒░░░░░░▒▒▒▒
░░░░░▓██ ██▓▒▒▒▓███▒░░░░░░░░░
░░░▒▒▓███████████ ██▒░░░░░
░░░░▒███████████ ▓██▓░▒░░▒▓▒░░
░░░▒░▒████████████▓▓▒▒▒░░░░▒▓▓
░▒▒▒▒▓█▒▓████████▓▒▒░░░░░░░░░
░▒▒▒▒██  ▒▒▒▒▓▓▒░▒▒▒░░░░░░░░░░
░▒░▒██░ ▒▓ ░▓█▓▒▒▒▒▒░░░▒▒▒░░░░░
DSH_LOGO
__LT_PAYLOAD_END__
}

payload_update_motd_25_sysinfo() {
cat <<'__LT_PAYLOAD_END__'
#!/bin/sh
#
# /etc/update-motd.d/25-sysinfo
#
# 登录面板：系统概况 + 负载/内存/磁盘占用条 + 连接构成 + 流量 + 最近登录
#
# 安装：
#   install -m 0755 25-sysinfo /etc/update-motd.d/25-sysinfo
#   run-parts /etc/update-motd.d
#
# 设计约定（改样式时请一并遵守，否则很容易"看着怪"）：
#   * 标签一律 2 个汉字 = 显示宽度 4 列，所有行从同一列开始。
#   * 只用单宽度字符：条用 █ ░，箭头用 ↓ ↑。不用 emoji，不用 ─ │ ┌ 这类
#     "宽度歧义"字符——部分终端按 2 列渲染它们，会把整行挤到折行。
#   * 条只表达「占用率」（0–100% 有意义）：负载 / 内存 / 磁盘 / 交换。
#     连接数、构成比例没有"满格=危险"的含义，用对齐的彩色文字表达，
#     免得把"18/142 是活跃连接"误读成"健康度只有 13%"。
#   * 百分比右对齐到固定列，数值才能竖向扫读。
#   * 颜色码由 printf '\033' 运行时生成，本文件不含任何控制字节。
#   * 数据全部取自 /proc 与 /sys，不依赖 ss/netstat/ifconfig。

USE_COLOR=1      # 1 = 彩色，0 = 纯文本
USE_BOLD=1       # 1 = 标签加粗
LOGINS=5         # 登录记录条数
BAR_WIDTH=12     # 占用条宽度（字符数）
WARN=60          # 黄条阈值（百分比）
CRIT=85          # 红条阈值（百分比）
SHOW_CONN=1      # 1 = 显示 连接 / 方向 / 累计
SHOW_TRAFFIC=1   # 1 = 显示 流量
NET_BARS=0       # 0 = 连接类用彩色文字（推荐）；1 = 改用构成条
LOGIN_HEADER=1   # 1 = 登录表显示列标题
HIDE_CURRENT=0   # 1 = 登录记录里隐藏本次会话，会连别人的在线会话一起隐藏
NET_IFACE=''     # 流量统计的网卡，留空自动取默认路由网卡

BAR_FULL='█'     # 占用条：已完成
BAR_EMPTY='░'    # 占用条：空槽
SEG_1='█'        # 构成条：第一段（配合 NET_BARS=1）
SEG_2='▒'        # 构成条：第二段
SEG_3='░'        # 构成条：其余

# 登录表列标题：与下面的 %-14s %-8s %-16s %s 逐列对齐
# （"开始"占 4 列 + 11 空格 = 14；"用户" 4 + 5 = 8；"来源" 4 + 13 = 16）
LOGIN_HDR='开始           用户     来源             时长'

esc=$(printf '\033')
if [ "$USE_COLOR" = 1 ] && [ ${#esc} -eq 1 ]; then
	if [ "$USE_BOLD" = 1 ]; then
		C="${esc}[1;36m"    # 粗体青：标签
	else
		C="${esc}[36m"
	fi
	D="${esc}[90m"          # 灰：次要信息 / 空槽 / 表头
	G="${esc}[32m"          # 绿：正常 / 第一组数值
	Y="${esc}[33m"          # 黄：偏高
	R="${esc}[31m"          # 红：吃紧
	K="${esc}[36m"          # 青：第二组数值
	Z="${esc}[0m"           # 复位
	COLOR=1
else
	C=''; D=''; G=''; Y=''; R=''; K=''; Z=''
	COLOR=0
fi

# ------------------------------------------------------------------ 绘制
# 占用条：bar <百分比整数>
bar() {
	_p=$1
	case "$_p" in ''|*[!0-9]*) _p=0 ;; esac
	[ "$_p" -gt 100 ] && _p=100
	_n=$(( (_p * BAR_WIDTH + 50) / 100 ))
	_f=''
	_e=''
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_f="$_f$BAR_FULL"
		_i=$(( _i + 1 ))
	done
	_i=0
	while [ "$_i" -lt "$(( BAR_WIDTH - _n ))" ]; do
		_e="$_e$BAR_EMPTY"
		_i=$(( _i + 1 ))
	done
	if [ "$COLOR" = 1 ]; then
		if [ "$_p" -ge "$CRIT" ]; then
			_c=$R
		elif [ "$_p" -ge "$WARN" ]; then
			_c=$Y
		else
			_c=$G
		fi
		printf '%s%s%s%s%s' "$_c" "$_f" "$D" "$_e" "$Z"
	else
		printf '%s%s' "$_f" "$_e"
	fi
}

# 构成条：sbar <值1> <值2> [值3] -> 输出 "<彩条> <值1占比>"
sbar() {
	awk -v a="${1:-0}" -v b="${2:-0}" -v c="${3:-0}" -v w="$BAR_WIDTH" \
	    -v e="$esc" -v s1="$SEG_1" -v s2="$SEG_2" -v s3="$SEG_3" '
		function rep(ch, n,   i, s) {
			s = ""
			for (i = 0; i < n; i++) s = s ch
			return s
		}
		function cl(k) { return (e == "") ? "" : e "[" k "m" }
		BEGIN {
			v[1] = a + 0
			v[2] = b + 0
			v[3] = c + 0
			t = v[1] + v[2] + v[3]
			n[1] = 0; n[2] = 0; n[3] = 0
			if (t <= 0) {
				printf "%s%s %d\n", cl(90), rep(s3, w), 0
				exit
			}
			# 非零项先各占 1 格，剩余格按比例分，最后修正累计误差
			left = w
			for (i = 1; i <= 3; i++) {
				if (v[i] > 0) { n[i] = 1; left-- }
			}
			if (left > 0) {
				got = 0
				for (i = 1; i <= 3; i++) {
					if (v[i] > 0) {
						k = int(v[i] * left / t + 0.5)
						n[i] += k
						got += k
					}
				}
				d = left - got
				if (d != 0) {
					j = 1
					for (i = 2; i <= 3; i++) if (v[i] > v[j]) j = i
					n[j] += d
				}
			}
			if (n[1] + n[2] + n[3] != w) {
				j = 1
				for (i = 2; i <= 3; i++) if (v[i] > v[j]) j = i
				n[j] += w - n[1] - n[2] - n[3]
			}
			printf "%s%s%s%s%s%s%s %d\n", cl(32), rep(s1, n[1]), \
				cl(36), rep(s2, n[2]), cl(90), rep(s3, n[3]), cl(0), \
				int(v[1] * 100 / t + 0.5)
		}'
}

# 带占用条的一行：rowbar <标签> <百分比> <事实>
rowbar() { printf ' %s%s%s  %s  %s%3s%%%s  %s\n' "$C" "$1" "$Z" "$(bar "$2")" "$D" "$2" "$Z" "$3"; }

# 磁盘行：把挂载点放到最后一列（仿 df -h 的列序），避免"挂载点 / 已用 / 总量"三个斜杠连在一起
# "已用 / 总量"是纯 ASCII，可以用 %-14s 按字节补齐对齐
diskrow() { printf ' %s%s%s  %s  %s%3s%%%s  %-14s %s\n' "$C" "$1" "$Z" "$(bar "$2")" "$D" "$2" "$Z" "$3" "$4"; }

# 带构成条的一行：srow <标签> <值1> <值2> [值3] <事实>
srow() {
	read -r _bar _pct <<EOF
$(sbar "$2" "$3" "${4:-0}")
EOF
	printf ' %s%s%s  %s  %s%3s%%%s  %s\n' "$C" "$1" "$Z" "$_bar" "$D" "$_pct" "$Z" "$5"
}

# 纯文字一行：crow <标签> <内容>（内容里可带颜色）
crow() { printf ' %s%s%s  %s\n' "$C" "$1" "$Z" "$2"; }

# 连接/流量行：NET_BARS=1 时改用构成条
netrow() {
	if [ "$NET_BARS" = 1 ]; then
		srow "$1" "$2" "$3" "${4:-0}" "$5"
	else
		crow "$1" "$5"
	fi
}

# 无条的信息行
row() { printf ' %s%s%s  %s\n' "$C" "$1" "$Z" "$2"; }

# ------------------------------------------------------------------ 系统
os=$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}" )
kern=$(uname -r)
arch=$(uname -m)
host=$(uname -n)
# "up 12 weeks, 3 days, 15 hours, 51 minutes" -> "12 weeks, 3 days"
up=$(uptime -p 2>/dev/null | sed 's/^up //')
up=$(printf '%s' "$up" | awk -F', ' '{ if (NF > 2) printf "%s, %s", $1, $2; else printf "%s", $0 }')

# 容器（LXC/OpenVZ/部分 Docker）里 /proc/meminfo、/proc/cpuinfo、/proc/loadavg 报的都是
# 宿主机的数字，真实配额在 cgroup 里。cgroup v2 看 /sys/fs/cgroup/memory.max，
# v1 看 /sys/fs/cgroup/memory/ 目录下那几个文件。
cgver=''; cg_mem_limit=''; cg_mem_used=''; cg_swap_limit=''; cg_swap_used=''
cg_quota=''; cg_period=''
if [ -r /sys/fs/cgroup/memory.max ]; then
	cgver=2
	cg_mem_limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
	cg_mem_used=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
	cg_swap_limit=$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null)
	cg_swap_used=$(cat /sys/fs/cgroup/memory.swap.current 2>/dev/null)
	cg_quota=$(awk '{print $1}' /sys/fs/cgroup/cpu.max 2>/dev/null)
	cg_period=$(awk '{print $2}' /sys/fs/cgroup/cpu.max 2>/dev/null)
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
	cgver=1
	cg_mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
	cg_mem_used=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)
	cg_swap_limit=$(cat /sys/fs/cgroup/memory/memory.memsw.limit_in_bytes 2>/dev/null)
	cg_swap_used=$(cat /sys/fs/cgroup/memory/memory.memsw.usage_in_bytes 2>/dev/null)
	cg_quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)
	cg_period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
fi
# v1 的 memsw 是「内存+交换」合计上限，减去内存上限才是交换上限
if [ "$cgver" = 1 ]; then
	case "$cg_swap_limit$cg_mem_limit" in
		*[!0-9]*) ;;
		*) [ "$cg_swap_limit" -gt "$cg_mem_limit" ] && cg_swap_limit=$(( cg_swap_limit - cg_mem_limit )) ;;
	esac
fi

cores=$(nproc 2>/dev/null)
[ -n "$cores" ] || cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
[ -n "$cores" ] || cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
[ -n "$cores" ] || cores=1
# cgroup 的 CPU 配额（"200000 100000" = 2 核）可能小于 nproc，取较小值
case "$cg_quota" in
	''|max|*[!0-9]*) ;;
	*) if [ "$cg_quota" -gt 0 ] && [ "${cg_period:-0}" -gt 0 ]; then
		qc=$(( (cg_quota + cg_period - 1) / cg_period ))
		[ "$qc" -gt 0 ] && [ "$qc" -lt "$cores" ] && cores=$qc
	fi ;;
esac

loads=$(awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)
l1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
# 负载条 = load1 / 核数：100% 表示每核一个可运行任务
lp=$(awk -v l="${l1:-0}" -v c="$cores" 'BEGIN{ p = (c > 0) ? l * 100 / c : 0; if (p > 999) p = 999; printf "%d", p }')

# 内存：cgroup 限额有效就用它（容器），否则退回 /proc/meminfo（物理机）
mem=$(awk -v lim="$cg_mem_limit" -v used="$cg_mem_used" '
	function h(b) {
		if (b <= 0)          return "0"
		if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824)
		if (b >= 1048576)    return sprintf("%dM", b / 1048576)
		return sprintf("%dK", b / 1024)
	}
	function n(x) { return (x ~ /^[0-9]+$/) ? x + 0 : -1 }
	/^MemTotal:/     { t = $2 }
	/^MemAvailable:/ { a = $2 }
	/^MemFree:/      { f = $2 }
	END {
		if (!t) exit
		if (!a) a = f
		host = t * 1024
		L = n(lim)
		if (L > 0 && L < host) {          # 有效限额；v1 的"无限制"是个远大于宿主的数
			U = n(used)
			if (U < 0 || U > L) U = L - (t - a) * 1024
			if (U < 0) U = 0
			printf "%d %s %s", U * 100 / L, h(U), h(L)
		} else {
			U = (t - a) * 1024
			printf "%d %s %s", U * 100 / host, h(U), h(host)
		}
	}' /proc/meminfo)
mp=''; mu=''; mt=''
if [ -n "$mem" ]; then
	read -r mp mu mt <<EOF
$mem
EOF
fi

# 交换：同样以 cgroup 为准；v2 的 swap.max=0 或 v1 的 memsw==memory 都表示没有交换
swapinfo=$(awk -v lim="$cg_swap_limit" -v used="$cg_swap_used" '
	function h(b) {
		if (b <= 0)          return "0"
		if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824)
		if (b >= 1048576)    return sprintf("%dM", b / 1048576)
		return sprintf("%dK", b / 1024)
	}
	function n(x) { return (x ~ /^[0-9]+$/) ? x + 0 : -1 }
	/^SwapTotal:/ { t = $2 }
	/^SwapFree:/  { f = $2 }
	END {
		host = t * 1024
		L = n(lim)
		if (L == 0) exit
		if (L > 0 && L < host) {
			tot = L
			U = n(used)
			if (U < 0 || U > L) U = 0
		} else {
			tot = host
			U = (t - f) * 1024
		}
		if (tot <= 0) exit
		printf "%d %s %s", U * 100 / tot, h(U), h(tot)
	}' /proc/meminfo)
sp=''; su=''; st=''
if [ -n "$swapinfo" ]; then
	read -r sp su st <<EOF
$swapinfo
EOF
fi

# 真实挂载点，每个一行：mount 百分比 已用 总量
disks=$(df -h --output=target,pcent,used,size -x tmpfs -x devtmpfs -x vfat -x squashfs 2>/dev/null \
	| awk 'NR > 1 { sub(/%$/, "", $2); print $1, $2, $3, $4 }' | head -n 3)
[ -n "$disks" ] || disks=$(df -h / 2>/dev/null | awk 'NR == 2 { sub(/%$/, "", $5); print $6, $5, $3, $2 }')

users=$(who 2>/dev/null | wc -l | tr -d ' ')
procs=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')

# ------------------------------------------------------------------ 连接
# /proc/net/tcp{,6} 的 st 列是十六进制状态：01=ESTABLISHED  0A=LISTEN
# 方向判定：本地端口落在 LISTEN 集合里 = 入站（被连）；否则 = 出站（本机主动发起）
conn=$(awk '
	FNR > 1 && NF >= 4 {
		total++
		st = $4
		split($2, a, ":")
		if (st == "0A") {
			ln++
			listen[a[2]] = 1
		} else if (st == "01") {
			est++
			eport[a[2]]++
		}
	}
	END {
		inb = 0
		outb = 0
		for (p in eport) {
			if (p in listen) inb += eport[p]
			else outb += eport[p]
		}
		printf "%d %d %d %d %d", total + 0, est + 0, outb, inb, ln + 0
	}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)

# 累计建连：/proc/net/snmp 的 Tcp: 行按列名定位 ActiveOpens / PassiveOpens
# 输出 原值+显示值：原值给条算比例，显示值给人看
opens=$(awk '
	function hn(x) {
		if (x >= 1000000) return sprintf("%.1fM", x / 1000000)
		if (x >= 10000)   return sprintf("%.1fk", x / 1000)
		return sprintf("%d", x)
	}
	/^Tcp:/ {
		if (!got) {
			for (i = 2; i <= NF; i++) {
				if ($i == "ActiveOpens")  ai = i
				if ($i == "PassiveOpens") pi = i
			}
			got = 1
			next
		}
		if (ai && pi) printf "%d %d %s %s", $ai + 0, $pi + 0, hn($ai + 0), hn($pi + 0)
	}' /proc/net/snmp 2>/dev/null)

# ------------------------------------------------------------------ 流量
iface=$NET_IFACE
[ -n "$iface" ] || iface=$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route 2>/dev/null)
[ -n "$iface" ] || iface=$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n 1)

# 输出 原值+显示值+均速
traffic=''
[ -n "$iface" ] && traffic=$(awk -v n="$iface" '
	function h(k) {
		if (k >= 1073741824) return sprintf("%.1fG", k / 1073741824)
		if (k >= 1048576)    return sprintf("%.1fM", k / 1048576)
		if (k >= 1024)       return sprintf("%.1fK", k / 1024)
		return sprintf("%dB", k)
	}
	BEGIN {
		rf = "/sys/class/net/" n "/statistics/rx_bytes"
		tf = "/sys/class/net/" n "/statistics/tx_bytes"
		if ((getline rv < rf) <= 0) exit
		if ((getline tv < tf) <= 0) exit
		rv += 0
		tv += 0
		up = 1
		if ((getline u < "/proc/uptime") > 0) up = (u + 0 > 0) ? u + 0 : 1
		printf "%d %d %s %s %s %s", rv, tv, h(rv), h(tv), h(rv / up), h(tv / up)
	}' 2>/dev/null)

ctotal=''; cest=''; cout=''; cin=''; clisten=''
if [ -n "$conn" ]; then
	read -r ctotal cest cout cin clisten <<EOF
$conn
EOF
fi
oar=''; opr=''; oa=''; op=''
if [ -n "$opens" ]; then
	read -r oar opr oa op <<EOF
$opens
EOF
fi
rxr=''; txr=''; rxv=''; txv=''; rrate=''; trate=''
if [ -n "$traffic" ]; then
	read -r rxr txr rxv txv rrate trate <<EOF
$traffic
EOF
fi

if [ "$HIDE_CURRENT" = 1 ]; then
	drop='still logged in'
else
	drop='@@never-matches@@'
fi

# 登录记录：重排成对齐表格（last 原始输出的宽间距很难看）
# LC_ALL=C 保证月份是英文 Jan..Dec，字段位置固定
logins=$(LC_ALL=C last -i -n 100 2>/dev/null | awk -v n="$LOGINS" -v drop="$drop" -v e="$esc" '
	BEGIN {
		split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
		for (i = 1; i <= 12; i++) mon[mn[i]] = i
	}
	$2 ~ /^pts\// {
		if (index($0, drop) > 0) next
		if (++shown > n) exit
		start = sprintf("%02d-%02d %s", mon[$5] + 0, $6 + 0, $7)
		if (index($0, "still logged in") > 0) {
			dur = (e == "") ? "在线" : e "[32m在线" e "[0m"
		} else if ($NF ~ /^\([0-9]/) {
			d = $NF
			gsub(/[()]/, "", d)
			dur = d
		} else {
			dur = "-"
		}
		printf "   %-14s %-8s %-16s %s\n", start, $1, $3, dur
	}')

# ------------------------------------------------------------------ 输出
# 前面 20-logo 已经输出过空行，这里不再补
row "系统" "$os · $kern · $arch"
row "主机" "$host${up:+ · $up}${users:+ · 在线 $users 人}${procs:+ · 进程 $procs}"

# 占用率一组
printf '\n'
[ -n "$lp" ] && rowbar "负载" "$lp" "${loads:-n/a} · ${cores} 核"
[ -n "$mem" ] && rowbar "内存" "$mp" "$mu / $mt"
[ -n "$sp" ] && rowbar "交换" "$sp" "$su / $st"
if [ -n "$disks" ]; then
	_first=1
	while read -r _mnt _pct _used _size; do
		[ -n "$_mnt" ] || continue
		if [ "$_first" = 1 ]; then _lbl='磁盘'; _first=0; else _lbl='    '; fi
		diskrow "$_lbl" "$_pct" "$_used / $_size" "$_mnt"
	done <<EOF
$disks
EOF
fi

# 连接与流量一组
if { [ "$SHOW_CONN" = 1 ] && [ -n "$ctotal" ]; } || { [ "$SHOW_TRAFFIC" = 1 ] && [ -n "$rxr" ]; }; then
	printf '\n'
fi
if [ "$SHOW_CONN" = 1 ] && [ -n "$ctotal" ]; then
	cother=$(( ctotal - cest - clisten ))
	[ "$cother" -lt 0 ] && cother=0
	netrow "连接" "$cest" "$clisten" "$cother" \
		"${ctotal} 个 · ${G}建立 ${cest}${Z} · ${K}监听 ${clisten}${Z} · ${D}其他 ${cother}${Z}"
	netrow "方向" "$cout" "$cin" 0 \
		"${G}出站 ${cout}${Z} · ${K}入站 ${cin}${Z}"
	[ -n "$oar" ] && netrow "累计" "$oar" "$opr" 0 \
		"${G}主动建连 ${oa}${Z} · ${K}被动建连 ${op}${Z} · ${D}开机以来${Z}"
fi
[ "$SHOW_TRAFFIC" = 1 ] && [ -n "$rxr" ] && netrow "流量" "$rxr" "$txr" 0 \
	"${iface} ${G}↓ ${rxv}${Z} ${K}↑ ${txv}${Z} · ${D}均速${Z} ${G}↓ ${rrate}/s${Z} ${K}↑ ${trate}/s${Z}"

# 登录记录
printf '\n %s%s%s\n' "$C" "最近 $LOGINS 次 SSH 登录" "$Z"
if [ -n "$logins" ]; then
	[ "$LOGIN_HEADER" = 1 ] && printf '   %s%s%s\n' "$D" "$LOGIN_HDR" "$Z"
	printf '%s\n' "$logins"
elif ! command -v last >/dev/null 2>&1; then
	# Debian 13 的 util-linux 不再提供 last，需安装 wtmpdb（它提供兼容的 last 命令）
	printf '   %s没有 last 命令（Debian 13 请安装 wtmpdb 与 libpam-wtmpdb）%s\n' "$D" "$Z"
else
	printf '   %s读不到登录记录（登录数据库为空或不可读）%s\n' "$D" "$Z"
fi
__LT_PAYLOAD_END__
}


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
            0|q|Q) info "再见。"; exit 0 ;;
            '') ;;
            *) warn "无效编号：$choice"; sleep 1 ;;
        esac
    done
}

main "$@"
