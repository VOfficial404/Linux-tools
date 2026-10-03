#!/usr/bin/env bash
# =============================================================================
#  debian-cleanup.sh —— Debian 12 (bookworm) / Debian 13 (trixie) 通用系统清理脚本
#
#  在完整保留原脚本功能的前提下重写，主要改动：
#    * 修复原脚本中被复制粘贴破坏的语法（注释缺 "#"、通配符丢失、for user in /home/ 等）
#    * 修复会误删“正在运行的内核”的隐患：内核版本号里的 "+" 在正则中是量词，
#      Debian 13 的 6.12.x+deb13-amd64 会导致排除失效 —— 现改为纯字面量匹配
#    * 适配 Debian 13：deborphan 已从 trixie 仓库移除（自动探测并回退到 apt autoremove）、
#      /tmp 默认为 tmpfs（清理只释放内存）、内核与固件包体积变大（内核清理更彻底）
#    * 保留 Debian 12 及 Ubuntu/Mint 等 apt 系发行版的可用性，非 Debian 走兼容模式
#    * 新增：dry-run、verbose、分步骤磁盘占用统计、失败不中断、可逐项开关
#
#  用法：
#     sudo ./debian-cleanup.sh                # 正常清理
#     sudo ./debian-cleanup.sh --dry-run      # 只显示将要做什么，不做任何修改
#     sudo ./debian-cleanup.sh --verbose      # 显示被清理命令的原始输出
#     sudo ./debian-cleanup.sh --help
#
#  常用环境变量（可与 sudo 一起写成： sudo KEEP_NEWEST_KERNEL=0 ./debian-cleanup.sh）：
#     KEEP_NEWEST_KERNEL=0     仅保留"正在运行"的内核（= 原脚本行为）
#     DOCKER_PRUNE_VOLUMES=0   保留 Docker 数据卷（避免误删容器数据）
#     USE_DEBORPHAN=0          不安装也不调用 deborphan
#     DEBORPHAN_PURGE=1        允许真正删除 deborphan 报出的孤立库（默认只报告）
#     LOG_REMOVE_COMPRESSED=1  一并删除 /var/log 下已压缩的历史日志归档
#     CLEAN_KERNELS=0 / CLEAN_LOGS=0 / CLEAN_TMP=0 / CLEAN_USER_CACHES=0 /
#     CLEAN_APT_CACHE=0 / CLEAN_DOCKER=0 / CLEAN_JOURNAL=0  关闭对应步骤
# =============================================================================

set -u
set -o pipefail

# -----------------------------------------------------------------------------
# CONFIG —— 全部可用环境变量覆盖
# -----------------------------------------------------------------------------
DRY_RUN=${DRY_RUN:-0}
VERBOSE=${VERBOSE:-0}

CLEAN_APT_UPDATE=${CLEAN_APT_UPDATE:-1}          # apt-get update

CLEAN_KERNELS=${CLEAN_KERNELS:-1}                # 删除旧内核
KEEP_NEWEST_KERNEL=${KEEP_NEWEST_KERNEL:-1}      # 1=同时保留已安装的最新内核（更安全），0=只保留运行中的内核

CLEAN_ORPHANS=${CLEAN_ORPHANS:-1}                # 清理孤立/不再需要的包
USE_DEBORPHAN=${USE_DEBORPHAN:-1}                # 1=仓库里有时安装并调用 deborphan（Debian 12 有，Debian 13 已移除）
DEBORPHAN_PURGE=${DEBORPHAN_PURGE:-0}            # 1=实际删除 deborphan 报出的孤立库（默认仅报告，更安全）

CLEAN_LOGS=${CLEAN_LOGS:-1}                      # 截断日志
LOG_EXTRA_FILES=${LOG_EXTRA_FILES:-"syslog messages debug kern.log daemon.log user.log"}  # 无 .log 后缀的常见日志
LOG_REMOVE_COMPRESSED=${LOG_REMOVE_COMPRESSED:-0} # 1=删除 *.gz/*.old 历史归档（默认只截断不删除）

