#!/bin/bash
#
# Debian 12 (bookworm) / Debian 13 (trixie) 系统清理脚本
# 功能：删除旧内核、清理孤立依赖、系统日志、临时文件、用户缓存、
#       APT 存档与缓存、Docker 未使用资源，并收缩 systemd 日志
#
# 用法：chmod +x clean_system.sh && sudo ./clean_system.sh
#
# 警告（以下操作不可逆，请确认后再执行）：
#   - 会删除当前运行内核以外的所有已安装内核
#   - 会删除 /home 下所有用户的 .cache 目录
#   - 若安装了 Docker，会删除所有未使用的镜像、容器和卷

set -u

# ---------- 可按需修改的配置 ----------
JOURNAL_VACUUM_TIME="7d"    # systemd 日志保留时长
JOURNAL_VACUUM_SIZE="1G"    # systemd 日志磁盘占用上限

# apt 非交互模式，避免卸载/清理过程中出现交互提示
export DEBIAN_FRONTEND=noninteractive

# ---------- 权限检查：确保以 root 运行 ----------
if [[ $EUID -ne 0 ]]; then
    echo "此脚本必须以root权限运行"
    exit 1
fi

# ---------- 识别 Debian 版本（支持 12 / 13）----------
# 预先置空，防止 os-release 缺少某些字段时变量未定义
VERSION_ID=""; PRETTY_NAME=""; VERSION_CODENAME=""
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
fi
debian_major="${VERSION_ID%%.*}"
case "$debian_major" in
    12) echo "检测到系统：Debian 12 (${VERSION_CODENAME:-bookworm})" ;;
    13) echo "检测到系统：Debian 13 (${VERSION_CODENAME:-trixie})" ;;
    *)  echo "警告：当前系统为 ${PRETTY_NAME:-未知}，本脚本仅在 Debian 12/13 上验证过，仍将继续执行。" ;;
esac

# 记录起始已用空间（单位 KB）；df -P 保证长设备名不换行、字段解析稳定
start_space=$(df -Pk / | awk 'NR==2 {print $3}')

# ---------- 更新软件源 ----------
echo "正在更新依赖..."
if ! apt-get update >/dev/null 2>&1; then
    echo "警告：apt-get update 失败，跳过更新继续清理。"
fi

# ---------- 删除未使用的旧内核 ----------
echo "正在删除未使用的内核..."
current_kernel=$(uname -r)
# 去掉 ABI/架构后缀得到版本前缀（如 6.1.0-21-amd64 -> 6.1.0-21），
# 将当前内核的全部配套包（含 linux-headers-*-common）一并排除，避免误删
kernel_ver="${current_kernel%-*}"
mapfile -t kernel_packages < <(
    dpkg --list \
        | awk '/^ii/ && $2 ~ /^linux-(image|headers)-[0-9]/ {print $2}' \
        | grep -v -E "^linux-(image|headers)-${kernel_ver}-|-${current_kernel}\$"
)
if (( ${#kernel_packages[@]} > 0 )); then
    echo "找到旧内核，正在删除："
    printf '  %s\n' "${kernel_packages[@]}"
    apt-get purge -y "${kernel_packages[@]}" >/dev/null 2>&1
    update-grub >/dev/null 2>&1
else
    echo "没有旧内核需要删除。"
fi

# ---------- 清理孤立的依赖包 ----------
# deborphan 已从 Debian 13 (trixie) 仓库移除，统一使用 apt autoremove，
# Debian 12 与 13 行为保持一致
echo "正在清理不再需要的依赖包..."
apt-get autoremove --purge -y >/dev/null 2>&1

# ---------- 清理系统日志文件 ----------
echo "正在清理系统日志文件..."
find /var/log -type f -name '*.log' -exec truncate -s 0 {} + 2>/dev/null
find /root  -type f -name '*.log' -exec truncate -s 0 {} + 2>/dev/null

# ---------- 清理缓存目录 ----------
echo "正在清理缓存目录..."
rm -rf /tmp/* /var/tmp/* 2>/dev/null
rm -rf /root/.cache/pip 2>/dev/null

# ---------- 清理用户缓存目录 ----------
echo "正在清理用户缓存目录..."
for user_home in /home/*/; do
    [[ -d "${user_home}.cache" ]] || continue
    rm -rf "${user_home}.cache" 2>/dev/null
done

# ---------- 清理 APT 本地存档 ----------
echo "正在清理APT的本地存档..."
rm -rf /var/cache/apt/archives/* 2>/dev/null

# ---------- 清理 Docker（如已安装）----------
if command -v docker >/dev/null 2>&1; then
    echo "正在清理Docker镜像、容器和卷..."
    docker system prune -a -f --volumes >/dev/null 2>&1
fi

# ---------- 清理包管理器缓存 ----------
# apt-get clean 已覆盖 autoclean 的效果；孤立依赖已由上面的 autoremove 处理
echo "正在清理包管理器缓存..."
apt-get clean >/dev/null 2>&1

# ---------- 收缩 systemd 日志 ----------
echo "清空系统日志..."
journalctl --vacuum-time="$JOURNAL_VACUUM_TIME" --vacuum-size="$JOURNAL_VACUUM_SIZE" >/dev/null 2>&1

# ---------- 统计清理结果 ----------
end_space=$(df -Pk / | awk 'NR==2 {print $3}')
cleared_space=$((start_space - end_space))
# 更新依赖等操作可能反而新增文件导致差值为负，此时按 0 处理
(( cleared_space < 0 )) && cleared_space=0
echo "系统清理完成，清理了 $((cleared_space / 1024))M 空间！"
