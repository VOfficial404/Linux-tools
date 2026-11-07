#!/usr/bin/env bash
#
# Linux-tools 总控菜单
#
# 用法：
#   在仓库目录里：         sudo bash menu.sh
#   只下载这一个文件：     curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/menu.sh -o menu.sh && sudo bash menu.sh
#
# 操作：↑↓（或 j / k）选择，回车执行；也可以直接输入编号再回车。q 退出，子菜单里 Esc 返回。
#
# 环境变量：
#   LT_REPO_RAW   在线下载子脚本的地址，可改成自己的 fork 或镜像
#   LT_ASCII=1    只用 ASCII 字符画线和图标（终端里的线条、圆点显示成方块或错位时用）
#   LT_PLAIN=1    不用方向键菜单，改为输入编号（终端不支持光标控制时用）
#
# 把仓库里的各个脚本集中到一个交互式菜单里。
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

# 退出时删除临时目录，并恢复光标和终端设置（方向键菜单会隐藏光标）
TUI=0
STTY_SAVED=''
cleanup() {
    rm -rf -- "${WORK_DIR:-/nonexistent}"
    if (( TUI )); then
        { printf '\033[?25h' >/dev/tty; [[ -n $STTY_SAVED ]] && stty "$STTY_SAVED" </dev/tty; } 2>/dev/null
    fi
}

# 取到的子脚本放在这里，退出时整个删除
WORK_DIR=$(mktemp -d /tmp/linux-tools.XXXXXX) || { echo "无法创建临时目录" >&2; exit 1; }
trap cleanup EXIT
# Ctrl-C 时走正常退出流程，保证上面的清理会执行
trap 'printf "\n"; exit 130' INT

# GitHub 下载失败时，motd 文件再试一次这些短链接
declare -A MOTD_URL=(
    [20-DSH-32]="https://lnk.ixwx.de/dsh-32"
    [20-DSH-mono-32]="https://lnk.ixwx.de/dsh-mono-32"
    [25-sysinfo]="https://lnk.ixwx.de/sysinfo"
)

# -----------------------------------------------------------------------------
# 终端外观、提问、排版（公共代码，见 lib/ui.sh）
# -----------------------------------------------------------------------------
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

# 退出时要恢复的终端设置
(( TUI )) && { STTY_SAVED=$(stty -g </dev/tty 2>/dev/null) || STTY_SAVED=''; }

# bar <百分比> <格数>：彩色占用条放进 BAR（70% 以上变黄，90% 以上变红）
bar() {
    local pct=$1 n=$2 fill color=$GREEN f e
    (( pct > 100 )) && pct=100
    (( pct < 0 )) && pct=0
    fill=$(( (pct * n + 50) / 100 ))
    if (( pct >= 90 )); then color=$RED; elif (( pct >= 70 )); then color=$YELLOW; fi
    printf -v f '%*s' "$fill" ''
    printf -v e '%*s' "$(( n - fill ))" ''
    BAR="$color${f// /$G_BAR}$NC$DIM${e// /$G_BAR0}$NC"
}

# human_kb <KB>：放进 HUMAN，如 1.9G、512M
human_kb() {
    local kb=$1
    if (( kb >= 1048576 )); then
        printf -v HUMAN '%d.%dG' $(( kb / 1048576 )) $(( kb % 1048576 * 10 / 1048576 ))
    elif (( kb >= 1024 )); then
        HUMAN="$(( kb / 1024 ))M"
    else
        HUMAN="${kb}K"
    fi
}

