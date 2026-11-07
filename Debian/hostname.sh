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

# >>> lib/ui.sh >>>
# 终端外观与提问（由 build.sh 从 lib/ui.sh 同步到各脚本，要修改请改 lib/ui.sh 再运行 bash build.sh）。
# 每个脚本都要能单独下载运行，所以各自带一份。
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; REV=$'\033[7m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'
else
    BOLD=''; DIM=''; REV=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi
EL=$'\033[K'

# 按 UTF-8 计算中文的显示宽度。当前 locale 不是 UTF-8 时，只给本脚本自己换成 C.UTF-8
# （不导出，调用的其他程序不受影响）；还不行就退回 ASCII 字符。LT_ASCII=1 强制用 ASCII
_probe='中'
if (( ${#_probe} != 1 )) && [[ -z ${LC_ALL:-} ]]; then
    { LC_ALL=C.UTF-8; } 2>/dev/null
    export -n LC_ALL
fi
UNICODE=0; UTF8=0
(( ${#_probe} == 1 )) && UTF8=1
(( UTF8 )) && [[ ${LT_ASCII:-0} != 1 ]] && UNICODE=1
unset _probe

if (( UNICODE )); then
    G_HR='─'; G_SEL='▸'; G_ON='●'; G_OFF='○'; G_WARN='▲'; G_OK='✓'; G_ERR='✗'
    G_BAR='█'; G_BAR0='░'; G_DOT='·'; G_MORE='…'; G_UPDN='↑↓'; G_UP='↑'; G_DOWN='↓'; G_LOGO='◆'; G_ARROW='›'
else
    G_HR='-'; G_SEL='>'; G_ON='*'; G_OFF='o'; G_WARN='!'; G_OK='+'; G_ERR='x'
    G_BAR='#'; G_BAR0='.'; G_DOT='|'; G_MORE='..'; G_UPDN='Up/Down'; G_UP='^'; G_DOWN='v'; G_LOGO='#'; G_ARROW='>'
fi

info() { printf '%s\n' "$*"; }
ok()   { printf ' %s%s%s %s\n' "$GREEN" "$G_OK" "$NC" "$*"; }
warn() { printf ' %s%s %s%s\n' "$YELLOW" "$G_WARN" "$*" "$NC" >&2; }
die()  { printf ' %s%s %s%s\n' "$RED" "$G_ERR" "$*" "$NC" >&2; exit 1; }
# step <文字>：一个处理步骤开始，如「正在下载 ...」
step() { printf ' %s%s%s %s\n' "$CYAN" "$G_SEL" "$NC" "$*"; }

# 一律从 /dev/tty 读，用 curl ... | bash 运行时也能正常提问
HAVE_TTY=0
{ : </dev/tty; } 2>/dev/null && HAVE_TTY=1

# 方向键菜单需要真正的终端；否则（或设置了 LT_PLAIN=1）改为输入编号
TUI=0
if (( HAVE_TTY )) && [[ -t 1 && ${TERM:-dumb} != dumb && ${LT_PLAIN:-0} != 1 ]]; then
    TUI=1
fi

# 从总控菜单 menu.sh 打开时，菜单里的「退出」实际是回到总控菜单
BACK_LABEL='退出'
[[ ${LT_FROM_MENU:-0} == 1 ]] && BACK_LABEL='返回主菜单'

# ask_yn <提示> <默认 y|n>；没有终端、或脚本设置了 ASSUME_YES=1（如 --yes）时直接取默认值
ask_yn() {
    local prompt=$1 def=$2 hint='y/N' reply=''
    [[ $def == y ]] && hint='Y/n'
    if (( ${ASSUME_YES:-0} )); then
        [[ $def == y ]]
        return
    fi
    if (( HAVE_TTY )); then
        read -r -p " $YELLOW?$NC $prompt $DIM[$hint]$NC " reply </dev/tty || reply=''
    fi
    reply=${reply:-$def}
    [[ $reply =~ ^[Yy] ]]
}

# ask_value <提示> <默认值> <校验正则>；结果输出到 stdout。默认值为空时不显示 []
ask_value() {
    local prompt=$1 def=$2 re=$3 reply='' shown=''
    [[ -n $def ]] && shown=" $DIM[$def]$NC"
    while true; do
        read -r -p " $YELLOW?$NC $prompt$shown: " reply </dev/tty || reply=''
        reply=${reply:-$def}
        if [[ $reply =~ $re ]]; then
            printf '%s' "$reply"
            return
        fi
        printf '   %s输入无效，请重新输入。%s\n' "$RED" "$NC" >&2
    done
}

pause() { printf '\n'; read -r -p " ${DIM}按回车返回...${NC}" _ </dev/tty || true; }

clear_screen() { [[ -t 1 ]] && printf '\033[H\033[2J'; return 0; }

# ---- 排版：中文按 2 列计算宽度，结果放进全局变量，避免反复开子进程 ----
# text_width <文本>：显示宽度放进 WIDTH。文本里不能带颜色代码
text_width() {
    local s=$1 i cp
    WIDTH=${#s}
    (( UTF8 )) || return 0
    [[ $s == *[![:ascii:]]* ]] || return 0
    for (( i = 0; i < ${#s}; i++ )); do
        printf -v cp '%d' "'${s:i:1}"
        if (( (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf && cp != 0x303f) ||
              (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) ||
              (cp >= 0xfe30 && cp <= 0xfe4f) || (cp >= 0xff00 && cp <= 0xff60) ||
              (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1faff) ||
              (cp >= 0x20000 && cp <= 0x3fffd) )); then
            (( WIDTH++ ))
        fi
    done
}

# fit <文本> <最大宽度>：超出时截断并加省略号，结果放进 FIT，宽度放进 WIDTH
fit() {
    local s=$1 max=$2 i c out='' w=0 mw=${#G_MORE}
    text_width "$s"
    (( WIDTH <= max )) && { FIT=$s; return; }
    if (( max <= mw )); then FIT=''; WIDTH=0; return; fi
    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        text_width "$c"
        (( w + WIDTH + mw > max )) && break
        out+=$c
        (( w += WIDTH ))
    done
    FIT=$out$G_MORE
    WIDTH=$(( w + mw ))
}

# pad <宽度>：空格放进 PAD
pad() { local n=$1; (( n < 0 )) && n=0; printf -v PAD '%*s' "$n" ''; }

# hr <宽度>：一条暗色横线放进 HR
hr() { local n=$1; (( n < 0 )) && n=0; printf -v HR '%*s' "$n" ''; HR="$DIM${HR// /$G_HR}$NC"; }

# 状态统一写成 "级别|文字"。级别：on 正常、warn 注意、danger 危险、off 未安装、info 说明
# badge <状态> [最大宽度]：彩色状态放进 BADGE
badge() {
    local level text max=${2:-200} g c
    BADGE=''
    [[ -n $1 ]] || return 0
    if [[ $1 == *'|'* ]]; then level=${1%%|*}; text=${1#*|}; else level=info; text=$1; fi
    case $level in
        on)     g=$G_ON;   c=$GREEN ;;
        warn)   g=$G_WARN; c=$YELLOW ;;
        danger) g=$G_WARN; c=$RED ;;
        off)    g=$G_OFF;  c=$DIM ;;
        *)      g=' ';     c=$DIM ;;
    esac
    (( max > 2 )) || return 0
    fit "$text" $(( max - 2 ))
    BADGE="$c$g $FIT$NC"
}

# 终端大小放进 TERM_ROWS / TERM_COLS；内容宽度 UI_W 最多 78 列
term_size() {
    local r='' c=''
    read -r r c < <(stty size </dev/tty 2>/dev/null)
    [[ $r =~ ^[0-9]+$ ]] && (( r >= 10 )) || r=24
    [[ $c =~ ^[0-9]+$ ]] && (( c >= 40 )) || c=80
    TERM_ROWS=$r; TERM_COLS=$c
    UI_W=$(( c - 1 )); (( UI_W > 78 )) && UI_W=78
    TITLE_W=$(( UI_W - 38 )); (( TITLE_W > 24 )) && TITLE_W=24; (( TITLE_W < 14 )) && TITLE_W=14
    return 0
}

# 页面顶部一行：◆ Linux-tools › 位置，放进 TITLE
title_line() {
    TITLE=" $CYAN$G_LOGO$NC ${BOLD}Linux-tools$NC"
    if [[ -n $1 ]]; then
        TITLE+=" $DIM$G_ARROW$NC $BOLD$1$NC"
    else
        TITLE+=" ${DIM}工具箱 $G_DOT Debian 12 / 13$NC"
    fi
}

# page <位置>：清屏，画出页面标题，用在每个功能开始时
page() {
    clear_screen
    term_size
    title_line "$1"
    hr "$UI_W"
    printf '%s\n%s\n\n' "$TITLE" "$HR"
}

# section <标题>：页面里的小标题，后面跟一条横线
section() {
    term_size
    text_width "$1"
    hr $(( UI_W - WIDTH - 2 ))
    printf '\n %s%s%s %s\n' "$BOLD" "$1" "$NC" "$HR"
}

# kv <标签> <内容> [标签宽度]：一行 " 标签  内容"，标签暗色、按宽度对齐（内容可以带颜色），
# 结果放进 KV；标签宽度默认 KV_W（8 列，即 4 个汉字）
kv() {
    text_width "$1"
    pad $(( ${3:-${KV_W:-8}} - WIDTH ))
    KV=" $DIM$1$NC$PAD  $2"
}
# <<< lib/ui.sh <<<

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
    ok "已更新 $HOSTS：$entry"
    info "   ${DIM}原文件备份在 $b$NC"

    # 其他行里还出现旧主机名时只提醒，不擅自修改
    if [[ -n $old && $old != "$new" ]] &&
       grep -vE '^[[:space:]]*(#|127\.0\.1\.1[[:space:]])' "$HOSTS" | grep -qwF -- "$old"; then
        warn "$HOSTS 的其他行里还有旧主机名 $old，请自行检查："
        grep -nwF -- "$old" "$HOSTS" | grep -v '127\.0\.1\.1' | sed 's/^/     /' >&2
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
        info " 没有修改 cloud-init，重启后主机名可能会被改回去。"
    fi
}

main() {
    local old new input
    case ${1:-} in
        -h|--help) info "用法: sudo bash ${0##*/} [新主机名]"; exit 0 ;;
    esac
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"

    old=$(current_hostname)
    page "修改主机名"
    kv 当前主机名 "$BOLD$old$NC" 10; info "$KV"

    input=${1:-}
    if [[ -z $input ]]; then
        (( HAVE_TTY )) || die "需要交互式终端，或者直接把新主机名写在参数里。"
        info "   ${DIM}只能用字母、数字、- 和 .，例如 web01 或 web01.example.com$NC"
        printf '\n'
        read -r -p " $YELLOW?$NC 新主机名 ${DIM}（直接回车取消）$NC: " input </dev/tty || input=''
        [[ -n $input ]] || { info " 已取消，没有做任何修改。"; exit 0; }
    fi

    new=${input,,}
    [[ $new != "$input" ]] && info "   ${DIM}主机名不区分大小写，统一用小写：$new$NC"
    valid_hostname "$new" || die "主机名不合法：$input（每段 1-63 个字母、数字或 -，不能以 - 开头或结尾）"
    if [[ $new == "$old" ]]; then
        ok "主机名已经是 $new，无需修改。"
        exit 0
    fi

    set_hostname "$new" || die "修改主机名失败。"
    ok "主机名已改为 $new"
    update_hosts "$new" "$old"
    keep_with_cloud_init
    info "   ${DIM}当前 shell 的提示符要重新登录后才会显示新主机名。$NC"
}

main "$@"
