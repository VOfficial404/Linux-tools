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
  --status       查看当前实际生效的 SSH 登录设置
  --restore      删除本脚本的配置，恢复原来的登录方式
  -h, --help     显示本帮助
EOF
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

# yn_badge <yes|no> <yes 时的级别> <no 时的级别>：允许 / 禁止，带颜色，放进 BADGE
yn_badge() {
    case $1 in
        yes) badge "$2|允许" ;;
        no)  badge "$3|禁止" ;;
        *)   badge "info|$(yn_text "$1")" ;;
    esac
}

# status_rows：当前实际生效的登录设置，每行放进 STATUS_ROWS；读不到 sshd 配置时返回 1
status_rows() {
    STATUS_ROWS=()
    load_effective
    if [[ -z $SSHD_T ]]; then
        STATUS_ROWS=(" $RED$G_ERR 无法读取 sshd 配置（sshd -T 失败），配置文件可能有错误$NC")
        return 1
    fi
    KV_W=12
    yn_badge "$(eff passwordauthentication)" warn on;        kv 密码登录 "$BADGE";     STATUS_ROWS+=("$KV")
    yn_badge "$(eff kbdinteractiveauthentication)" warn on;  kv 键盘交互登录 "$BADGE ${DIM}（PAM 通过它询问密码）$NC"; STATUS_ROWS+=("$KV")
    yn_badge "$(eff pubkeyauthentication)" on danger;        kv 密钥登录 "$BADGE";     STATUS_ROWS+=("$KV")
    yn_badge "$(eff permitemptypasswords)" danger on;        kv 空密码登录 "$BADGE";   STATUS_ROWS+=("$KV")
    kv "root 登录" "$(eff permitrootlogin)";                                         STATUS_ROWS+=("$KV")
    if [[ -f $CONF ]]; then
        badge "on|已应用 $G_DOT $CONF"
    else
        badge "off|未应用"
    fi
    kv 本脚本配置 "$BADGE"; STATUS_ROWS+=("$KV")
}