# -----------------------------------------------------------------------------
# 菜单组件（公共代码，见 lib/menu.sh）
# -----------------------------------------------------------------------------
# >>> lib/menu.sh >>>
# 方向键菜单（由 build.sh 从 lib/menu.sh 同步到各脚本，要修改请改 lib/menu.sh 再运行 bash build.sh）。
#   menu_reset，然后用 menu_group / menu_item 添加条目，MENU_HEADER 放标题下的说明行，
#   再调用 menu_run <位置> <返回键> [默认选中的编号]，选中的编号放进 MENU_CHOICE。
#   MENU_HINT 可以换掉底部的按键提示
#   位置为空表示主菜单：Esc 不退出，按 q 才退出
menu_reset() { M_KIND=(); M_KEY=(); M_TITLE=(); M_STATUS=(); MENU_HEADER=(); MENU_HINT=''; term_size; }
# menu_group <组名> [说明]：组之间自动空一行
menu_group() {
    (( ${#M_KIND[@]} )) && { M_KIND+=(B); M_KEY+=(''); M_TITLE+=(''); M_STATUS+=(''); }
    M_KIND+=(H); M_KEY+=(''); M_TITLE+=("$1"); M_STATUS+=("${2:-}")
}
menu_blank() { M_KIND+=(B); M_KEY+=(''); M_TITLE+=(''); M_STATUS+=(''); }
# menu_item <编号> <标题> [状态]
menu_item() { M_KIND+=(I); M_KEY+=("$1"); M_TITLE+=("$2"); M_STATUS+=("${3:-}"); }

# menu_line <索引> <是否选中>：一行菜单放进 LINE
menu_line() {
    local i=$1 sel=$2 num title w
    case ${M_KIND[i]} in
        B) LINE=''; return ;;
        H)
            text_width "${M_TITLE[i]}"; w=$(( WIDTH + 1 ))
            LINE=" $BOLD${M_TITLE[i]}$NC"
            if [[ -n ${M_STATUS[i]} ]]; then
                fit "${M_STATUS[i]}" $(( UI_W - w - 6 ))
                LINE+=" $DIM$FIT$NC"; (( w += WIDTH + 1 ))
            fi
            hr $(( UI_W - w - 1 ))
            LINE+=" $HR"
            return ;;
    esac
    fit "${M_TITLE[i]}" "$TITLE_W"; title=$FIT
    pad $(( TITLE_W - WIDTH ))
    printf -v num '%2s' "${M_KEY[i]}"
    badge "${M_STATUS[i]}" $(( UI_W - TITLE_W - 11 ))
    if (( sel )); then
        LINE=" $CYAN$G_SEL$NC $REV$BOLD $num  $title$PAD $NC  $BADGE"
    else
        LINE="    $CYAN$num$NC  $title$PAD   $BADGE"
    fi
}

# menu_find <编号>：找到对应条目的索引放进 FOUND，找不到返回 1
menu_find() {
    local i
    for (( i = 0; i < ${#M_KIND[@]}; i++ )); do
        [[ ${M_KIND[i]} == I && ${M_KEY[i]} == "$1" ]] && { FOUND=$i; return 0; }
    done
    return 1
}

# menu_draw <位置> <选中索引> <已输入的编号> <提示消息>：原地重画整屏（不清屏，避免闪烁）
menu_draw() {
    local crumb=$1 sel=$2 buf=$3 msg=$4 out i n=${#M_KIND[@]} hdr=${#MENU_HEADER[@]} h fixed end hint rule room
    term_size
    # 至少留 6 行给菜单；屏幕不够时说明行只显示前面几行
    room=$(( TERM_ROWS - 4 - 6 - 1 ))
    (( hdr > room )) && hdr=$room
    (( hdr < 0 )) && hdr=0
    fixed=4
    (( hdr )) && fixed=$(( fixed + hdr + 1 ))
    h=$(( TERM_ROWS - fixed ))
    (( h > n )) && h=$n

    # 滚动：选中项必须可见；它上面紧挨着的组标题尽量一起显示
    (( sel < MENU_TOP )) && MENU_TOP=$sel
    while (( MENU_TOP > 0 && sel - MENU_TOP + 1 < h )) && [[ ${M_KIND[MENU_TOP - 1]} != I ]]; do
        (( MENU_TOP-- ))
    done
    (( sel >= MENU_TOP + h )) && MENU_TOP=$(( sel - h + 1 ))
    (( MENU_TOP > n - h )) && MENU_TOP=$(( n - h ))
    (( MENU_TOP < 0 )) && MENU_TOP=0
    end=$(( MENU_TOP + h ))

    title_line "$crumb"
    hr "$UI_W"; rule=$HR
    out=$'\033[H'"$TITLE$EL"$'\n'"$rule$EL"$'\n'
    if (( hdr )); then
        for (( i = 0; i < hdr; i++ )); do out+="${MENU_HEADER[i]}$EL"$'\n'; done
        out+="$rule$EL"$'\n'
    fi
    for (( i = MENU_TOP; i < end; i++ )); do
        menu_line "$i" $(( i == sel ))
        out+="$LINE$EL"$'\n'
    done

    # 底部横线上标出上下是否还有内容
    if (( MENU_TOP > 0 || end < n )); then
        hint=" "
        (( MENU_TOP > 0 )) && hint+="$G_UP 上面还有 "
        (( end < n )) && hint+="$G_DOWN 下面还有 "
        text_width "$hint"
        hr $(( UI_W - WIDTH ))
        out+="$HR$DIM$hint$NC$EL"$'\n'
    else
        out+="$rule$EL"$'\n'
    fi

    if [[ -n $msg ]]; then
        out+=" $RED$G_ERR $msg$NC"
    elif [[ -n $buf ]]; then
        out+=" 编号 $BOLD$CYAN$buf$NC${DIM}_   Enter 确认 $G_DOT 退格删除$NC"
    elif [[ -n ${MENU_HINT:-} ]]; then
        out+=" $DIM$MENU_HINT$NC"
    elif [[ -z $crumb ]]; then
        out+=" $DIM$G_UPDN 选择 $G_DOT Enter 执行 $G_DOT 输入编号直达 $G_DOT q 退出$NC"
    else
        out+=" $DIM$G_UPDN 选择 $G_DOT Enter 确认 $G_DOT Esc 返回$NC"
    fi
    printf '%s%s\033[J' "$out" "$EL"
}

# read_key：读一个按键放进 KEY：up down home end pgup pgdn enter esc bs space q 字母 数字 或 none
read_key() {
    local k='' c='' seq=''
    IFS= read -rsn1 k </dev/tty || return 1
    case $k in
        $'\e')
            if ! IFS= read -rsn1 -t 0.05 c </dev/tty; then KEY=esc; return 0; fi
            if [[ $c == '[' || $c == O ]]; then
                while IFS= read -rsn1 -t 0.05 c </dev/tty; do
                    seq+=$c
                    [[ $c == [A-Za-z~] ]] && break
                done
            fi
            case $seq in
                A) KEY=up ;;  B) KEY=down ;;  D) KEY=esc ;;
                H|1~|7~) KEY=home ;;  F|4~|8~) KEY=end ;;
                5~) KEY=pgup ;;  6~) KEY=pgdn ;;
                *) KEY=none ;;
            esac ;;
        '') KEY=enter ;;
        ' ') KEY=space ;;
        $'\x7f'|$'\b') KEY=bs ;;
        k|K) KEY=up ;;
        j|J) KEY=down ;;
        q|Q) KEY=q ;;
        [0-9]) KEY=$k ;;
        [a-zA-Z]) KEY=${k,} ;;
        *) KEY=none ;;
    esac
}

