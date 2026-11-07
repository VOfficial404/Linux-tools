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

  （不带参数）   打开交互式菜单
  --install      只安装 / 升级 sing-box 程序（官方 apt 源）
  --link         显示节点链接
  -h, --help     显示本帮助
EOF
}

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
        step "安装依赖：${missing[*]} ..."
        { apt_get update -qq && apt_get install -y -qq "${missing[@]}"; } || { warn "依赖安装失败"; return 1; }
    fi

    step "配置 sing-box 官方软件源..."
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

    step "安装 sing-box..."
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
        p=$(ask_value "$label 端口" "$def" '^[0-9]{1,5}$')
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
    pw=$(ask_value "$1 密码（回车随机生成）" "" '^[^[:space:]]{0,128}$')
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
        for p in "$@"; do ufw allow "$p/tcp" >/dev/null && info "   已放行 $p/tcp"; done
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

    menu_reset
    MENU_HEADER=(" 选择要配置的协议。重新配置会覆盖现有节点（原配置会先备份）。")
    menu_item 1 "仅 AnyReality" "on|借用目标网站的证书，不需要域名，推荐"
    menu_item 2 "仅 AnyTLS"     "info|自签证书，客户端需跳过证书验证"
    menu_item 3 "双协议"        "info|AnyReality + AnyTLS 各一个端口"
    menu_blank
    menu_item 0 "返回"
    menu_run "sing-box $G_ARROW 配置节点" 0 1
    mode=$MENU_CHOICE
    [[ $mode == 0 ]] && return 2
    page "sing-box $G_ARROW 配置节点"

    if [[ $mode == 1 || $mode == 3 ]]; then
        section AnyReality
        rp=$(ask_port AnyReality 1443)
        rpw=$(ask_password AnyReality)
        rsni=$(ask_value "Reality 目标网站（需支持 TLS 1.3）" "$DEFAULT_SNI" '^[A-Za-z0-9.-]+$')
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
        section AnyTLS
        ap=$(ask_port AnyTLS 2026 "$rp")
        apw=$(ask_password AnyTLS)
        asni=$(ask_value "证书域名（自签证书，随便填）" "$DEFAULT_SNI" '^[A-Za-z0-9.-]+$')
        step "生成自签 TLS 证书（CN=$asni）..."
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
    printf '\n'
    step "写入配置并检查..."
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
    [[ -n $bak ]] && info " 上一次的配置备份在 $bak"

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

    # 链接单独占一行、不加缩进和颜色，方便整行复制
    if jq -e .reality "$INFO_FILE" >/dev/null 2>&1; then
        read -r p w s k d < <(jq -r '.reality | [.port, (.pwd | @uri), .sni, .pk, .id] | @tsv' "$INFO_FILE")
        section "AnyReality $G_DOT 端口 $p"
        printf 'anytls://%s@%s:%s/?sni=%s&fp=chrome&pbk=%s&sid=%s#AnyReality_%s\n' "$w" "$host" "$p" "$s" "$k" "$d" "$name"
    fi
    if jq -e .anytls "$INFO_FILE" >/dev/null 2>&1; then
        read -r p w s < <(jq -r '.anytls | [.port, (.pwd | @uri), .sni] | @tsv' "$INFO_FILE")
        section "AnyTLS $G_DOT 端口 $p"
        printf 'anytls://%s@%s:%s/?sni=%s&insecure=1#AnyTLS_%s\n' "$w" "$host" "$p" "$s" "$name"
    fi
    printf '\n %s把整行链接导入支持 AnyTLS 的客户端（sing-box 1.12+、mihomo 等）。%s\n' "$DIM" "$NC"
}