# show_status：直接打印（--status 用）
show_status() {
    local rc=0
    status_rows || rc=1
    title_line "SSH 登录方式"
    term_size; hr "$UI_W"
    printf '%s %s（当前实际生效的设置）%s\n%s\n' "$TITLE" "$DIM" "$NC" "$HR"
    printf '%s\n' "${STATUS_ROWS[@]}"
    printf '%s\n' "$HR"
    return $rc
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
        info " ssh 由 ssh.socket 按需启动，新连接会自动使用新配置。"
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
    section "各用户已配置的公钥"
    while read -r u; do
        n=$(keys_of "$u")
        if [[ $u == root && $root_mode == no ]]; then
            badge "off|$n 把（root 将被完全禁止登录）"
            kv "$u" "$BADGE" 16; info "$KV"
            continue
        fi
        total=$(( total + n ))
        if (( n )); then
            badge "on|$n 把"
        else
            badge "warn|没有公钥，禁止密码后将无法登录"
        fi
        kv "$u" "$BADGE" 16; info "$KV"
    done < <(login_users)
    printf '\n'

    if (( total == 0 )); then
        warn "没有任何可登录的用户配置了公钥，现在禁止密码登录会把所有人锁在外面，已取消。"
        warn "请先用菜单里的「添加公钥」，并确认用密钥能登录。"
        return 1
    fi
    if [[ ! ($me == root && $root_mode == no) ]] && (( $(keys_of "$me") == 0 )); then
        warn "你当前使用的用户 $me 没有公钥，禁止密码登录后 $me 将无法登录。"
        ask_yn "仍要继续吗？" n || { info " 已取消，没有做任何修改。"; return 1; }
    fi
    if grep -qsiE '^[[:space:]]*Match[[:space:]]' "$MAIN_CONF" "$CONF_DIR"/*.conf; then
        warn "sshd 配置里有 Match 段，它可能为部分用户或来源重新打开密码登录，请自行检查。"
    fi

    printf '\n'
    ask_yn "确认禁止 SSH 密码登录吗？" n || { info " 已取消，没有做任何修改。"; return 1; }

    # ---- 确保 sshd_config 会读取 sshd_config.d ------------------------------
    if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN_CONF"; then
        local b
        b="$MAIN_CONF.bak.$(date +%Y%m%d_%H%M%S)"
        cp -a "$MAIN_CONF" "$b"
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN_CONF"
        info " $MAIN_CONF 里没有 Include sshd_config.d，已加在第一行（原文件备份在 $b）"
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
    printf '\n %s%s 不要关闭当前这个 SSH 窗口！%s先另开一个终端测试：\n\n' "$RED$BOLD" "$G_WARN" "$NC"
    info "   1. 用密钥能登录"
    info "      $CYAN ssh $me@<服务器IP>$NC"
    info "   2. 密码会被拒绝，应该提示 Permission denied (publickey)"
    info "      $CYAN ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password $me@<服务器IP>$NC"
    printf '\n'
    info " 如果登不上，在当前窗口（或服务商的 VNC / 控制台）执行下面这行即可恢复："
    info "   $CYAN rm -f $CONF && systemctl reload ssh$NC"
}

restore_login() {
    if [[ ! -f $CONF ]]; then
        info " 没有应用过本脚本的配置，无需恢复。"
        return 0
    fi
    rm -f -- "$CONF"
    prep_sshd
    "$SSHD" -t || warn "sshd 配置检查有问题，请查看上面的输出。"
    reload_ssh
    ok "已删除 $CONF，恢复为系统原来的登录设置。"
    load_effective
    if [[ $(eff passwordauthentication) == no ]]; then
        info " 注意：系统的其他配置本身就禁止了密码登录，所以现在仍然是禁止的。"
    fi
}

# -----------------------------------------------------------------------------
# 添加公钥
# -----------------------------------------------------------------------------
add_key() {
    local user home group key tmp dir file fp
    page "SSH 禁止密码登录 $G_ARROW 添加公钥"
    info " 在你自己的电脑上执行 ${CYAN}ssh-keygen -t ed25519$NC 生成密钥，"
    info " 然后把 .pub 文件里的那一行粘贴到这里。"
    printf '\n'
    user=$(ask_value "给哪个用户添加" "$(current_user)" '^[a-z_][a-z0-9_.-]*$')
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -n $home && -d $home ]] || { warn "用户 $user 不存在或没有家目录。"; return 1; }
    group=$(id -gn "$user")

    read -r -p " $YELLOW?$NC 公钥（以 ssh-ed25519、ssh-rsa 等开头）: " key </dev/tty || return 1
    printf '\n'
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
        info " 这把公钥已经在 $file 里了。"
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
    local mode crumb="SSH 禁止密码登录 $G_ARROW 禁止密码"
    menu_reset
    MENU_HEADER=(" 禁止密码登录后，root 用什么方式登录？")
    menu_item 1 "只允许密钥"   "on|prohibit-password，推荐"
    menu_item 2 "完全禁止 root" "warn|no，需要另有一个能 sudo 的普通用户"
    menu_item 3 "不修改"       "info|保持 root 现在的设置"
    menu_blank
    menu_item 0 "返回"
    menu_run "$crumb" 0 1
    case $MENU_CHOICE in
        1) mode=prohibit-password ;;
        2) mode=no ;;
        3) mode=keep ;;
        *) return 2 ;;   # 返回上一层，不用停下来
    esac
    page "$crumb"
    if [[ $mode == no && $(current_user) == root ]]; then
        warn "你现在是用 root 登录的，完全禁止 root 后将不能再用 root 登录。"
        ask_yn "仍要继续吗？" n || return 0
    fi
    apply_keyonly "$mode"
}

menu() {
    local last=1
    while true; do
        menu_reset
        status_rows
        MENU_HEADER=("${STATUS_ROWS[@]}")
        if [[ -f $CONF ]]; then
            menu_item 1 "重新应用"   "info|再检查一遍公钥并写入配置"
        else
            menu_item 1 "禁止密码登录" "info|只允许密钥，应用前检查公钥"
        fi
        menu_item 2 "添加公钥"     "info|写入 ~/.ssh/authorized_keys"
        if [[ -f $CONF ]]; then
            menu_item 3 "恢复原来的登录方式" "info|删除本脚本的配置"
        else
            menu_item 3 "恢复原来的登录方式" "off|没有应用过"
        fi
        menu_blank
        menu_item 0 "$BACK_LABEL"
        menu_run "SSH 禁止密码登录" 0 "$last"
        last=$MENU_CHOICE
        case $MENU_CHOICE in
            1) interactive_apply; [[ $? == 2 ]] && continue ;;
            2) add_key ;;
            3)
                page "SSH 禁止密码登录 $G_ARROW 恢复"
                ask_yn "删除本脚本的配置，恢复原来的登录方式吗？" n && { printf '\n'; restore_login; } ;;
            *) clear_screen; return 0 ;;
        esac
        pause
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
