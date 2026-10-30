#!/bin/bash
#
# Go 语言安装 / 升级脚本（Debian / Ubuntu）
#
# 用法：
#   sudo bash golong.sh              # 安装官方最新稳定版
#   sudo GO_VERSION=1.23.4 bash golong.sh   # 安装指定版本
#
# 安装到 /usr/local/go，PATH 写入 /etc/profile.d/go.sh（对所有用户生效）。
# GOPATH 使用 Go 默认值 $HOME/go，无需额外配置。

set -euo pipefail

INSTALL_DIR="/usr/local"
PROFILE_SNIPPET="/etc/profile.d/go.sh"
GO_VERSION="${GO_VERSION:-}"

die() { echo "错误：$*" >&2; exit 1; }

# 从终端读取输入，兼容 curl ... | bash 的用法
ask() {
  local prompt=$1 reply=''
  if [ -r /dev/tty ]; then
    read -r -p "$prompt" reply </dev/tty || true
  fi
  [[ $reply =~ ^[Yy]$ ]]
}

[ "$(id -u)" -eq 0 ] || die "请使用 sudo 或 root 权限运行此脚本"

for cmd in curl tar sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
done

# 架构检测
case "$(uname -m)" in
  x86_64)        ARCH="linux-amd64" ;;
  aarch64|arm64) ARCH="linux-arm64" ;;
  armv6l|armv7l) ARCH="linux-armv6l" ;;
  i386|i686)     ARCH="linux-386" ;;
  *) die "不支持的架构：$(uname -m)" ;;
esac

# 未指定版本时取官方最新稳定版（输出第一行形如 go1.23.4）
if [ -z "$GO_VERSION" ]; then
  GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n 1 | sed 's/^go//') \
    || die "无法获取最新版本号，请用 GO_VERSION=x.y.z 指定"
fi
[[ $GO_VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "版本号格式不对：$GO_VERSION"

# 已安装版本检查（直接用绝对路径，不依赖当前 PATH）
GO_BIN="$INSTALL_DIR/go/bin/go"
if [ -x "$GO_BIN" ]; then
  current=$("$GO_BIN" version | awk '{print $3}')
  if [ "$current" = "go$GO_VERSION" ]; then
    echo "已经是 $current，无需安装。"
    exit 0
  fi
  echo "检测到已安装版本：$current，目标版本：go$GO_VERSION"
  ask "是否替换为 go$GO_VERSION？(y/n) " || { echo "保留现有安装"; exit 0; }
fi

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

package="go$GO_VERSION.$ARCH.tar.gz"
url="https://dl.google.com/go/$package"

echo "正在下载 $package ..."
curl -fL --progress-bar -o "$temp_dir/$package" "$url" || die "下载失败：$url"

# 官方 .sha256 文件里只有哈希值，没有文件名，需要拼成 "哈希  文件名" 再校验
echo "验证文件完整性..."
expected=$(curl -fsSL "$url.sha256") || die "无法下载校验文件"
(cd "$temp_dir" && echo "$expected  $package" | sha256sum -c --quiet -) \
  || die "校验和不匹配！文件可能损坏或被篡改"

# 官方建议：先删除旧目录再解压，避免新旧文件混在一起
echo "正在安装到 $INSTALL_DIR/go ..."
rm -rf "$INSTALL_DIR/go"
tar -C "$INSTALL_DIR" -xzf "$temp_dir/$package"

cat > "$PROFILE_SNIPPET" <<'EOF'
# Go 环境变量（由 golong.sh 生成）
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
EOF
chmod 644 "$PROFILE_SNIPPET"

echo "验证安装..."
"$GO_BIN" version

# 用 go run 跑一个单文件程序，模块模式下不需要 go.mod
cat > "$temp_dir/hello.go" <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("Go 安装成功！")
}
EOF
GOCACHE="$temp_dir/cache" GOPATH="$temp_dir/gopath" "$GO_BIN" run "$temp_dir/hello.go"

echo "安装完成！重新登录或执行 'source $PROFILE_SNIPPET' 后即可直接使用 go 命令。"