CLEAN_TMP=${CLEAN_TMP:-1}                        # /tmp、/var/tmp
CLEAN_USER_CACHES=${CLEAN_USER_CACHES:-1}        # /root/.cache/pip 与 /home/*/.cache
CLEAN_APT_CACHE=${CLEAN_APT_CACHE:-1}            # apt 本地存档与缓存

CLEAN_DOCKER=${CLEAN_DOCKER:-1}                  # Docker 清理
DOCKER_PRUNE_VOLUMES=${DOCKER_PRUNE_VOLUMES:-1}  # 1=连同数据卷一起删（原脚本行为）

CLEAN_JOURNAL=${CLEAN_JOURNAL:-1}                # systemd journal 收缩
JOURNAL_KEEP_TIME=${JOURNAL_KEEP_TIME:-7d}
JOURNAL_MAX_SIZE=${JOURNAL_MAX_SIZE:-1G}

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# 运行时探测到的信息（由 detect_environment 填充，这里先给默认值，
# 避免脚本被 source 后被 set -u 判为未绑定变量）
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
DISTRO_LIKE=""
DISTRO_TAG="未知发行版"
RUNNING_KERNEL=""
IS_CONTAINER=0

# -----------------------------------------------------------------------------
# 基础输出工具
# -----------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
info() { printf '[信息] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

# run —— 统一执行被清理命令：dry-run 只打印；默认静默；失败只警告不中断
run() {
    if (( DRY_RUN )); then
        printf '    [dry-run] %s\n' "$*"
        return 0
    fi
    if (( VERBOSE )); then
        "$@" || warn "命令返回非零（已忽略）：$*"
    else
        "$@" >/dev/null 2>&1 || warn "命令返回非零（已忽略）：$*"
    fi
    return 0
}

usage() {
    cat <<'EOF'
用法: sudo ./debian-cleanup.sh [选项]

选项:
  -n, --dry-run       只显示将要执行的操作，不做任何修改
  -v, --verbose       显示被清理命令的原始输出
      --no-docker     跳过 Docker 清理
      --no-journal    跳过 systemd journal 清理
  -h, --help          显示本帮助

可用环境变量（示例: sudo KEEP_NEWEST_KERNEL=0 ./debian-cleanup.sh）:
  KEEP_NEWEST_KERNEL=0      只保留正在运行的内核（与原脚本行为完全一致）
  DOCKER_PRUNE_VOLUMES=0    保留 Docker 数据卷
  USE_DEBORPHAN=0           不使用 deborphan（Debian 13 会自动跳过）
  DEBORPHAN_PURGE=1         允许删除 deborphan 报出的孤立库（默认仅报告）
  LOG_REMOVE_COMPRESSED=1   一并删除 /var/log 下已压缩的历史日志
  CLEAN_*=0                 关闭对应步骤，详见脚本头部 CONFIG 区
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -n|--dry-run) DRY_RUN=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            --no-docker)  CLEAN_DOCKER=0 ;;
            --no-journal) CLEAN_JOURNAL=0 ;;
            -h|--help)    usage; exit 0 ;;
            *) warn "未知参数：$1"; usage; exit 2 ;;
        esac
        shift
    done
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log "此脚本必须以root权限运行"
        die "请使用：sudo $0"
    fi
}

# -----------------------------------------------------------------------------
# 磁盘空间统计
# -----------------------------------------------------------------------------
disk_used()  { df -Pk / 2>/dev/null | awk 'NR==2 {print $3+0}'; }   # 根分区已用（KB）
disk_avail() { df -Pk / 2>/dev/null | awk 'NR==2 {print $4+0}'; }   # 根分区可用（KB）

human_kb() {
    awk -v k="${1:-0}" 'BEGIN{
        split("KB MB GB TB PB", u, " "); i = 1;
        while (k >= 1024 && i < 5) { k /= 1024; i++ }
        if (i == 1) printf "%d %s", k, u[i]; else printf "%.2f %s", k, u[i];
    }'
}

