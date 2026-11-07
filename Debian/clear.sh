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
# 工具函数
# -----------------------------------------------------------------------------
# 新装的 VPS 上 unattended-upgrades 经常持有 dpkg 锁，最多等 120 秒而不是直接失败
apt_get() { apt-get -o DPkg::Lock::Timeout=120 "$@"; }

# run：dry-run 只打印；平时静默执行，失败只警告不中断
run() {
    if (( DRY_RUN )); then
        printf '   %s$ %s%s\n' "$DIM" "$*" "$NC"
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

root_usage() { df -Ph / | awk 'NR == 2 { printf "已用 %s / 共 %s（%s）", $3, $2, $5 }'; }

# 系统概况的几行，放进 BANNER_ROWS（勾选列表的顶部也用它）
banner_rows() {
    BANNER_ROWS=()
    kv 系统 "$OS_NAME"; BANNER_ROWS+=("$KV")
    kv 运行内核 "$RUNNING_KERNEL"; BANNER_ROWS+=("$KV")
    (( IS_CONTAINER )) && { kv 环境 "${YELLOW}容器$NC"; BANNER_ROWS+=("$KV"); }
    kv 根分区 "$(root_usage)"; BANNER_ROWS+=("$KV")
    if (( DRY_RUN )); then
        kv 模式 "${YELLOW}DRY-RUN$NC ${DIM}只显示将执行的命令，不做任何修改$NC"; BANNER_ROWS+=("$KV")
    fi
    return 0
}

print_banner() {
    banner_rows
    term_size
    title_line "系统清理"
    hr "$UI_W"
    printf '%s\n%s\n' "$TITLE" "$HR"
    printf '%s\n' "${BANNER_ROWS[@]}"
    printf '%s\n' "$HR"
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
        ask_yn "仍然继续吗？" n || { info "   已跳过内核清理。"; return 0; }
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
        add_item journal "systemd 日志" "当前占用 ${usage:-未知}" 1 1 "按保留天数和总大小收缩，下一步可修改"
    else
        add_item journal "systemd 日志" "系统未以 systemd 运行" 0 0 ""
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
    local kb note="/tmp、/var/tmp 下超过 N 天没用过的文件，正在使用的不动"
    kb=$(tmp_find "$TMP_MAX_AGE_DAYS" -printf '%s\n' | bytes_to_kb)
    (( TMP_IS_TMPFS )) && note+="；/tmp 是内存盘，清理它释放的是内存"
    if (( kb > 0 )); then
        add_item tmp "临时文件" "超过 ${TMP_MAX_AGE_DAYS} 天未用的约 $(human_kb "$kb")" 1 1 "$note"
    else
        add_item tmp "临时文件" "没有超过 ${TMP_MAX_AGE_DAYS} 天未用的文件" 0 0 ""
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
count_on() {
    local i
    COUNT=0
    for i in "${!ITEM_ID[@]}"; do (( ITEM_ON[i] )) && COUNT=$(( COUNT + 1 )); done
    return 0
}

set_all() {
    local i
    for i in "${!ITEM_ID[@]}"; do
        if (( $1 && ITEM_AVAIL[i] )); then ITEM_ON[i]=1; else ITEM_ON[i]=0; fi
    done
}

# toggle <索引>：切换一项；没有可清理内容时提示放进 MSG
toggle() {
    if (( ITEM_AVAIL[$1] )); then
        ITEM_ON[$1]=$(( 1 - ITEM_ON[$1] ))
    else
        MSG="「${ITEM_TITLE[$1]}」没有需要清理的内容"
    fi
}

# check_build <选中索引>：把清理项目放进菜单，顶部是系统概况和选中项的说明
check_build() {
    local i sel=$1 box note
    menu_reset
    box=x; (( UNICODE )) && box=$G_OK
    for i in "${!ITEM_ID[@]}"; do
        if (( ! ITEM_AVAIL[i] )); then
            menu_item $(( i + 1 )) "[-] ${ITEM_TITLE[i]}" "off|${ITEM_INFO[i]}"
        elif (( ITEM_ON[i] )); then
            menu_item $(( i + 1 )) "[$box] ${ITEM_TITLE[i]}" "on|${ITEM_INFO[i]}"
        else
            menu_item $(( i + 1 )) "[ ] ${ITEM_TITLE[i]}" "info|${ITEM_INFO[i]}"
        fi
    done
    MENU_HEADER=("${BANNER_ROWS[@]}")
    note=${ITEM_NOTE[sel]}
    (( ITEM_AVAIL[sel] )) || note="这一项现在没有需要清理的内容"
    [[ -n $note ]] || note=${ITEM_TITLE[sel]}
    fit "$note" $(( UI_W - 12 ))
    kv 说明 "$CYAN$FIT$NC"; MENU_HEADER+=("$KV")
    count_on
    MENU_HINT="已选 $COUNT 项 $G_DOT Space 勾选 $G_DOT a 全选 $G_DOT n 全不选 $G_DOT Enter 下一步 $G_DOT q 退出"
}

# 勾选列表：方向键移动，空格或编号勾选，a 全选，n 全不选，Enter 下一步，q / Esc 退出
choose_items() {
    (( ASSUME_YES )) && return
    (( TUI )) || { choose_items_plain; return; }
    local sel=0 n=${#ITEM_ID[@]} old_int quit=0
    MSG=''
    old_int=$(trap -p INT)
    trap 'printf "\033[?25h\n"; exit 130' INT
    MENU_TOP=0
    clear_screen
    printf '\033[?25l'
    while true; do
        check_build "$sel"
        menu_draw "系统清理" "$sel" '' "$MSG"
        MSG=''
        read_key || { quit=1; break; }
        case $KEY in
            up)    sel=$(( (sel + n - 1) % n )) ;;
            down)  sel=$(( (sel + 1) % n )) ;;
            home|pgup) sel=0 ;;
            end|pgdn)  sel=$(( n - 1 )) ;;
            space) toggle "$sel" ;;
            [1-9])
                if (( KEY <= n )); then sel=$(( KEY - 1 )); toggle "$sel"; fi ;;
            a) set_all 1 ;;
            n) set_all 0 ;;
            enter)
                count_on
                (( COUNT )) && break
                MSG="还没有勾选任何项目（Space 勾选，q 退出）" ;;
            q|esc) quit=1; break ;;
        esac
    done
    printf '\033[?25h'
    if [[ -n $old_int ]]; then eval "$old_int"; else trap - INT; fi
    if (( quit )); then
        clear_screen
        info " 已退出，没有做任何修改。"
        exit 0
    fi
}