# menu_move <起点> <步数>：从起点往上（负数）或往下跳过非条目行，结果放进 MOVED，到头时循环
menu_move() {
    local i=$1 step=$2 n=${#M_KIND[@]} dir=1 k
    (( step < 0 )) && { dir=-1; step=$(( -step )); }
    for (( k = 0; k < step; k++ )); do
        i=$(( (i + dir + n) % n ))
        while [[ ${M_KIND[i]} != I ]]; do i=$(( (i + dir + n) % n )); done
    done
    MOVED=$i
}

menu_run() {
    local crumb=$1 back=$2 def=${3:-} sel=-1 i buf='' msg='' n=${#M_KIND[@]} old_int
    MENU_CHOICE=$back
    for (( i = 0; i < n; i++ )); do
        [[ ${M_KIND[i]} == I ]] || continue
        (( sel < 0 )) && sel=$i
        [[ -n $def && ${M_KEY[i]} == "$def" ]] && { sel=$i; break; }
    done
    (( sel >= 0 )) || return 0
    (( TUI )) || { menu_plain "$crumb" "$back"; return; }

    # 菜单打开时隐藏光标；Ctrl-C 退出前要把光标还原
    old_int=$(trap -p INT)
    trap 'printf "\033[?25h\n"; exit 130' INT
    MENU_TOP=0
    clear_screen
    printf '\033[?25l'
    while true; do
        menu_draw "$crumb" "$sel" "$buf" "$msg"
        msg=''
        read_key || break
        case $KEY in
            up)   menu_move "$sel" -1; sel=$MOVED; buf='' ;;
            down) menu_move "$sel" 1;  sel=$MOVED; buf='' ;;
            pgup) menu_move "$sel" -5; sel=$MOVED; buf='' ;;
            pgdn) menu_move "$sel" 5;  sel=$MOVED; buf='' ;;
            home) menu_move $(( n - 1 )) 1; sel=$MOVED; buf='' ;;
            end)  menu_move 0 -1; sel=$MOVED; buf='' ;;
            [0-9])
                (( ${#buf} >= 2 )) && buf=''
                buf+=$KEY
                menu_find "$buf" && sel=$FOUND ;;
            bs)
                buf=${buf%?}
                [[ -n $buf ]] && menu_find "$buf" && sel=$FOUND ;;
            enter)
                if [[ -n $buf ]]; then
                    if ! menu_find "$buf"; then msg="没有编号 $buf"; buf=''; continue; fi
                    sel=$FOUND
                fi
                MENU_CHOICE=${M_KEY[sel]}
                break ;;
            q) MENU_CHOICE=$back; break ;;
            esc)
                if [[ -n $buf ]]; then buf=''
                elif [[ -n $crumb ]]; then MENU_CHOICE=$back; break
                fi ;;
        esac
    done
    printf '\033[?25h'
    if [[ -n $old_int ]]; then eval "$old_int"; else trap - INT; fi
}

# 不支持方向键时：列出全部条目，输入编号
menu_plain() {
    local crumb=$1 back=$2 i reply rule
    while true; do
        clear_screen
        term_size
        title_line "$crumb"
        hr "$UI_W"; rule=$HR
        printf '%s\n%s\n' "$TITLE" "$rule"
        if (( ${#MENU_HEADER[@]} )); then
            printf '%s\n' "${MENU_HEADER[@]}"
            printf '%s\n' "$rule"
        fi
        for (( i = 0; i < ${#M_KIND[@]}; i++ )); do
            menu_line "$i" 0
            printf '%s\n' "$LINE"
        done
        printf '%s\n' "$rule"
        read -r -p " 请输入编号（q 返回）: " reply </dev/tty || { MENU_CHOICE=$back; return; }
        [[ -z $reply ]] && continue
        [[ $reply == [qQ] ]] && { MENU_CHOICE=$back; return; }
        if menu_find "$reply"; then
            MENU_CHOICE=$reply
            return
        fi
        warn "没有编号：$reply"
        sleep 1
    done
}
# <<< lib/menu.sh <<<

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
        printf '在线下载 %s' "${REPO_RAW#https://}"
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

    printf ' %s下载 %s ...%s\n' "$DIM" "$rel" "$NC" >&2
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

# 子脚本输出前后的分隔线
run_banner() {
    local label=" $1 " w
    term_size
    text_width "$label"
    hr $(( UI_W - WIDTH - 3 ))
    printf '%s%s%s%s%s\n' "$DIM" "$G_HR$G_HR" "$label" "$NC" "$HR"
}

# run_script [变量=值 ...] <相对路径> [参数...]
# 子脚本在独立进程里运行；Ctrl-C 只会中断子脚本，然后回到菜单
run_script() {
    local envs=() path rel rc
    while [[ ${1:-} =~ ^[A-Z_][A-Z0-9_]*= ]]; do envs+=("$1"); shift; done
    rel=$1; shift
    path=$(fetch_script "$rel") || return 127

    run_banner "运行 $rel${1:+ $*}"
    printf '\n'
    trap ':' INT
    # LT_FROM_MENU=1：子脚本菜单里的「退出」显示成「返回主菜单」
    env LT_FROM_MENU=1 "${envs[@]}" bash "$path" "$@"
    rc=$?
    trap 'printf "\n"; exit 130' INT

    printf '\n'
    run_banner "结束"
    case $rc in
        0)   ok "$rel 执行完毕" ;;
        130) warn "$rel 已被中断（Ctrl-C）" ;;
        *)   warn "$rel 退出码 $rc，请查看上面的输出" ;;
    esac
    return $rc
}

# -----------------------------------------------------------------------------
# 系统信息与各项状态（状态格式见 badge）
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
    VIRT=$(systemd-detect-virt 2>/dev/null) || VIRT=''
    [[ $VIRT == none ]] && VIRT='物理机'
}

status_kernel() {
    if [[ $(uname -r) == *xanmod* ]]; then
        printf 'on|正在使用 XanMod'
    elif dpkg-query -W -f='${db:Status-Abbrev}\n' 'linux-xanmod*' 2>/dev/null | grep -q '^ii'; then
        printf 'warn|已安装 XanMod，重启后生效'
    else
        printf 'off|未安装'
    fi
}

status_singbox() {
    local v
    if command -v sing-box >/dev/null 2>&1; then
        v=$(sing-box version 2>/dev/null | awk 'NR == 1 { print $NF }')
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            printf 'on|%s 运行中' "$v"
        else
            printf 'warn|%s 未运行' "$v"
        fi
    else
        printf 'off|未安装'
    fi
}

status_q() {
    if command -v q >/dev/null 2>&1; then printf 'on|已安装'; else printf 'off|未安装'; fi
}

status_swap() {
    local mb
    mb=$(awk '/^SwapTotal:/ { print int($2 / 1024); exit }' /proc/meminfo)
    if (( ${mb:-0} > 0 )); then
        printf 'on|%s %s swappiness %s' \
            "$(awk -v m="$mb" 'BEGIN { if (m >= 1024) printf "%.1fG", m / 1024; else printf "%dM", m }')" \
            "$G_DOT" "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
    else
        printf 'warn|未启用'
    fi
}

status_ssh_login() {
    local sshd pw
    sshd=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
    [[ -x $sshd ]] || { printf 'off|未安装 sshd'; return; }
    pw=$("$sshd" -T 2>/dev/null | awk '$1 == "passwordauthentication" { print $2; exit }')
    case $pw in
        no)  printf 'on|已禁止密码登录' ;;
        yes) printf 'warn|允许密码登录' ;;
        *)   printf 'info|未知' ;;
    esac
}

