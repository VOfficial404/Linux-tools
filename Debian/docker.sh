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
  --install      按默认选项直接安装 / 升级 Docker 和 Docker Compose
  --uninstall    卸载
  -h, --help     显示本帮助

环境变量 DOCKER_MIRROR：official（默认）、aliyun、tuna
EOF
}

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
        info " /var/lib/docker 里的镜像、容器和数据卷会保留，但用旧版跑着的容器会停止。"
        ask_yn "卸载这些软件包并继续吗？" n || { info " 已取消，没有做任何修改。"; return 1; }
        apt_get remove -y "${conflicts[@]}" || { warn "卸载冲突的软件包失败"; return 1; }
    fi

    # ---- 依赖 ---------------------------------------------------------------
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v gpg  >/dev/null 2>&1 || missing+=(gpg)
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
    if (( ${#missing[@]} )); then
        step "安装依赖：${missing[*]} ..."
        { apt_get update -qq && apt_get install -y -qq "${missing[@]}"; } || { warn "依赖安装失败"; return 1; }
    fi

    # ---- 软件源 -------------------------------------------------------------
    base="$(mirror_base "$MIRROR")/$OS_ID"
    codename=$OS_CODENAME
    step "使用 $(mirror_name "$MIRROR")：$base"
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
            info " 已停用以前的 Docker 软件源：$f（改名为 $f.linux-tools.bak）"
        done
    fi

    printf 'deb [arch=%s signed-by=%s] %s %s stable\n' "$arch" "$KEYRING" "$base" "$codename" > "$SOURCE_LIST"
    chmod 644 "$SOURCE_LIST"

    # ---- 安装 ---------------------------------------------------------------
    step "安装 Docker 和 Docker Compose（已安装时会升级到最新版）..."
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
        info " 已存在 $DAEMON_JSON，没有修改。"
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
    info " 注意：docker run -p 发布的端口会绕过 ufw 直接对外开放。只想本机访问时写成 -p 127.0.0.1:8080:80。"
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
        info " 数据保留在 /var/lib/docker，重新安装后还能用。"
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
docker_installed() { command -v docker >/dev/null 2>&1; }

# status_header：Docker 当前状态放进 MENU_HEADER
status_header() {
    local v src='未配置' n
    if docker_installed; then
        v=$(docker_version)
        if systemctl is-active --quiet docker 2>/dev/null; then
            n=$(docker ps -q 2>/dev/null | wc -l)
            badge "on|$v 运行中 $G_DOT $n 个容器"
        else
            badge "warn|$v 未运行"
        fi
        kv Docker "$BADGE"; MENU_HEADER+=("$KV")
        v=$(compose_version)
        if [[ -n $v ]]; then badge "on|$v"; else badge "off|未安装"; fi
        kv Compose "$BADGE"; MENU_HEADER+=("$KV")
    else
        badge "off|未安装"
        kv Docker "$BADGE"; MENU_HEADER+=("$KV")
    fi
    [[ -f $SOURCE_LIST ]] && src=$(awk '{ print $(NF - 2) }' "$SOURCE_LIST" | head -n 1)
    kv 软件源 "$src"; MENU_HEADER+=("$KV")
}

# 返回 2 表示选了「返回」，不用停下来
interactive_install() {
    local crumb="Docker $G_ARROW 安装 / 升级"
    menu_reset
    MENU_HEADER=(" 从哪个软件源安装？已安装时会升级到最新版。")
    menu_item 1 "Docker 官方源" "info|download.docker.com"
    menu_item 2 "阿里云镜像"    "info|国内服务器推荐"
    menu_item 3 "清华大学镜像"  "info|mirrors.tuna.tsinghua.edu.cn"
    menu_blank
    menu_item 0 "返回"
    menu_run "$crumb" 0 1
    case $MENU_CHOICE in
        1) MIRROR=official ;;
        2) MIRROR=aliyun ;;
        3) MIRROR=tuna ;;
        *) return 2 ;;
    esac
    page "$crumb"
    install_docker
}

menu() {
    local last=1
    while true; do
        menu_reset
        status_header
        if docker_installed; then
            menu_item 1 "升级 Docker" "info|安装最新版 Docker + Compose"
            menu_item 2 "卸载"        "warn|可选是否删除镜像和数据"
        else
            menu_item 1 "安装 Docker" "info|Docker + Compose 插件，可选国内镜像"
            menu_item 2 "卸载"        "off|未安装"
        fi
        menu_blank
        menu_item 0 "$BACK_LABEL"
        menu_run "Docker + Compose" 0 "$last"
        last=$MENU_CHOICE
        case $MENU_CHOICE in
            1) interactive_install; [[ $? == 2 ]] && continue ;;
            2) page "Docker $G_ARROW 卸载"; uninstall_docker ;;
            *) clear_screen; return 0 ;;
        esac
        pause
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
