#!/bin/bash
#
# 检查 sshd 是否受 regreSSHion（CVE-2024-6387）影响
#
# 受影响的上游版本：< 4.4p1，以及 8.5p1 <= 版本 < 9.8p1
# Debian / Ubuntu 会把补丁移植回旧版本号，所以先按发行版的软件包版本判断。
#
# 返回码（与旧版保持一致）：
#   0 = 不受影响   1 = 受影响   2 = 未找到 sshd/ssh   3 = 无法解析版本号

# 各发行版里修复该漏洞的 openssh-server 版本
declare -A FIXED_PKG=(
  [debian:bookworm]="1:9.2p1-2+deb12u3"
  [ubuntu:jammy]="1:8.9p1-3ubuntu0.10"
  [ubuntu:noble]="1:9.6p1-3ubuntu13.3"
)

# 1) 发行版软件包版本（有补丁移植信息，最准确）
if [ -r /etc/os-release ] && command -v dpkg-query >/dev/null 2>&1; then
  distro=$( . /etc/os-release; echo "${ID:-}:${VERSION_CODENAME:-}" )
  pkg_ver=$(dpkg-query -W -f='${Version}' openssh-server 2>/dev/null)
  fixed=${FIXED_PKG[$distro]:-}
  if [ -n "$pkg_ver" ] && [ -n "$fixed" ]; then
    if dpkg --compare-versions "$pkg_ver" lt "$fixed"; then
      echo "受影响：openssh-server $pkg_ver（$distro 的修复版本为 $fixed），请执行 apt update && apt install openssh-server"
      exit 1
    fi
    echo "不受影响：openssh-server $pkg_ver（$distro 已包含修复）"
    exit 0
  fi
fi

# 2) 退回按上游版本号判断；优先看服务端 sshd，没有再看 ssh 客户端
sshd_bin=$(command -v sshd 2>/dev/null || true)
[ -z "$sshd_bin" ] && [ -x /usr/sbin/sshd ] && sshd_bin=/usr/sbin/sshd
if [ -n "$sshd_bin" ]; then
  # 旧版 sshd 不认识 -V，但会在用法说明的第一行打印版本号
  version_str=$("$sshd_bin" -V 2>&1)
elif command -v ssh >/dev/null 2>&1; then
  version_str=$(ssh -V 2>&1)
else
  echo "未找到 sshd 或 ssh"
  exit 2
fi

if [[ ! $version_str =~ OpenSSH_([0-9]+)\.([0-9]+) ]]; then
  echo "无法解析版本号：$version_str"
  exit 3
fi
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
v=$(( major * 100 + minor ))

if (( v < 404 || (v >= 805 && v < 908) )); then
  echo "受影响：OpenSSH $major.$minor（若发行版已移植补丁，这可能是误报）"
  exit 1
fi
echo "不受影响：OpenSSH $major.$minor"
exit 0