# -----------------------------------------------------------------------------
# 服务管理 / 卸载
# -----------------------------------------------------------------------------
# 返回 2 表示选了「返回」，不用停下来
manage_service() {
    local crumb="sing-box $G_ARROW 服务" def=1
    menu_reset
    status_header
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        def=3
        menu_item 1 "启动" "off|已在运行"
        menu_item 2 "停止" "warn|节点会断开"
    else
        menu_item 1 "启动" "info|并设为开机自启"
        menu_item 2 "停止" "off|没有运行"
    fi
    menu_item 3 "重启" "info|重新加载配置"
    menu_blank
    menu_item 0 "返回"
    menu_run "$crumb" 0 "$def"
    case $MENU_CHOICE in
        1) page "$crumb"; systemctl enable --now "$SERVICE" && ok "已启动" ;;
        2) page "$crumb"; systemctl stop "$SERVICE" && ok "已停止" ;;
        3) page "$crumb"; systemctl restart "$SERVICE" && ok "已重启" ;;
        *) return 2 ;;
    esac
}

show_logs() {
    section "服务状态"
    systemctl status "$SERVICE" --no-pager 2>&1 | head -n 12
    section "最近 50 行日志"
    journalctl -u "$SERVICE" -n 50 --no-pager
}

uninstall() {
    local pkg
    ask_yn "卸载 sing-box 吗？" n || return 0
    printf '\n'
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
# 已配置的节点，如「AnyReality 端口 1443，AnyTLS 端口 2026」，没有时为空
node_summary() {
    [[ -f $INFO_FILE ]] && command -v jq >/dev/null 2>&1 || return 0
    jq -r '[(if .reality then "AnyReality 端口 \(.reality.port)" else empty end),
            (if .anytls then "AnyTLS 端口 \(.anytls.port)" else empty end)] | join("，")' "$INFO_FILE" 2>/dev/null
}

# status_header：程序和节点状态放进 MENU_HEADER
status_header() {
    local v nodes
    if sb_installed; then
        v=$(sb_version)
        if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then badge "on|$v 运行中"; else badge "warn|$v 未运行"; fi
    else
        badge "off|未安装"
    fi
    kv sing-box "$BADGE"; MENU_HEADER+=("$KV")
    nodes=$(node_summary)
    if [[ -n $nodes ]]; then badge "on|$nodes"; else badge "off|未配置"; fi
    kv 节点 "$BADGE"; MENU_HEADER+=("$KV")
}

menu() {
    local last=1 installed=0 nodes
    while true; do
        menu_reset
        status_header
        sb_installed && installed=1 || installed=0
        nodes=$(node_summary)
        menu_group "节点"
        if [[ -n $nodes ]]; then
            menu_item 1 "重新配置节点" "info|AnyReality / AnyTLS，会覆盖现有节点"
            menu_item 2 "显示节点链接" "info|复制到客户端导入"
        else
            menu_item 1 "安装并配置节点" "info|AnyReality / AnyTLS，没装时先装 sing-box"
            menu_item 2 "显示节点链接" "off|还没有配置"
        fi
        menu_group "服务"
        if (( installed )); then
            menu_item 3 "启动 / 停止 / 重启" ""
            menu_item 4 "状态和日志"         "info|最近 50 行"
            menu_item 5 "升级 sing-box"      "info|官方 apt 源，当前 $(sb_version)"
            menu_item 6 "卸载"               "warn|可选是否保留配置"
        else
            menu_item 3 "启动 / 停止 / 重启" "off|未安装"
            menu_item 4 "状态和日志"         "off|未安装"
            menu_item 5 "只安装 sing-box"    "info|官方 apt 源，不配置节点"
            menu_item 6 "卸载"               "off|未安装"
        fi
        menu_blank
        menu_item 0 "$BACK_LABEL"
        menu_run "sing-box 节点" 0 "$last"
        last=$MENU_CHOICE
        case $MENU_CHOICE in
            1) page "sing-box $G_ARROW 配置节点"; configure; [[ $? == 2 ]] && continue ;;
            2) page "sing-box $G_ARROW 节点链接"; show_links ;;
            3) manage_service; [[ $? == 2 ]] && continue ;;
            4) page "sing-box $G_ARROW 状态和日志"; show_logs ;;
            5) page "sing-box $G_ARROW 安装 / 升级"; install_singbox ;;
            6) page "sing-box $G_ARROW 卸载"; uninstall ;;
            *) clear_screen; return 0 ;;
        esac
        pause
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
