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
