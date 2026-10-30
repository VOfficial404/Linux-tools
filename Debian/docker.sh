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
  --install      按默认选项直接安装 / 升级 Docker 和 Docker Compose
  --uninstall    卸载
  -h, --help     显示本帮助

环境变量 DOCKER_MIRROR：official（默认）、aliyun、tuna
EOF
}

# -----------------------------------------------------------------------------
# 交互：一律从 /dev/tty 读；--install 模式不提问，直接取默认值
# -----------------------------------------------------------------------------
HAVE_TTY=0
{ : </dev/tty; } 2>/dev/null && HAVE_TTY=1

# ask_yn <提示> <默认 y|n>
ask_yn() {
    local prompt=$1 def=$2 hint='[y/N]' reply=''
    [[ $def == y ]] && hint='[Y/n]'
    if (( ASSUME_YES )); then
        [[ $def == y ]]
        return
    fi
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

pause() { read -r -p "按回车继续..." _ </dev/tty || true; }

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
        info "  /var/lib/docker 里的镜像、容器和数据卷会保留，但用旧版跑着的容器会停止。"
        ask_yn "卸载这些软件包并继续吗？" n || { info "已取消，没有做任何修改。"; return 1; }
        apt_get remove -y "${conflicts[@]}" || { warn "卸载冲突的软件包失败"; return 1; }
    fi

    # ---- 依赖 ---------------------------------------------------------------
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v gpg  >/dev/null 2>&1 || missing+=(gpg)
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
    if (( ${#missing[@]} )); then
        info "安装依赖：${missing[*]} ..."
        { apt_get update -qq && apt_get install -y -qq "${missing[@]}"; } || { warn "依赖安装失败"; return 1; }
    fi

    # ---- 软件源 -------------------------------------------------------------
    base="$(mirror_base "$MIRROR")/$OS_ID"
    codename=$OS_CODENAME
    info "使用 $(mirror_name "$MIRROR")：$base"
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
            info "已停用以前的 Docker 软件源：$f（改名为 $f.linux-tools.bak）"
        done
    fi

    printf 'deb [arch=%s signed-by=%s] %s %s stable\n' "$arch" "$KEYRING" "$base" "$codename" > "$SOURCE_LIST"
    chmod 644 "$SOURCE_LIST"

    # ---- 安装 ---------------------------------------------------------------
    info "安装 Docker 和 Docker Compose（已安装时会升级到最新版）..."
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
        info "已存在 $DAEMON_JSON，没有修改。"
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
    info "注意：docker run -p 发布的端口会绕过 ufw 直接对外开放。只想本机访问时写成 -p 127.0.0.1:8080:80。"
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
        info "数据保留在 /var/lib/docker，重新安装后还能用。"
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
show_status() {
    local st src='未配置'
    info "=============================================================="
    info " ${BOLD}Docker + Docker Compose${NC}"
    info "=============================================================="
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker 2>/dev/null; then st="${GREEN}运行中${NC}"; else st="${YELLOW}未运行${NC}"; fi
        info " Docker   : $(docker_version) · $st"
        st=$(compose_version)
        info " Compose  : ${st:-未安装}"
    else
        info " Docker   : 未安装"
    fi
    [[ -f $SOURCE_LIST ]] && src=$(awk '{ print $(NF - 2) }' "$SOURCE_LIST" | head -n 1)
    info " 软件源   : $src"
    info "=============================================================="
}

interactive_install() {
    local c
    printf '\n%s选择软件源%s\n' "$BOLD" "$NC"
    printf '  1) Docker 官方源（download.docker.com）\n'
    printf '  2) 阿里云镜像（国内服务器推荐）\n'
    printf '  3) 清华大学镜像\n'
    printf '  0) 返回\n'
    c=$(ask_value "请选择" 1 '^[0-3]$')
    case $c in
        1) MIRROR=official ;;
        2) MIRROR=aliyun ;;
        3) MIRROR=tuna ;;
        *) return 0 ;;
    esac
    install_docker
}

menu() {
    while true; do
        printf '\n'
        show_status
        printf '  %s1)%s 安装 / 升级 Docker 和 Docker Compose\n' "$CYAN" "$NC"
        printf '  %s2)%s 卸载\n' "$CYAN" "$NC"
        printf '  %s0)%s 退出\n' "$CYAN" "$NC"
        case $(ask_value "请选择" 0 '^[0-2]$') in
            1) interactive_install; pause ;;
            2) uninstall_docker; pause ;;
            *) return 0 ;;
        esac
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