status_docker() {
    local v
    if command -v docker >/dev/null 2>&1; then
        v=$(docker --version 2>/dev/null | awk '{ gsub(",", "", $3); print $3 }')
        if systemctl is-active --quiet docker 2>/dev/null; then
            printf 'on|%s 运行中' "$v"
        else
            printf 'warn|%s 未运行' "$v"
        fi
    else
        printf 'off|未安装'
    fi
}

status_go() {
    if [[ -x /usr/local/go/bin/go ]]; then
        printf 'on|%s' "$(/usr/local/go/bin/go version 2>/dev/null | awk '{ print $3 }')"
    else
        printf 'off|未安装'
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
        printf 'on|%s' "${parts[*]}"
    else
        printf 'off|未安装'
    fi
}

# -----------------------------------------------------------------------------
# 主菜单
# -----------------------------------------------------------------------------
# cell <标签> <文字> <格宽>：固定宽度的一格（标签暗色），放进 CELL
cell() {
    fit "$2" $(( $3 - 7 ))
    pad $(( $3 - 7 - WIDTH ))
    CELL=" $DIM$1$NC  $FIT$PAD "
}

# usage_cell <标签> <百分比> <已用> <总量> <格宽> <条的格数>：带占用条的一格，放进 CELL
usage_cell() {
    local n=$6 text
    text="$2% $3/$4"
    bar "$2" "$n"
    fit "$text" $(( $5 - 8 - n ))
    pad $(( $5 - 8 - n - WIDTH ))
    CELL=" $DIM$1$NC  $BAR $FIT$PAD "
}

main_header() {
    local lw rw bn=10 mt=0 ma=0 dt=0 du=0 up=0 load ut a b c d e f hu ht
    lw=$(( UI_W * 55 / 100 ))
    rw=$(( UI_W - lw ))
    (( rw < 30 )) && { lw=$UI_W; rw=$UI_W; }
    (( rw < 34 )) && bn=6   # 两个占用条一样长

    read -r mt ma < <(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { print t + 0, a + 0 }' /proc/meminfo 2>/dev/null)
    read -r dt du < <(df -Pk / 2>/dev/null | awk 'NR == 2 { print $2 + 0, $3 + 0 }')
    up=$(awk '{ print int($1) }' /proc/uptime 2>/dev/null)
    load=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)
    up=${up:-0}
    if (( up >= 86400 )); then ut="$(( up / 86400 )) 天 $(( up % 86400 / 3600 )) 小时"
    elif (( up >= 3600 )); then ut="$(( up / 3600 )) 小时 $(( up % 3600 / 60 )) 分"
    else ut="$(( up / 60 )) 分钟"; fi

    cell 系统 "$OS_NAME" "$lw"; a=$CELL
    cell 主机 "$(hostname 2>/dev/null)${VIRT:+ $G_DOT $VIRT}" "$rw"; b=$CELL
    cell 内核 "$(uname -r) $G_DOT $ARCH" "$lw"; c=$CELL
    cell 运行 "$ut $G_DOT 负载 ${load:-?}" "$rw"; d=$CELL
    human_kb $(( ${mt:-0} - ${ma:-0} )); hu=$HUMAN; human_kb "${mt:-0}"; ht=$HUMAN
    usage_cell 内存 $(( ${mt:-0} ? (${mt:-0} - ${ma:-0}) * 100 / ${mt:-1} : 0 )) "$hu" "$ht" "$lw" "$bn"; e=$CELL
    human_kb "${du:-0}"; hu=$HUMAN; human_kb "${dt:-0}"; ht=$HUMAN
    usage_cell 磁盘 $(( ${dt:-0} ? ${du:-0} * 100 / ${dt:-1} : 0 )) "$hu" "$ht" "$rw" "$bn"; f=$CELL

    if (( lw == UI_W )); then
        MENU_HEADER=("$a" "$c" "$e" "$b" "$d" "$f")
    else
        MENU_HEADER=("$a$b" "$c$d" "$e$f")
    fi
    cell 脚本 "$(script_source)" "$UI_W"
    MENU_HEADER+=("$DIM${CELL//$NC/}$NC")
    (( IS_CONTAINER )) && MENU_HEADER+=(" $YELLOW$G_WARN 当前在容器里：内核、Swap、重装系统等功能不可用$NC")
    [[ $OS_ID == debian ]] || MENU_HEADER+=(" $YELLOW$G_WARN 这些脚本为 Debian 12 / 13 编写，当前系统可能不完全兼容$NC")
}