# 没有方向键时（LT_PLAIN=1 或终端不支持）：输入编号切换
show_menu() {
    local i mark
    section "可清理的项目"
    for i in "${!ITEM_ID[@]}"; do
        if (( ! ITEM_AVAIL[i] )); then
            printf '  %s[-] %d  %s  %s%s\n' "$DIM" "$((i + 1))" "${ITEM_TITLE[i]}" "${ITEM_INFO[i]}" "$NC"
            continue
        fi
        mark=' '
        (( ITEM_ON[i] )) && mark="$GREEN$G_OK$NC"
        printf '  [%s] %s%d%s  %s  %s%s%s\n' "$mark" "$CYAN" "$((i + 1))" "$NC" "${ITEM_TITLE[i]}" "$DIM" "${ITEM_INFO[i]}" "$NC"
        [[ -n ${ITEM_NOTE[i]} ]] && printf '         %s%s%s\n' "$DIM" "${ITEM_NOTE[i]}" "$NC"
    done
}

choose_items_plain() {
    local input tok i toks
    while true; do
        show_menu
        printf '\n %s输入编号切换选中（可输入多个，如 "5 8"），a 全选，n 全不选，回车下一步，q 退出%s\n' "$DIM" "$NC"
        read -r -p ' > ' input </dev/tty || input=q
        case "$input" in
            '')
                count_on
                (( COUNT )) && return
                warn "还没有勾选任何项目" ;;
            q|Q)  info " 已退出，没有做任何修改。"; exit 0 ;;
            a|A)  set_all 1 ;;
            n|N)  set_all 0 ;;
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
    local p
    if is_on kernels; then
        section "旧内核"
        for p in "${KERNEL_PURGE[@]}"; do printf '   %s%s%s 删除  %s\n' "$RED" "$G_ERR" "$NC" "$p"; done
        for p in "${KERNEL_KEEP[@]}"; do printf '   %s%s%s 保留  %s\n' "$GREEN" "$G_OK" "$NC" "$p"; done
    fi
    if is_on journal; then
        section "systemd 日志"
        JOURNAL_KEEP_DAYS=$(ask_value "保留最近几天" "$JOURNAL_KEEP_DAYS" '^[0-9]+$')
        JOURNAL_MAX_SIZE=$(ask_value "总大小上限（如 200M、1G）" "$JOURNAL_MAX_SIZE" '^[0-9]+[KMG]$')
    fi
    if is_on tmp; then
        section "临时文件"
        TMP_MAX_AGE_DAYS=$(ask_value "删除多少天没用过的文件" "$TMP_MAX_AGE_DAYS" '^[0-9]+$')
    fi
    if is_on docker; then
        section "Docker 清理程度"
        printf '   %s1%s  停止的容器、悬空镜像、构建缓存 %s（最安全）%s\n' "$CYAN" "$NC" "$DIM" "$NC"
        printf '   %s2%s  再加上所有没被容器使用的镜像 %s（之后需要重新拉取）%s\n' "$CYAN" "$NC" "$DIM" "$NC"
        printf '   %s3%s  再加上没被容器使用的数据卷 %s（数据会永久丢失）%s\n' "$CYAN" "$NC" "$RED" "$NC"
        DOCKER_LEVEL=$(ask_value "请选择" "$DOCKER_LEVEL" '^[123]$')
        if [[ $DOCKER_LEVEL == 3 ]] && ! ask_yn "已停止容器的数据卷也会被删除且无法恢复，确定吗？" n; then
            DOCKER_LEVEL=2
            info "   已改为程度 2，保留数据卷。"
        fi
    fi
    return 0
}

