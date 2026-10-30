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

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'
else
    BOLD=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

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
# 交互：一律从 /dev/tty 读
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

# ask_value <提示> <默认值> <校验正则>；结果输出到 stdout。默认值为空时不显示 []
ask_value() {
    local prompt=$1 def=$2 re=$3 reply='' shown=''
    [[ -n $def ]] && shown=" [$def]"
    while true; do
        read -r -p "$prompt$shown: " reply </dev/tty || reply=''
        reply=${reply:-$def}
        if [[ $reply =~ $re ]]; then
            printf '%s' "$reply"
            return
        fi
        printf '  输入无效，请重新输入。\n' >&2
    done
}

pause() { read -r -p "按回车继续..." _ </dev/tty || true; }

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
        info "安装依赖：${missing[*]} ..."
        { apt_get update -qq && apt_get install -y -qq "${missing[@]}"; } || { warn "依赖安装失败"; return 1; }
    fi

    info "配置 sing-box 官方软件源..."
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

    info "安装 sing-box..."
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
        p=$(ask_value "  $label 端口" "$def" '^[0-9]{1,5}$')
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
    pw=$(ask_value "  $1 密码（回车随机生成）" "" '^[^[:space:]]{0,128}$')
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
        for p in "$@"; do ufw allow "$p/tcp" >/dev/null && info "  已放行 $p/tcp"; done
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

    printf '\n%s配置模式%s\n' "$BOLD" "$NC"
    printf '  1) 仅 AnyReality（借用目标网站的证书，不需要域名）\n'
    printf '  2) 仅 AnyTLS（自签证书，客户端需跳过证书验证）\n'
    printf '  3) 双协议（AnyReality + AnyTLS）\n'
    printf '  0) 返回\n'
    mode=$(ask_value "请选择" 1 '^[0-3]$')
    [[ $mode == 0 ]] && return 0

    if [[ $mode == 1 || $mode == 3 ]]; then
        printf '\n%sAnyReality%s\n' "$BOLD" "$NC"
        rp=$(ask_port AnyReality 1443)
        rpw=$(ask_password AnyReality)
        rsni=$(ask_value "  Reality 目标网站（需支持 TLS 1.3）" "$DEFAULT_SNI" '^[A-Za-z0-9.-]+$')
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
        printf '\n%sAnyTLS%s\n' "$BOLD" "$NC"
        ap=$(ask_port AnyTLS 2026 "$rp")
        apw=$(ask_password AnyTLS)
        asni=$(ask_value "  证书域名（自签证书，随便填）" "$DEFAULT_SNI" '^[A-Za-z0-9.-]+$')
        info "  生成自签 TLS 证书（CN=$asni）..."
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
    [[ -n $bak ]] && info "上一次的配置备份在 $bak"

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

    if jq -e .reality "$INFO_FILE" >/dev/null 2>&1; then
        read -r p w s k d < <(jq -r '.reality | [.port, (.pwd | @uri), .sni, .pk, .id] | @tsv' "$INFO_FILE")
        printf '\n%s[AnyReality]%s\n' "$GREEN" "$NC"
        printf 'anytls://%s@%s:%s/?sni=%s&fp=chrome&pbk=%s&sid=%s#AnyReality_%s\n' "$w" "$host" "$p" "$s" "$k" "$d" "$name"
    fi
    if jq -e .anytls "$INFO_FILE" >/dev/null 2>&1; then
        read -r p w s < <(jq -r '.anytls | [.port, (.pwd | @uri), .sni] | @tsv' "$INFO_FILE")
        printf '\n%s[AnyTLS]%s\n' "$GREEN" "$NC"
        printf 'anytls://%s@%s:%s/?sni=%s&insecure=1#AnyTLS_%s\n' "$w" "$host" "$p" "$s" "$name"
    fi
    printf '\n'
}

# -----------------------------------------------------------------------------
# 服务管理 / 卸载
# -----------------------------------------------------------------------------
manage_service() {
    printf '  1) 启动  2) 停止  3) 重启  0) 返回\n'
    case $(ask_value "请选择" 0 '^[0-3]$') in
        1) systemctl start "$SERVICE" && ok "已启动" ;;
        2) systemctl stop "$SERVICE" && ok "已停止" ;;
        3) systemctl restart "$SERVICE" && ok "已重启" ;;
    esac
}

show_logs() {
    systemctl status "$SERVICE" --no-pager 2>&1 | head -n 12
    printf '\n%s最近 50 行日志：%s\n' "$BOLD" "$NC"
    journalctl -u "$SERVICE" -n 50 --no-pager
}

uninstall() {
    local pkg
    ask_yn "卸载 sing-box 吗？" n || return 0
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
show_status() {
    local v st nodes=''
    info "=============================================================="
    info " ${BOLD}sing-box 管理（AnyTLS / AnyReality）${NC}"
    info "=============================================================="
    if sb_installed; then
        v=$(sb_version)
        if systemctl is-active --quiet "$SERVICE"; then st="${GREEN}运行中${NC}"; else st="${YELLOW}未运行${NC}"; fi
        info " sing-box : $v · $st"
    else
        info " sing-box : 未安装"
    fi
    if [[ -f $INFO_FILE ]] && command -v jq >/dev/null 2>&1; then
        nodes=$(jq -r '[(if .reality then "AnyReality 端口 \(.reality.port)" else empty end),
                        (if .anytls then "AnyTLS 端口 \(.anytls.port)" else empty end)] | join("，")' "$INFO_FILE" 2>/dev/null)
    fi
    info " 节点     : ${nodes:-未配置}"
    info "=============================================================="
}

menu() {
    while true; do
        printf '\n'
        show_status
        printf '  %s1)%s 安装 / 重新配置节点\n' "$CYAN" "$NC"
        printf '  %s2)%s 显示节点链接\n' "$CYAN" "$NC"
        printf '  %s3)%s 启动 / 停止 / 重启服务\n' "$CYAN" "$NC"
        printf '  %s4)%s 查看状态和日志\n' "$CYAN" "$NC"
        printf '  %s5)%s 只安装 / 升级 sing-box 程序\n' "$CYAN" "$NC"
        printf '  %s6)%s 卸载\n' "$CYAN" "$NC"
        printf '  %s0)%s 退出\n' "$CYAN" "$NC"
        case $(ask_value "请选择" 0 '^[0-6]$') in
            1) configure; pause ;;
            2) show_links; pause ;;
            3) manage_service ;;
            4) show_logs; pause ;;
            5) install_singbox; pause ;;
            6) uninstall; pause ;;
            *) return 0 ;;
        esac
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