build_main_menu() {
    menu_reset
    main_header
    menu_group "系统维护"
    menu_item 1  "系统清理"                "info|旧内核、日志、缓存、Docker，逐项勾选"
    menu_item 2  "Swap 管理"               "$(status_swap)"
    menu_item 3  "XanMod 内核 + 网络优化"  "$(status_kernel)"
    menu_item 4  "SSH 漏洞检查"            "info|CVE-2024-6387 regreSSHion，只检查"
    menu_item 5  "SSH 禁止密码登录"        "$(status_ssh_login)"
    menu_item 6  "修改主机名"              "info|当前 $(hostname 2>/dev/null)"
    menu_item 7  "内核漏洞 CVE-2026-98432" "info|严重 9.8 $G_DOT 检测 / 升级修复 / 临时缓解"
    menu_group "软件与界面"
    menu_item 8  "sing-box 节点"           "$(status_singbox)"
    menu_item 9  "q（DNS 查询工具）"       "$(status_q)"
    menu_item 10 "Go 语言"                 "$(status_go)"
    menu_item 11 "Docker + Compose"        "$(status_docker)"
    menu_item 12 "SSH 登录面板（motd）"    "$(status_motd)"
    menu_group "第三方脚本" "运行时从上游下载，原样执行"
    menu_item 13 "TcpQuality 网络质量"     "info|ibsgss/TcpQuality"
    menu_item 14 "NodeQuality 综合测试"    "warn|结果会上传到 nodequality.com"
    menu_item 15 "DD 重装：InstallNET"     "danger|清空系统盘 $G_DOT leitbogioro/Tools"
    menu_item 16 "DD 重装：reinstall"      "danger|清空系统盘 $G_DOT bin456789/reinstall"
    menu_blank
    menu_item 0  "退出"
}

# -----------------------------------------------------------------------------
# 各功能
# -----------------------------------------------------------------------------
do_clear() {
    menu_reset
    MENU_HEADER=(" ${DIM}先扫描并列出每一项能释放多少空间，逐项勾选，最后确认才删除。${NC}")
    menu_item 1 "开始清理" "info|扫描后逐项勾选"
    menu_item 2 "预演"     "info|同样选择，只显示将执行的命令，不做修改"
    menu_blank
    menu_item 0 "返回"
    menu_run "系统清理" 0
    case $MENU_CHOICE in
        1) page "系统清理"; run_script "$CLEAR" ;;
        2) page "系统清理 $G_ARROW 预演"; run_script "$CLEAR" --dry-run ;;
        *) return 0 ;;
    esac
    pause
}

do_xanmod() {
    page "XanMod 内核 + 网络优化"
    if [[ $ARCH != x86_64 ]]; then
        warn "XanMod 只提供 x86_64 内核，当前架构是 $ARCH。"
        pause; return
    fi
    if (( IS_CONTAINER )); then
        warn "当前在容器里，安装的内核不会被使用（容器共用宿主机内核）。"
        pause; return
    fi
    info " 该脚本会："
    info "   $G_DOT 添加 XanMod 软件源，并执行一次完整的系统升级（dist-upgrade）"
    info "   $G_DOT 按 CPU 级别安装 XanMod 内核（会让你选择 LTS / MAIN / RT）"
    info "   $G_DOT 没有交换空间时创建 1G 的 /swapfile"
    info "   $G_DOT 写入网络优化参数 /etc/sysctl.d/99-xanmod-optimizations.conf（BBR 等）"
    info "   $G_DOT 最后询问是否重启"
    printf '\n'
    ask_yn "确定继续吗？" n || return 0
    run_script "$XANMOD"
    pause
}

do_ssh_check() {
    local rc
    page "SSH 漏洞检查（CVE-2024-6387）"
    run_script "$SSH_CHECK"
    rc=$?
    printf '\n'
    case $rc in
        0) ok "结论：不受 regreSSHion 影响。" ;;
        1) printf '%s%s 结论：受影响，请尽快升级 openssh-server：apt update && apt install openssh-server%s\n' "$RED" "$G_ERR" "$NC" ;;
        2) info " 结论：系统里没有 sshd / ssh，无需处理。" ;;
        3) info " 结论：无法识别 OpenSSH 版本，请手动执行 sshd -V 查看。" ;;
    esac
    pause
}

# 自带菜单的子脚本：退出它就回到这里，只有出错时才停下来让你看输出
run_own_menu() {
    page "$1"
    run_script "$2" || pause
}

# 简单的软件源安装类：q
do_apt_install() {
    local name=$1 script=$2
    page "安装 $name"
    badge "$3" 40
    info " 当前：$BADGE"
    printf '\n'
    info " 会添加 $name 官方 apt 软件源和签名密钥，然后用 apt 安装；已安装时会升级到最新版。"
    printf '\n'
    ask_yn "确定继续吗？" y || return 0
    run_script "$script"
    pause
}

