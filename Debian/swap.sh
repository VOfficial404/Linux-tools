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

  （不带参数）          打开交互式菜单
  -a, --add <大小>      添加 /swapfile，已有时调整为该大小。例：2G、512M、1024（MB）
  -r, --remove          删除 /swapfile（不影响 swap 分区和 zram）
  -s, --swappiness <N>  设置 swappiness（0-100）并永久保存
  -h, --help            显示本帮助
EOF
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
    cp -a /etc/fstab "$b" && info " 已备份 /etc/fstab -> $b"
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
# status_header：当前内存和 swap 情况放进 MENU_HEADER（菜单标题下方）
status_header() {
    local total avail st sf name type size used
    total=$(mem_mb MemTotal); avail=$(mem_mb MemAvailable)
    st=$(mem_mb SwapTotal);   sf=$(mem_mb SwapFree)
    KV_W=10
    kv 内存 "共 $(human_mb "$total") $DIM$G_DOT$NC 可用 $(human_mb "$avail")"; MENU_HEADER+=("$KV")
    if (( st > 0 )); then
        badge "on|共 $(human_mb "$st") $G_DOT 已用 $(human_mb $(( st - sf )))"
    else
        badge "warn|未启用"
    fi
    kv Swap "$BADGE"; MENU_HEADER+=("$KV")
    kv swappiness "$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 未知) ${DIM}（越小越晚用 swap）$NC"; MENU_HEADER+=("$KV")
    # 每个 swap 设备一行：文件、分区、zram
    while read -r name type size used; do
        [[ -n $name ]] || continue
        kv "" "$name $DIM$G_DOT $type $G_DOT $size，已用 $used$NC"; MENU_HEADER+=("$KV")
    done < <(swapon --noheadings --show=NAME,TYPE,SIZE,USED 2>/dev/null)
    [[ -n $CONTAINER ]] && MENU_HEADER+=(" $YELLOW$G_WARN 当前在容器（$CONTAINER）里，无法添加 swap$NC")
    return 0
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
    step "fallocate 不可用，改用 dd 写入（较慢，请稍候）..."
    dd_file "$mb"
}

# remove_swapfile：关闭并删除 /swapfile，同时去掉 fstab 里的那一行
remove_swapfile() {
    if [[ ! -e $SWAPFILE ]] && ! fstab_has_swapfile; then
        info " 没有 $SWAPFILE，无需删除。"
        if [[ -n $(swapon --noheadings --show 2>/dev/null) ]]; then
            info " 系统里的其他 swap（分区、zram 等）不是本脚本创建的，没有改动。"
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
            ask_yn "仍要关闭吗？" n || { info " 已取消，没有做任何修改。"; return 1; }
        fi
        step "正在关闭 $SWAPFILE（里面的数据会移回内存，可能需要一点时间）..."
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
        step "先删除现有的 $SWAPFILE ..."
        remove_swapfile || return 1
    fi

    step "正在创建 $(human_mb "$mb") 的 $SWAPFILE ..."
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
    swapon --show | sed "s/^/   /"
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
    page "Swap 管理 $G_ARROW 添加 / 调整"
    kv 建议大小 "$BOLD$(human_mb "$rec")$NC ${DIM}（内存 ≤2G 取 2 倍，≤8G 取 1 倍，更大取 4G）$NC"; info "$KV"
    printf '\n'
    input=$(ask_value "swap 大小（如 1G、512M，纯数字按 MB）" "${rec}M" '^[0-9]+[MmGg]?[Bb]?$')
    mb=$(parse_size "$input") || { warn "大小格式不对：$input"; return 1; }
    if [[ -e $SWAPFILE ]]; then
        ask_yn "已有 $SWAPFILE，将改为 $(human_mb "$mb")（先关闭旧的再重新创建），继续吗？" y || return 0
    else
        ask_yn "创建 $(human_mb "$mb") 的 $SWAPFILE 吗？" y || return 0
    fi
    printf '\n'
    add_swap "$mb"
}

interactive_remove() {
    page "Swap 管理 $G_ARROW 删除"
    if [[ -e $SWAPFILE ]] || fstab_has_swapfile; then
        ask_yn "删除 $SWAPFILE 吗？（swap 分区和 zram 不受影响）" n || return 0
        printf '\n'
    fi
    remove_swapfile
}

interactive_swappiness() {
    local v
    page "Swap 管理 $G_ARROW swappiness"
    info " 范围 0-100，数值越小，系统越晚开始使用 swap。"
    info " ${DIM}Debian 默认 60，小内存 VPS 常用 10。$NC"
    printf '\n'
    v=$(ask_value "swappiness" "$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)" '^[0-9]+$')
    printf '\n'
    set_swappiness "$v"
}

menu() {
    local last=1
    while true; do
        menu_reset
        status_header
        if [[ -e $SWAPFILE ]]; then
            menu_item 1 "调整 swap 大小" "info|重新创建 $SWAPFILE"
            menu_item 2 "删除 swap"      "info|只删 $SWAPFILE，分区和 zram 不动"
        else
            menu_item 1 "添加 swap"      "info|建议 $(human_mb "$(recommend_mb)")"
            menu_item 2 "删除 swap"      "off|没有 $SWAPFILE"
        fi
        menu_item 3 "设置 swappiness" "info|当前 $(cat /proc/sys/vm/swappiness 2>/dev/null || echo 未知)"
        menu_blank
        menu_item 0 "$BACK_LABEL"
        menu_run "Swap 管理" 0 "$last"
        last=$MENU_CHOICE
        case $MENU_CHOICE in
            1) interactive_add ;;
            2) interactive_remove ;;
            3) interactive_swappiness ;;
            *) clear_screen; return 0 ;;
        esac
        pause
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
