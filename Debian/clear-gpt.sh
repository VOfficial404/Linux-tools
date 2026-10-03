#!/usr/bin/env bash

# Debian 12/13 系统清理脚本
#
# 用法：sudo bash debian-cleanup.sh
# 说明：Docker prune、旧内核删除、临时目录清理都会删除数据，请在生产环境
# 使用前确认这些行为符合预期。

set -u
umask 022

if [[ $(id -u) -ne 0 ]]; then
    echo "此脚本必须以 root 权限运行。" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# Debian 12/13 的 apt 支持该选项，可在 unattended-upgrades 持锁时等待片刻。
apt_cmd=(apt-get -o DPkg::Lock::Timeout=60)

warn() {
    printf '警告：%s\n' "$*" >&2
}

run_quiet() {
    # 清理动作尽量继续执行；单项失败不会阻止后续清理。
    if ! "$@" >/dev/null 2>&1; then
        warn "命令执行失败：$*"
        return 1
    fi
    return 0
}

clean_directory_contents() {
    local directory=$1

    [[ -d "$directory" ]] || return 0

    # find 能正确处理隐藏文件和带空格的路径；-mindepth 1 保留目录本身。
    find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system -- {} + \
        >/dev/null 2>&1 || warn "无法完全清理目录：$directory"
}

get_root_used_kb() {
    # -P 保证只输出一行，避免不同 df 输出格式导致 awk 取错字段。
    df -Pk / | awk 'NR == 2 { print $3; exit }'
}

if [[ ! -r /etc/os-release ]]; then
    warn "找不到 /etc/os-release，无法确认系统版本。"
else
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ ${ID:-} != debian ]]; then
        warn "当前系统不是 Debian（检测到 ${PRETTY_NAME:-未知系统}），脚本仍会尝试执行。"
    else
        debian_major=${VERSION_ID:-unknown}
        debian_major=${debian_major%%.*}
        case "$debian_major" in
            12) echo "检测到 Debian 12，使用兼容清理流程。" ;;
            13) echo "检测到 Debian 13，使用兼容清理流程。" ;;
            *) warn "此脚本针对 Debian 12/13；检测到版本 ${VERSION_ID:-未知}，请先确认。" ;;
        esac
    fi
fi

start_space=$(get_root_used_kb)
if [[ ! $start_space =~ ^[0-9]+$ ]]; then
    warn "无法读取根分区使用量，空间统计将跳过。"
    start_space=''
fi

echo "正在更新软件包索引..."
if ! "${apt_cmd[@]}" update >/dev/null 2>&1; then
    warn "apt-get update 失败，后续操作将继续，但软件包信息可能不是最新。"
fi

echo "正在删除未使用的内核..."
current_kernel=$(uname -r)
kernel_packages=()
latest_backup_image=''

# Debian 12（6.1 内核）和 Debian 13（6.12 内核）都使用以下版本化包名。
# 仅匹配以数字开头的 linux-image/linux-headers，避免误删 amd64 等元包。
while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    [[ "$package" == *"$current_kernel"* ]] && continue

    # 保留一个最新的备用镜像，避免清理后没有可回滚的内核。
    if [[ "$package" == linux-image-* ]]; then
        if [[ -z "$latest_backup_image" ]] || \
           [[ "$(printf '%s\n' "$latest_backup_image" "$package" | sort -V | tail -n 1)" == "$package" ]]; then
            latest_backup_image=$package
        fi
    fi

    kernel_packages+=("$package")
done < <(
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' \
        'linux-image-*' 'linux-headers-*' 2>/dev/null \
        | awk -F '\t' '$2 == "installed" { print $1 }' \
        | grep -E '^linux-(image|headers)-[0-9]'
)

if [[ -n "$latest_backup_image" ]]; then
    filtered_kernel_packages=()
    for package in "${kernel_packages[@]}"; do
        [[ "$package" == "$latest_backup_image" ]] && continue
        filtered_kernel_packages+=("$package")
    done
    kernel_packages=("${filtered_kernel_packages[@]}")
    echo "保留最新的备用内核镜像：$latest_backup_image"
fi

if ((${#kernel_packages[@]} > 0)); then
    printf '找到未运行的版本化内核包，正在删除：%s\n' "${kernel_packages[*]}"
    run_quiet "${apt_cmd[@]}" purge -y -- "${kernel_packages[@]}" || true
    if command -v update-grub >/dev/null 2>&1; then
        run_quiet update-grub || true
    fi
else
    echo "没有可删除的旧内核。"
fi

echo "正在清理不再需要的依赖包..."
run_quiet "${apt_cmd[@]}" autoremove --purge -y || true

echo "正在清理系统日志文件..."
for log_root in /var/log /root; do
    if [[ -d "$log_root" ]]; then
        find "$log_root" -type f -name '*.log' -exec truncate -s 0 -- {} + \
            >/dev/null 2>&1 || warn "无法完全清空 $log_root 下的日志文件。"
    fi
done

echo "正在清理缓存目录..."
clean_directory_contents /tmp
clean_directory_contents /var/tmp
rm -rf -- /root/.cache/pip >/dev/null 2>&1 || warn "无法清理 /root/.cache/pip。"

echo "正在清理用户缓存目录..."
for user_home in /home/*; do
    [[ -d "$user_home/.cache" ]] || continue
    clean_directory_contents "$user_home/.cache"
done

echo "正在清理 APT 本地存档..."
clean_directory_contents /var/cache/apt/archives

if command -v docker >/dev/null 2>&1; then
    echo "正在清理 Docker 镜像、容器和卷..."
    # 保留原脚本的 -a/--volumes 行为；Docker 未运行时只报告警告并继续。
    run_quiet docker system prune -a -f --volumes || true
fi

echo "正在清理包管理器缓存..."
run_quiet "${apt_cmd[@]}" autoclean || true
run_quiet "${apt_cmd[@]}" clean || true

if command -v journalctl >/dev/null 2>&1; then
    echo "正在清理 systemd 日志..."
    run_quiet journalctl --vacuum-time=7d --vacuum-size=1G || true
fi

end_space=$(get_root_used_kb)
if [[ $end_space =~ ^[0-9]+$ && -n $start_space ]]; then
    cleared_space=$((start_space - end_space))
    if ((cleared_space >= 0)); then
        echo "系统清理完成，释放了 $((cleared_space / 1024)) MiB 空间。"
    else
        echo "系统清理完成；清理期间根分区使用量增加了 $(((-cleared_space) / 1024)) MiB。"
    fi
else
    echo "系统清理完成（无法计算释放的空间）。"
fi

exit 0