do_go() {
    local ver
    page "安装 Go 语言"
    badge "$(status_go)" 40
    info " 当前：$BADGE"
    info " 安装到 /usr/local/go，PATH 写入 /etc/profile.d/go.sh。"
    printf '\n'
    ver=$(ask_value "版本号（latest = 官方最新稳定版，如 1.23.4）" latest '^(latest|[0-9]+\.[0-9]+(\.[0-9]+)?)$')
    [[ $ver == latest ]] && ver=''
    run_script "GO_VERSION=$ver" "$GOLANG"
    pause
}

# ---- 登录面板 motd -----------------------------------------------------------
# 删除所有已安装的 logo，大小写两种文件名都删
remove_logos() { rm -f -- "$MOTD_DIR"/20-[Dd][Ss][Hh]*; }

motd_install_logo() {
    local logos=(20-DSH 20-DSH-32 20-DSH-mono 20-DSH-mono-32) f src
    menu_reset
    MENU_HEADER=(" ${DIM}彩色版需要终端支持 256 色。只保留一个 logo，换新的时旧的会被删除。${NC}")
    menu_item 1 "20-DSH"         "info|彩色 40×20"
    menu_item 2 "20-DSH-32"      "info|彩色 32×16（窄屏）"
    menu_item 3 "20-DSH-mono"    "info|黑白 40×20（任何终端都能显示）"
    menu_item 4 "20-DSH-mono-32" "info|黑白 32×16"
    menu_item 5 "不要 logo"      "info|删除已安装的"
    menu_blank
    menu_item 0 "返回"
    menu_run "登录面板 $G_ARROW logo" 0
    case $MENU_CHOICE in
        [1-4]) f=${logos[MENU_CHOICE - 1]} ;;
        5)
            page "登录面板 $G_ARROW logo"
            remove_logos
            ok "已删除 logo"
            pause; return ;;
        *) return ;;
    esac

    page "登录面板 $G_ARROW logo $G_ARROW $f"
    src=$(fetch_script "update-motd/$f") || { pause; return; }
    info " ${DIM}预览：${NC}"
    printf '\n'
    sh "$src"
    printf '\n'
    if ask_yn "安装这个 logo 吗？" y; then
        mkdir -p "$MOTD_DIR"
        # 只保留一个 logo，避免登录时连续打印两个（包括以前手动装的小写 20-dsh-*）
        remove_logos
        install -m 0755 "$src" "$MOTD_DIR/$f"
        ok "已安装 $MOTD_DIR/$f"
        pause
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
    local done=0
    if [[ -f $MOTD_DIR/10-uname && -x $MOTD_DIR/10-uname ]]; then
        chmod -x "$MOTD_DIR/10-uname" && ok "已停用 $MOTD_DIR/10-uname" && done=1
    fi
    if [[ -s /etc/motd ]]; then
        [[ -e $MOTD_BACKUP ]] || cp -a /etc/motd "$MOTD_BACKUP"
        : > /etc/motd
        ok "已清空 /etc/motd（原内容备份在 $MOTD_BACKUP）"
        done=1
    fi
    (( done )) || info " 默认内容已经是隐藏状态，不需要修改。"
}

motd_preview() {
    run_banner "登录时将显示"
    if command -v run-parts >/dev/null 2>&1 && [[ -d $MOTD_DIR ]]; then
        run-parts "$MOTD_DIR"
    fi
    [[ -s /etc/motd ]] && cat /etc/motd
    run_banner "结束"
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
    local last=1
    while true; do
        menu_reset
        badge "$(status_motd)" $(( UI_W - 8 ))
        MENU_HEADER=(" ${DIM}当前${NC}  $BADGE"
                     " ${DIM}SSH 登录时显示的 logo 和系统信息面板，文件放在 $MOTD_DIR${NC}")
        menu_item 1 "安装 / 更换 logo"     "info|4 种可选，彩色或黑白"
        menu_item 2 "安装系统信息面板"     "info|负载、内存、磁盘、连接、流量、最近登录"
        menu_item 3 "隐藏 Debian 默认内容" "info|内核版本行和 /etc/motd 免责声明"
        menu_item 4 "预览登录面板"
        menu_item 5 "卸载，恢复默认"
        menu_blank
        menu_item 0 "返回主菜单"
        menu_run "SSH 登录面板" 0 "$last"
        last=$MENU_CHOICE
        case $MENU_CHOICE in
            1) motd_install_logo ;;
            2) page "登录面板 $G_ARROW 系统信息面板"; motd_install_sysinfo; pause ;;
            3) page "登录面板 $G_ARROW 隐藏默认内容"; motd_hide_default; pause ;;
            4) page "登录面板 $G_ARROW 预览"; motd_preview; pause ;;
            5) page "登录面板 $G_ARROW 卸载"; motd_uninstall; pause ;;
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
        printf ' %s下载 %s ...%s\n' "$DIM" "$url" "$NC" >&2
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
    printf '\n'
    run_banner "第三方脚本 ${path##*/}${1:+ $(mask_args "$@")}"
    printf '\n'
    trap ':' INT
    bash "$path" "$@" </dev/tty
    rc=$?
    trap 'printf "\n"; exit 130' INT
    printf '\n'
    run_banner "结束"
    return $rc
}