# -----------------------------------------------------------------------------
# 环境识别
# -----------------------------------------------------------------------------
detect_environment() {
    DISTRO_ID=""; DISTRO_VERSION=""; DISTRO_CODENAME=""; DISTRO_LIKE=""
    if [[ -r /etc/os-release ]]; then
        read -r DISTRO_ID DISTRO_VERSION DISTRO_CODENAME DISTRO_LIKE < <(
            # shellcheck disable=SC1091
            . /etc/os-release 2>/dev/null
            printf '%s %s %s %s\n' "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}" "${ID_LIKE:-}"
        )
    fi

    case "${DISTRO_ID}:${DISTRO_VERSION}" in
        debian:12) DISTRO_TAG="Debian 12 (bookworm) —— 完全支持" ;;
        debian:13) DISTRO_TAG="Debian 13 (trixie) —— 完全支持" ;;
        debian:*)  DISTRO_TAG="Debian ${DISTRO_VERSION} —— 未测试版本，按兼容模式运行" ;;
        *)
            if [[ " ${DISTRO_LIKE} " == *debian* ]]; then
                DISTRO_TAG="${DISTRO_ID} ${DISTRO_VERSION} (Debian 衍生版) —— 兼容模式"
            else
                DISTRO_TAG="${DISTRO_ID:-未知发行版} ${DISTRO_VERSION} —— 非 Debian 系，仍按 apt 流程尝试"
            fi
            ;;
    esac

    IS_CONTAINER=0
    if [[ -f /.dockerenv ]] || { command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --quiet --container; }; then
        IS_CONTAINER=1
    fi

    RUNNING_KERNEL=$(uname -r)
    return 0
}

print_banner() {
    log "=============================================================="
    log " Debian 12 / 13 系统清理脚本"
    log "=============================================================="
    log " 发行版     : ${DISTRO_TAG}"
    log " 运行内核   : ${RUNNING_KERNEL}"
    if (( IS_CONTAINER )); then
        log " 环境       : 容器"
    else
        log " 环境       : 物理机 / 虚拟机"
    fi
    (( DRY_RUN )) && log " 模式       : DRY-RUN（只显示，不修改）"
    log "=============================================================="
    return 0
}

# -----------------------------------------------------------------------------
# 步骤执行器：每步前后统计根分区可用空间
# -----------------------------------------------------------------------------
FREED_TOTAL_KB=0