show_plan() {
    local i id extra
    section "即将执行"
    for i in "${!ITEM_ID[@]}"; do
        (( ITEM_ON[i] )) || continue
        id=${ITEM_ID[i]}; extra=''
        case "$id" in
            journal) extra="保留 ${JOURNAL_KEEP_DAYS} 天，上限 ${JOURNAL_MAX_SIZE}" ;;
            tmp)     extra="超过 ${TMP_MAX_AGE_DAYS} 天未用" ;;
            docker)  extra="程度 ${DOCKER_LEVEL}" ;;
        esac
        printf ' %s%s%s %s%s\n' "$CYAN" "$G_SEL" "$NC" "${ITEM_TITLE[i]}" "${extra:+  $DIM$extra$NC}"
    done
}

# -----------------------------------------------------------------------------
# 执行
# -----------------------------------------------------------------------------
run_step() {
    local title=$1 fn=$2 before after delta
    before=$(disk_avail_kb)
    printf '\n %s%s%s %s%s%s\n' "$CYAN" "$G_SEL" "$NC" "$BOLD" "$title" "$NC"
    "$fn" || warn "「$title」执行时出现问题，已继续后续项目"
    (( DRY_RUN )) && return 0
    after=$(disk_avail_kb)
    delta=$((after - before))
    if (( delta > 0 )); then
        printf '   %s%s%s 根分区可用空间增加 %s\n' "$GREEN" "$G_OK" "$NC" "$(human_kb "$delta")"
    else
        printf '   %s根分区可用空间没有变化（内存盘或本来就很小）%s\n' "$DIM" "$NC"
    fi
}

main() {
    parse_args "$@"
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
    (( ASSUME_YES || HAVE_TTY )) || die "没有可交互的终端。非交互运行请加 --yes（按默认勾选清理）。"

    detect_system
    (( ASSUME_YES )) || clear_screen
    print_banner
    step "正在扫描系统，请稍候 ..."
    scan_all

    choose_items
    count_on
    if (( COUNT == 0 )); then
        info " 没有选中任何项目，已退出。"
        exit 0
    fi

    (( ASSUME_YES )) || page "系统清理 $G_ARROW 确认"
    configure_selected
    show_plan
    if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
        printf '\n'
        ask_yn "确认开始清理？" n || { info " 已取消，没有做任何修改。"; exit 0; }
    fi

    local i start_avail end_avail freed
    start_avail=$(disk_avail_kb)
    for i in "${!ITEM_ID[@]}"; do
        (( ITEM_ON[i] )) || continue
        run_step "${ITEM_TITLE[i]}" "step_${ITEM_ID[i]}"
    done

    term_size; hr "$UI_W"
    printf '\n%s\n' "$HR"
    if (( DRY_RUN )); then
        ok "DRY-RUN 结束，没有做任何修改。去掉 --dry-run 即可真正执行。"
        return 0
    fi
    end_avail=$(disk_avail_kb)
    freed=$((end_avail - start_avail))
    (( freed < 0 )) && freed=0
    ok "清理完成，根分区共释放 $BOLD$(human_kb "$freed")$NC。"
    info "   ${DIM}当前根分区：$(root_usage)$NC"
    is_on kernels && warn "删除过旧内核，建议找时间重启一次，确认系统能正常启动。"
    return 0
}

main "$@"