# read_args <提示>：读一行参数，按空格拆分放进 ARGS（不支持引号）
read_args() {
    ARGS=()
    read -r -a ARGS -p " $YELLOW?$NC $1" </dev/tty || ARGS=()
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
        read -r -s -p " $YELLOW?$NC $1: " p1 </dev/tty || p1=''
        printf '\n' >&2
        [[ -z $p1 ]] && { PASSWORD=''; return; }
        # InstallNET 把密码不加引号地传给 openssl，含空格、引号、$ 等字符会出错
        if [[ ! $p1 =~ $re ]]; then
            printf '   %s密码至少 8 位，只能包含字母、数字和 _@%%+=.,:-%s\n' "$RED" "$NC" >&2
            continue
        fi
        read -r -s -p " $YELLOW?$NC 再输入一次: " p2 </dev/tty || p2=''
        printf '\n' >&2
        [[ $p1 == "$p2" ]] && { PASSWORD=$p1; return; }
        printf '   %s两次输入不一致。%s\n' "$RED" "$NC" >&2
    done
}

ask_port() {
    local p
    while true; do
        p=$(ask_value "$1" 22 '^[0-9]{1,5}$')
        (( p >= 1 && p <= 65535 )) && { printf '%s' "$p"; return; }
        printf '   %s端口范围是 1-65535。%s\n' "$RED" "$NC" >&2
    done
}

reboot_now() {
    info " 系统将在 5 秒后重启（Ctrl-C 取消）..."
    sleep 5 && { systemctl reboot 2>/dev/null || reboot; }
}

do_tcpquality() {
    local path rc
    page "TcpQuality 网络质量测试"
    info " ${DIM}第三方脚本 github.com/ibsgss/TcpQuality，从上游下载，原样运行${NC}"
    printf '\n'
    info " 默认下载一个临时的 Debian 根文件系统，在里面测试，不往本机装软件，结束后自动删除。"
    info " 常用参数：-v4（只测 IPv4）、--intl、--all、--no-rootfs（直接在本机运行）、--help（查看全部）"
    printf '\n'
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
    page "NodeQuality 综合测试"
    info " ${DIM}第三方脚本 github.com/LloydAsp/NodeQuality，从上游下载，原样运行${NC}"
    printf '\n'
    info " 会依次询问要做哪些测试：硬件质量、IP 质量、网络质量、回程路由（直接回车 = 都做）。"
    info " 做法：下载一个临时测试系统到 /root/.nodequality<时间>，挂载 /proc /sys /dev 后"
    info " chroot 进去测试，结束后卸载并删除。"
    printf '\n'
    warn "测试结果会上传到 nodequality.com 生成分享链接，内容包括本机 IP 和 IP 质量检测结果。"
    printf '\n'
    info " 可选参数：-4（只测 IPv4）、-6（只测 IPv6）、-E（英文输出）"
    printf '\n'
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
    info " NodeQuality 已结束（它无论成功与否都返回退出码 $rc）。结果链接在上面的输出里。"
    if compgen -G '/root/.nodequality*' >/dev/null; then
        warn "/root 下留有 .nodequality* 目录，说明清理没有完成。请先重启，再删除这个目录（不要在挂载未卸载时删除）。"
    fi
    pause
}

# 两个重装脚本共用：容器里不能重装
dd_container_check() {
    (( IS_CONTAINER )) || return 0
    page "DD 重装系统"
    warn "当前在容器里，容器没有自己的内核和引导，无法重装系统。"
    pause
    return 1
}

# 选好系统之后、执行之前的提醒
dd_precheck() {
    warn "重装会清空整块系统盘（所有分区、所有数据），无法恢复！"
    info "   开始前请确认：数据已经备份；会用服务商的 VNC / 控制台（网络配置不对时只能从那里救）。"
    if command -v lsblk >/dev/null 2>&1; then
        printf '\n'
        info " ${DIM}本机磁盘：${NC}"
        lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | sed 's/^/   /'
    fi
    printf '\n'
}

# dd_confirm <要显示的命令>：要求输入主机名确认
dd_confirm() {
    local name reply
    name=$(hostname 2>/dev/null)
    name=${name:-yes}
    printf '\n 将要执行：%s%s%s\n\n' "$BOLD" "$1" "$NC"
    read -r -p " $RED?$NC 确认重装请输入本机主机名 $BOLD$name$NC: " reply </dev/tty || reply=''
    if [[ $reply != "$name" ]]; then
        info " 输入不一致，已取消，没有做任何修改。"
        return 1
    fi
}