run_step() {
    local title="$1"; shift
    local before after delta
    before=$(disk_avail)
    printf '\n==> %s\n' "$title"
    "$@" || warn "步骤「$title」执行期间出现错误（已继续后续步骤）"
    if (( DRY_RUN )); then
        printf '    （dry-run：未做任何修改）\n'
        return 0
    fi
    after=$(disk_avail)
    delta=$(( after - before ))
    if (( delta > 0 )); then
        FREED_TOTAL_KB=$(( FREED_TOTAL_KB + delta ))
        printf '    本步释放约 %s\n' "$(human_kb "$delta")"
    else
        printf '    本步未增加可用空间（tmpfs 清理/日志本已很小，或期间有其他写入）\n'
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 1. 更新软件包索引
# -----------------------------------------------------------------------------
step_update_index() {
    (( CLEAN_APT_UPDATE )) || { info "已跳过软件包索引更新"; return 0; }
    if (( DRY_RUN )); then printf '    [dry-run] apt-get update\n'; return 0; fi

    info "正在更新依赖（软件包索引）..."
    local output
    if output=$(apt-get update -o Acquire::Retries=2 2>&1); then
        (( VERBOSE )) && printf '%s\n' "$output"
    else
        warn "apt-get update 失败（可能无网络或源不可用），将使用本地已有的软件包信息继续清理。"
        printf '%s\n' "$output" | tail -n 3 >&2
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 2. 删除旧内核（Debian 12/13 通用）
# -----------------------------------------------------------------------------
# 列出所有"已安装"的内核相关包（image / headers / modules）
installed_kernel_pkgs() {
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' \
        'linux-image-*' 'linux-headers-*' 'linux-modules-*' 2>/dev/null |
        awk '$1 == "ii" {print $2}'
}

# 按 dpkg 版本号比较，找出已安装的最新内核镜像包（Debian 13 的版本号含 "+deb13"，
# 用 dpkg --compare-versions 才能正确比较）
newest_kernel_image() {
    local pkg ver best="" best_ver=""
    while read -r pkg ver; do
        [[ -n $pkg ]] || continue
        if [[ -z $best_ver ]] || dpkg --compare-versions "$ver" gt "$best_ver"; then
            best="$pkg"; best_ver="$ver"
        fi
    done < <(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' \
                 'linux-image-*' 2>/dev/null | awk '$1 == "ii" {print $2, $3}')
    printf '%s' "$best"
}

# 输出给定包所依赖的包名（用于保护 linux-headers-<ver>-common 之类的共享包）
installed_dependency_names() {
    (($#)) || return 0
    dpkg-query -W -f='${Depends},${Pre-Depends}\n' "$@" 2>/dev/null |
        tr ',|' '\n\n' |
        awk '{print $1}' |
        sed -E 's/\(.*//; s/:.*//' |
        sed '/^$/d' |
        sort -u
}

in_list() {   # in_list 值 数组...
    local needle="$1"; shift
    local x
    (($#)) || return 1
    for x in "$@"; do
        [[ $x == "$needle" ]] && return 0
    done
    return 1
}

step_clean_kernels() {
    (( CLEAN_KERNELS )) || { info "已跳过旧内核清理"; return 0; }

    # 兜底：即使调用方没有设置 RUNNING_KERNEL（例如被其他脚本 source 后直接调用），
    # 也不会因为 set -u 而中断
    RUNNING_KERNEL=${RUNNING_KERNEL:-$(uname -r)}

    if (( IS_CONTAINER )); then
        warn "检测到容器环境：删除内核包不会影响宿主机内核，通常也无需执行。"
    fi

    # ---- 计算必须保留的包 -------------------------------------------------
    # 关键：全部使用字面量（== 通配匹配）而不是 grep 正则。
    # Debian 13 内核包名形如 linux-image-6.12.38+deb13-amd64，
    # 若用 grep -v "6.12.38+deb13-amd64"，"+" 会被当成 ERE 量词而匹配失败，
    # 结果就是"正在运行的内核被当成旧内核删掉"。
    local keep_suffix=("$RUNNING_KERNEL")
    if (( KEEP_NEWEST_KERNEL )); then
        local newest_image
        newest_image=$(newest_kernel_image)
        if [[ -n $newest_image ]]; then
            local newest_suffix="${newest_image#linux-image-}"
            [[ $newest_suffix == "$RUNNING_KERNEL" ]] || keep_suffix+=("$newest_suffix")
        fi
    fi

    local keep_names=() p s
    while read -r p; do
        [[ -n $p ]] || continue
        for s in "${keep_suffix[@]}"; do
            if [[ $p == *"$s"* ]]; then
                keep_names+=("$p")
                break
            fi
        done
    done < <(installed_kernel_pkgs)

    # 被保留包所依赖的包同样不能删（例如 linux-headers-<ver>-common）
    local keep_deps=() dep
    if ((${#keep_names[@]})); then
        while read -r dep; do
            [[ -n $dep ]] && keep_deps+=("$dep")
        done < <(installed_dependency_names "${keep_names[@]}")
    fi

    # ---- 计算待删除的包 ---------------------------------------------------
    local purge_list=()
    while read -r p; do
        [[ -n $p ]] || continue
        # 元包（linux-image-amd64、linux-headers-amd64 等）不含版本号，永远不删
        [[ $p =~ -[0-9]+\.[0-9]+ ]] || continue
        in_list "$p" "${keep_names[@]}" && continue
        in_list "$p" "${keep_deps[@]}" && continue
        purge_list+=("$p")
    done < <(installed_kernel_pkgs)

    if ((${#purge_list[@]} == 0)); then
        info "没有旧内核需要删除。（正在运行：${RUNNING_KERNEL}）"
        return 0
    fi

    info "正在删除未使用的内核..."
    info "保留：${keep_suffix[*]}"
    log  "找到旧内核相关软件包："
    printf '    %s\n' "${purge_list[@]}"

    # ---- 安全网：先让 apt 模拟一次，若会牵连被保留的包则放弃 --------------
    if ! (( DRY_RUN )); then
        local sim
        sim=$(apt-get -s -y purge "${purge_list[@]}" 2>/dev/null)
        local bad=0
        for s in "${keep_names[@]}"; do
            if printf '%s\n' "$sim" | awk -v pkg="$s" '$1 == "Remv" && $2 == pkg {found = 1} END {exit !found}'; then
                warn "模拟结果显示会一并删除被保留的包 ${s}，为安全起见放弃本次内核清理。"
                bad=1
                break
            fi
        done
        (( bad )) && return 0
    fi

    run apt-get purge -y --auto-remove -o Dpkg::Use-Pty=0 "${purge_list[@]}"

    # 更新引导菜单（容器里通常没有 GRUB，静默跳过）
    if command -v update-grub >/dev/null 2>&1; then
        run update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]]; then
        run grub-mkconfig -o /boot/grub/grub.cfg
    else
        info "未检测到 GRUB，跳过引导菜单更新。"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 3. 清理孤立的包（Debian 12: deborphan；Debian 13: deborphan 已被移除）
# -----------------------------------------------------------------------------
step_clean_orphans() {
    (( CLEAN_ORPHANS )) || { info "已跳过孤立包清理"; return 0; }

    if (( USE_DEBORPHAN )); then
        if command -v deborphan >/dev/null 2>&1; then
            info "deborphan 已安装。"
        elif apt-cache show deborphan >/dev/null 2>&1; then
            # Debian 12 (bookworm) 及衍生版仍然提供该包
            info "仓库中存在 deborphan，正在安装..."
            run apt-get install -y deborphan
        else
            # Debian 13 (trixie) 起 deborphan 已从仓库移除，自动回退
            info "当前发行版仓库中没有 deborphan（Debian 13 已移除该软件包），改用 apt-get autoremove --purge。"
        fi

        if command -v deborphan >/dev/null 2>&1; then
            local orphans=()
            while read -r p; do
                [[ -n $p ]] && orphans+=("$p")
            done < <(deborphan 2>/dev/null)
            if ((${#orphans[@]})); then
                info "deborphan 发现 ${#orphans[@]} 个无依赖的孤立库。"
                if (( DEBORPHAN_PURGE )); then
                    run apt-get purge -y --auto-remove "${orphans[@]}"
                else
                    info "默认只报告不删除；如确认无误，可用 DEBORPHAN_PURGE=1 重新运行以一并清理。"
                fi
            else
                info "deborphan 未发现孤立库。"
            fi
        fi
    else
        info "已按配置跳过 deborphan。"
    fi

    info "正在清理不再需要的依赖包（apt-get autoremove --purge）..."
    run apt-get autoremove --purge -y
    return 0
}

# -----------------------------------------------------------------------------
# 4. 清理系统日志文件
# -----------------------------------------------------------------------------
step_clean_logs() {
    (( CLEAN_LOGS )) || { info "已跳过日志清理"; return 0; }

    local dirs=()
    [[ -d /var/log ]] && dirs+=(/var/log)
    [[ -d /root ]]    && dirs+=(/root)
    ((${#dirs[@]})) || return 0

    # 原脚本写成 -name ".log"（缺少通配符 *），实际上一个文件都没匹配到；
    # 这里使用 truncate 而不是删除，正在写入日志的服务不会被破坏。
    info "正在清理系统日志文件（截断 *.log，保留文件本身）..."
    run find "${dirs[@]}" -xdev -type f ! -name '*.gz' \
        \( -name '*.log' -o -name '*.log.[0-9]*' \) \
        -exec truncate -s 0 -- {} +

    # Debian 上 syslog/messages 等没有 .log 后缀，属于"系统日志"的一部分
    if [[ -n ${LOG_EXTRA_FILES// /} ]]; then
        local f
        for f in $LOG_EXTRA_FILES; do   # 这里需要按空格拆分，故意不加引号
            [[ -f /var/log/$f && ! -L /var/log/$f ]] || continue
            run truncate -s 0 -- "/var/log/$f"
        done
        info "已截断 /var/log/{${LOG_EXTRA_FILES// /,}}"
    fi

    if (( LOG_REMOVE_COMPRESSED )); then
        info "删除已压缩的历史日志归档（*.gz / *.old）..."
        run find "${dirs[@]}" -xdev -type f \
            \( -name '*.log.gz' -o -name '*.log.[0-9]*.gz' -o -name '*.log.*.old' \) -delete
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 5. 清理缓存目录（/tmp、/var/tmp）
# -----------------------------------------------------------------------------
step_clean_tmp() {
    (( CLEAN_TMP )) || { info "已跳过 /tmp 与 /var/tmp 清理"; return 0; }

    local has_mountpoint=0
    command -v mountpoint >/dev/null 2>&1 && has_mountpoint=1

    local d fstype entry
    for d in /tmp /var/tmp; do
        [[ -d $d ]] || continue

        fstype=$(findmnt -no FSTYPE --target "$d" 2>/dev/null || true)
        if [[ $fstype == tmpfs ]]; then
            info "$d 位于 tmpfs（Debian 13 起 /tmp 默认是内存盘），清理它释放的是内存而不是磁盘空间。"
        fi

        info "正在清理缓存目录 $d ..."
        # 原脚本用 rm -rf "$d"/*，会漏掉隐藏文件；find 更彻底
        run find "$d" -mindepth 1 -maxdepth 1 ! -type d -exec rm -rf -- {} +

        # 目录逐个删除，遇到挂载点则跳过，避免误删挂载进来的数据
        while IFS= read -r -d '' entry; do
            if (( has_mountpoint )) && mountpoint -q "$entry"; then
                warn "跳过挂载点：$entry"
                continue
            fi
            run rm -rf -- "$entry"
        done < <(find "$d" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    done
    return 0
}

# -----------------------------------------------------------------------------
# 6. 清理用户缓存目录
# -----------------------------------------------------------------------------
step_clean_user_caches() {
    (( CLEAN_USER_CACHES )) || { info "已跳过用户缓存清理"; return 0; }

    # root 用户：原脚本的 rm -r ~/.cache/pip（sudo 下 ~ 即 /root），这里补上 -f
    info "正在清理 /root/.cache/pip ..."
    run rm -rf -- /root/.cache/pip

    # 原脚本 for user in /home/ 永远不会遍历到任何用户目录
    local nullglob_was_set=0
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    local homes=(/home/*)
    (( nullglob_was_set )) || shopt -u nullglob

    if ((${#homes[@]} == 0)); then
        info "/home 下没有用户目录。"
        return 0
    fi

    local home
    for home in "${homes[@]}"; do
        [[ -d $home ]] || continue
        [[ -L $home ]] && continue
        if [[ -e $home/.cache || -L $home/.cache ]]; then
            info "正在清理 $home/.cache ..."
            run rm -rf -- "$home/.cache"
        fi
    done
    return 0
}

# -----------------------------------------------------------------------------
# 7. 清理 APT 本地存档与缓存
# -----------------------------------------------------------------------------
step_clean_apt_cache() {
    (( CLEAN_APT_CACHE )) || { info "已跳过 APT 缓存清理"; return 0; }

    info "正在清理 APT 的本地存档 /var/cache/apt/archives ..."
    # 原脚本的 rm -rf /var/cache/apt/archives/* 会漏掉隐藏文件与 partial 子目录
    if [[ -d /var/cache/apt/archives ]]; then
        run find /var/cache/apt/archives -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi

    info "正在清理包管理器缓存..."
    run apt-get autoclean
    run apt-get autoremove -y
    run apt-get clean
    return 0
}

# -----------------------------------------------------------------------------
# 8. 清理 Docker（如果使用 Docker）
# -----------------------------------------------------------------------------
step_clean_docker() {
    (( CLEAN_DOCKER )) || { info "已跳过 Docker 清理"; return 0; }

    if ! command -v docker >/dev/null 2>&1; then
        info "未安装 Docker，跳过。"
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        warn "Docker 守护进程未运行（或不可访问），跳过 Docker 清理。"
        return 0
    fi

    if (( DOCKER_PRUNE_VOLUMES )); then
        info "正在清理 Docker 镜像、容器和卷（注意：数据卷会被删除）..."
        run docker system prune -a -f --volumes
    else
        info "正在清理 Docker 镜像和容器（已按配置保留数据卷）..."
        run docker system prune -a -f
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 9. 收缩 systemd journal 日志
# -----------------------------------------------------------------------------
step_clean_journal() {
    (( CLEAN_JOURNAL )) || { info "已跳过 journal 清理"; return 0; }

    if ! command -v journalctl >/dev/null 2>&1; then
        info "未安装 journalctl，跳过。"
        return 0
    fi
    if [[ ! -d /run/systemd/system ]]; then
        info "当前系统未以 systemd 运行（容器/WSL 等），跳过 journal 清理。"
        return 0
    fi

    info "正在收缩 systemd journal（保留 ${JOURNAL_KEEP_TIME} 且不超过 ${JOURNAL_MAX_SIZE}）..."
    # 先 rotate，否则正在写入的当前日志文件无法被 vacuum 回收
    run journalctl --rotate
    run journalctl --vacuum-time="$JOURNAL_KEEP_TIME"
    run journalctl --vacuum-size="$JOURNAL_MAX_SIZE"
    return 0
}

# -----------------------------------------------------------------------------
# 结果汇总
# -----------------------------------------------------------------------------
print_summary() {
    local before_used="$1" before_avail="$2" after_used="$3" after_avail="$4"
    local freed_kb=$(( before_used - after_used ))
    local avail_gain=$(( after_avail - before_avail ))
    (( freed_kb < 0 )) && freed_kb=0

    log ""
    log "=============================================================="
    log " 清理前  已用 $(human_kb "$before_used") / 可用 $(human_kb "$before_avail")"
    log " 清理后  已用 $(human_kb "$after_used") / 可用 $(human_kb "$after_avail")"
    log " 根分区可用空间增加：$(human_kb "$avail_gain")"
    log "=============================================================="
    log "系统清理完成，清理了 $(( freed_kb / 1024 ))M 空间！"
    (( avail_gain < 0 )) && warn "可用空间未增加，说明清理期间有其他进程写入磁盘。"
    return 0
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    require_root
    detect_environment
    print_banner

    local before_used before_avail after_used after_avail
    before_used=$(disk_used); before_avail=$(disk_avail)

    run_step "更新软件包索引"                 step_update_index
    run_step "删除未使用的旧内核"             step_clean_kernels
    run_step "清理孤立的软件包"               step_clean_orphans
    run_step "清理系统日志文件"               step_clean_logs
    run_step "清理缓存目录（/tmp、/var/tmp）" step_clean_tmp
    run_step "清理用户缓存目录"               step_clean_user_caches
    run_step "清理 APT 本地存档与缓存"        step_clean_apt_cache
    run_step "清理 Docker（如已安装）"        step_clean_docker
    run_step "收缩 systemd journal 日志"      step_clean_journal

    if (( DRY_RUN )); then
        log ""
        log "DRY-RUN 结束，未对系统做任何修改。去掉 --dry-run 即可真正执行。"
        return 0
    fi

    read -r after_used after_avail <<<"$(disk_used) $(disk_avail)"
    print_summary "$before_used" "$before_avail" "$after_used" "$after_avail"
    return 0
}

main "$@"
