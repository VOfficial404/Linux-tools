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
