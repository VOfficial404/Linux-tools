#!/bin/bash

# XanMod 内核安装脚本
# 适用于 Debian 12+ (bookworm, trixie, sid)
#
# 先选好内核分支，再开始修改系统：没有 swap 时建 1G swap、升级系统、
# 导入 XanMod 密钥和软件源、按 CPU 微架构级别安装内核、写入网络优化参数。

# 启用严格错误检查
set -euo pipefail

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

log_info()  { step "$1"; }
log_ok()    { ok "$1"; }
log_warn()  { warn "$1"; }
log_error() { printf ' %s%s %s%s\n' "$RED" "$G_ERR" "$1" "$NC" >&2; }

# apt 全程非交互；配置文件冲突时保留本地版本
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
  log_error "请使用root权限运行此脚本：sudo bash $0"
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

# 检查是否支持的版本
case "$DEBIAN_CODENAME" in
  bookworm|trixie|forky|sid) ;;
  *)
    log_warn "检测到 $PRETTY_NAME（$DEBIAN_CODENAME），可能不被 XanMod 官方支持"
    ask_yn "是否继续？" n || exit 1
    ;;
esac

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

# 让用户选择内核分支，结果放进 KERNEL_CHOICE（0 = 取消）
choose_branch() {
  local cur
  cur=$(uname -r)
  if (( TUI )); then
    menu_reset
    kv 系统 "$PRETTY_NAME"; MENU_HEADER+=("$KV")
    kv CPU级别 "$CPU_LEVEL ${DIM}（自动检测，决定安装哪个构建）$NC"; MENU_HEADER+=("$KV")
    kv 运行内核 "$cur"; MENU_HEADER+=("$KV")
    menu_group "选择内核分支"
    menu_item 1 "LTS" "on|长期支持，推荐用于生产环境"
    menu_item 2 "MAIN" "info|主线，最新特性"
    menu_item 3 "RT" "info|实时内核，用于低延迟场景"
    menu_blank
    menu_item 0 "$BACK_LABEL"
    menu_run "安装 XanMod 内核" 0 1
    KERNEL_CHOICE=$MENU_CHOICE
  elif (( HAVE_TTY )); then
    printf '\n %s选择内核分支%s %s(CPU 级别 %s)%s\n' "$BOLD" "$NC" "$DIM" "$CPU_LEVEL" "$NC"
    printf '   %s1%s  LTS   %s长期支持，推荐用于生产环境%s\n' "$CYAN" "$NC" "$DIM" "$NC"
    printf '   %s2%s  MAIN  %s主线，最新特性%s\n' "$CYAN" "$NC" "$DIM" "$NC"
    printf '   %s3%s  RT    %s实时内核，用于低延迟场景%s\n' "$CYAN" "$NC" "$DIM" "$NC"
    printf '   %s0%s  取消\n' "$CYAN" "$NC"
    KERNEL_CHOICE=$(ask_value "请选择" 1 '^[0-3]$')
  else
    KERNEL_CHOICE=1
  fi
}

# 菜单代码不按 set -e 的规矩写，选择期间先关掉
set +e
choose_branch
set -e

case "$KERNEL_CHOICE" in
  1) BRANCH="lts" ;;
  2) BRANCH="main" ;;
  3) BRANCH="rt" ;;
  *) clear_screen; info " 已取消，没有做任何修改。"; exit 0 ;;
esac

page "安装 XanMod 内核 $G_ARROW ${BRANCH^^}"
kv 系统 "$PRETTY_NAME（$DEBIAN_CODENAME）"; info "$KV"
kv CPU级别 "$CPU_LEVEL"; info "$KV"
kv 内核分支 "${BRANCH^^}"; info "$KV"
printf '\n'

# 创建交换空间函数
create_swap() {
  log_info "未检测到 SWAP，正在创建 1G 的交换空间..."

  if ! fallocate -l 1G /swapfile 2>/dev/null; then
    log_warn "fallocate 失败，尝试使用 dd 创建交换文件..."
    dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
  fi

  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile

  # 备份并添加到 fstab
  if ! grep -q '/swapfile' /etc/fstab; then
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  # swappiness 统一由后面的 /etc/sysctl.d/99-xanmod-optimizations.conf 设置
  # （Debian 13 已不再读取 /etc/sysctl.conf）

  swapon --show | sed 's/^/   /'
  log_ok "SWAP 创建成功"
}

# 检查现有交换空间：有任何一行输出就说明已有交换（分区、文件、zram 都算）
if [ -z "$(swapon --noheadings --show 2>/dev/null)" ]; then
  create_swap
else
  log_ok "已存在 SWAP 空间"
  swapon --show | sed 's/^/   /'
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
log_ok "GPG 密钥安装成功"

# 添加软件源
sources_list="/etc/apt/sources.list.d/xanmod-release.list"
log_info "配置 XanMod 软件源..."
echo "deb [signed-by=$keyring_path] http://deb.xanmod.org $DEBIAN_CODENAME main" > "$sources_list"
info "   ${DIM}$(cat "$sources_list")$NC"

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

log_info "正在安装 XanMod 内核：$KERNEL_PACKAGE"
if apt-get "${APT_OPTS[@]}" install -y "$KERNEL_PACKAGE"; then
  log_ok "XanMod 内核安装成功"
else
  log_error "内核安装失败，请检查上面的错误信息并重试"
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
  log_ok "网络优化配置已应用"
else
  log_warn "部分参数在当前内核上未能应用，重启进入 XanMod 内核后会自动生效"
fi

# 显示已安装的内核
section "已安装的内核"
dpkg -l | awk '$1 == "ii" && $2 ~ /^linux-(image|xanmod)/ { printf "   %-44s %s\n", $2, $3 }' || true

# 完成提示
term_size; hr "$UI_W"
printf '\n%s\n' "$HR"
log_ok "XanMod 内核安装完成！"
kv 内核包 "$KERNEL_PACKAGE"; info "$KV"
kv 优化配置 "$sysctl_conf"; info "$KV"
kv 运行内核 "$(uname -r) ${DIM}（重启后才会换成 XanMod）$NC"; info "$KV"
printf '\n'
log_warn "需要重启系统才能使用新内核"

# 重启提示
if ask_yn "是否现在重启系统？" n; then
  log_info "系统将在 5 秒后重启..."
  sleep 5
  reboot
else
  info " 请稍后手动重启系统。重启后用 ${CYAN}uname -r$NC 确认内核版本。"
fi