do_installnet() {
    local path rc c port args=() crumb="DD 重装 $G_ARROW InstallNET"
    dd_container_check || return
    menu_reset
    MENU_HEADER=(" $RED$G_WARN 重装会清空整块系统盘（所有分区、所有数据），无法恢复！$NC"
                 " ${DIM}只写好 GRUB 启动项，手动重启后才开始重装。${NC}"
                 " ${DIM}第三方脚本 leitbogioro/Tools，从上游下载，原样运行。${NC}")
    menu_item 1 "Debian 13" "info|trixie"
    menu_item 2 "Debian 12" "info|bookworm"
    menu_item 3 "自定义参数" "info|如 -ubuntu 24.04、-dd <镜像网址>、-mirror <源>"
    menu_blank
    menu_item 0 "返回"
    menu_run "$crumb" 0
    c=$MENU_CHOICE
    [[ $c == 0 ]] && return
    page "$crumb"
    dd_precheck
    case $c in
        1) args=(-debian 13) ;;
        2) args=(-debian 12) ;;
        3) read_args "参数: "; args=("${ARGS[@]}"); (( ${#args[@]} )) || return 0 ;;
    esac
    if [[ $c != 3 ]]; then
        info " 不设置密码时，InstallNET 会用它内置的公开默认密码 $INSTALLNET_DEFAULT_PW。"
        ask_password "新系统的 root 密码（不显示；直接回车 = 用默认密码）"
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
    info " InstallNET 成功和失败都返回退出码 1，请看上面最后几行："
    info "   $G_DOT [Finish] Input 'reboot' to continue ...  表示准备好了，重启后开始重装"
    info "   $G_DOT [Error] ...                               表示失败，按提示处理"
    printf '\n'
    if ask_yn "已经看到 [Finish]，现在重启开始重装吗？" n; then
        reboot_now
    else
        info " 稍后执行 reboot 即可开始重装。"
    fi
    pause
}

do_reinstall() {
    local path rc c port args=() crumb="DD 重装 $G_ARROW reinstall"
    dd_container_check || return
    menu_reset
    MENU_HEADER=(" $RED$G_WARN 重装会清空整块系统盘（所有分区、所有数据），无法恢复！$NC"
                 " ${DIM}可装各种 Linux、Windows 或 dd 镜像；重启后才开始，重启前可以取消。${NC}"
                 " ${DIM}第三方脚本 bin456789/reinstall，从上游下载，原样运行。${NC}")
    menu_item 1 "Debian 13"    "info|trixie"
    menu_item 2 "Debian 12"    "info|bookworm"
    menu_item 3 "Ubuntu 24.04" "info|noble"
    menu_item 4 "自定义参数"   "info|如 alpine 3.22、dd --img=<网址>、--help"
    menu_blank
    menu_item 0 "返回"
    menu_run "$crumb" 0
    c=$MENU_CHOICE
    [[ $c == 0 ]] && return
    page "$crumb"
    case $c in
        1) args=(debian 13) ;;
        2) args=(debian 12) ;;
        3) args=(ubuntu 24.04) ;;
        4) read_args "参数: "; args=("${ARGS[@]}"); (( ${#args[@]} )) || return 0 ;;
    esac
    local help=0
    has_arg -h "${args[@]}" || has_arg --help "${args[@]}" && help=1
    (( help )) || dd_precheck
    if [[ $c != 4 ]]; then
        port=$(ask_port "新系统的 SSH 端口")
        [[ $port != 22 ]] && args+=(--ssh-port "$port")
        info " 用户名和密码由 reinstall.sh 自己询问（输入时会显示在屏幕上；密码留空则随机生成，结束时显示）。"
        info " 想用密钥登录请选「自定义参数」，加上 --ssh-key <公钥>。"
    fi
    if (( ! help )); then
        dd_confirm "bash reinstall.sh $(mask_args "${args[@]}")" || { pause; return; }
    fi
    path=$(fetch_remote reinstall.sh "$REINSTALL_URL" "$REINSTALL_URL_CN") || { pause; return; }
    run_remote "$path" "${args[@]}"
    rc=$?
    case $rc in
        0)
            if (( ! help )); then
                menu_reset
                MENU_HEADER=(" $GREEN$G_OK reinstall.sh 已准备好，重启后开始重装$NC")
                menu_item 1 "现在重启，开始重装"
                menu_item 2 "取消这次重装"     "info|执行 reinstall.sh reset"
                menu_item 0 "稍后自己执行 reboot"
                menu_run "$crumb" 0
                case $MENU_CHOICE in
                    1) page "$crumb"; reboot_now ;;
                    2) page "$crumb"; run_remote "$path" reset && ok "已取消，重启后仍是原系统" ;;
                    *) page "$crumb"
                       info " 稍后执行 reboot 即可开始重装。想取消时运行："
                       info "   curl -fsSL $REINSTALL_URL -o reinstall.sh && bash reinstall.sh reset" ;;
                esac
            fi ;;
        130) warn "已中断（Ctrl-C）" ;;
        *)   warn "reinstall.sh 退出码 $rc，没有准备好重装，请查看上面的输出" ;;
    esac
    pause
}

# build.sh 在生成整合版时，会把所有子脚本的内容插到下面这一行（在线版里这一行什么都不做）
# @@LT_PAYLOADS@@

# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
用法: sudo bash ${0##*/}    打开交互式菜单

操作: ↑↓ 或 j / k 选择，Enter 执行；也可以直接输入编号再按 Enter。q 退出，子菜单里 Esc 返回。

环境变量:
  LT_REPO_RAW=<地址>   在线下载子脚本的地址（自己的 fork 或镜像）
  LT_ASCII=1           只用 ASCII 字符（终端里线条、圆点显示不正常时用）
  LT_PLAIN=1           不用方向键菜单，改为输入编号
EOF
}

main() {
    case ${1:-} in
        -h|--help) usage; exit 0 ;;
    esac
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
    (( HAVE_TTY )) || die "需要在交互式终端里运行。"

    detect_system
    local last=1
    while true; do
        build_main_menu
        menu_run '' 0 "$last"
        last=$MENU_CHOICE
        case $MENU_CHOICE in
            1)  do_clear ;;
            2)  run_own_menu "Swap 管理" "$SWAP_SH" ;;
            3)  do_xanmod ;;
            4)  do_ssh_check ;;
            5)  run_own_menu "SSH 禁止密码登录" "$SSH_KEYONLY" ;;
            6)  page "修改主机名"; run_script "$HOSTNAME_SH"; pause ;;
            7)  run_own_menu "内核漏洞 CVE-2026-98432" "$CVE_98432_SH" ;;
            8)  run_own_menu "sing-box 节点" "$SINGBOX" ;;
            9)  do_apt_install "q" "$Q_SH" "$(status_q)" ;;
            10) do_go ;;
            11) run_own_menu "Docker + Compose" "$DOCKER_SH" ;;
            12) do_motd ;;
            13) do_tcpquality ;;
            14) do_nodequality ;;
            15) do_installnet ;;
            16) do_reinstall ;;
            *)  clear_screen; info "再见。"; exit 0 ;;
        esac
    done
}

main "$@"
