# Linux-tools

面向 Debian 12 (bookworm) / Debian 13 (trixie) 服务器的一组运维脚本，通过一个交互式菜单统一调用：系统清理、Swap、XanMod 内核、sing-box、Go、Docker、SSH 漏洞检查、SSH 禁止密码登录、修改主机名、内核漏洞 CVE-2026-98432 检测修复、登录面板等。

> [!WARNING]
> **本仓库的脚本和文档由 AI（Claude 和 GPT）生成，非人工编写。**
> 脚本会以 root 权限修改系统（删除内核和文件、添加软件源、升级系统、写入内核参数等）。使用前请先自己读一遍代码，先在测试机或可以随时重装的 VPS 上试用，确认没问题再用到重要的服务器上。作者不对使用后果负责。

## 快速开始

需要 root 权限。下面两种方式功能完全相同，任选一种。

### 方案一：整合版（一个文件，离线可用）

所有子脚本都打包在 `linux-tools.sh` 里，下载这一个文件就能用。运行时不再联网拉取本仓库的其他文件，适合网络不稳定或访问 GitHub 困难的机器。

```bash
curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/linux-tools.sh -o linux-tools.sh && sudo bash linux-tools.sh
```

### 方案二：在线版（主脚本小，用到才下载）

`menu.sh` 只有菜单本身。选中某个功能时，才会从本仓库下载对应的子脚本到临时目录运行，退出时自动删除。每次用到的都是仓库里的最新版本。

```bash
curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/menu.sh -o menu.sh && sudo bash menu.sh
```

已经是 root 时，也可以不保存文件直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/menu.sh)
```

### 方案三：克隆整个仓库

```bash
git clone https://github.com/VOfficial404/Linux-tools.git && cd Linux-tools && sudo bash menu.sh
```

在仓库目录里运行时，菜单会直接使用本地文件，不会联网下载。

> 菜单查找子脚本的顺序是：本地仓库 → 整合版内置 → 从 GitHub 下载。菜单顶部的「脚本」一行会显示当前用的是哪一种。
> 如果要从自己的 fork 或镜像下载，可以设置环境变量：`LT_REPO_RAW=https://raw.githubusercontent.com/<用户>/<仓库>/<分支>`。

## 菜单功能

| 编号 | 功能 | 对应脚本 | 说明 |
|---|---|---|---|
| 1 | 系统清理 | `Debian/clear.sh` | 先扫描并列出每一项能释放多少空间，逐项勾选、最终确认后才删除。支持预演模式 |
| 2 | Swap 管理 | `Debian/swap.sh` | 添加、调整、删除 `/swapfile`，设置 swappiness |
| 3 | XanMod 内核 + 网络优化 | `Debian/xanmod-kernel.sh` | 按 CPU 指令集级别安装 XanMod 内核，并开启 BBR 等网络参数。仅 x86_64 |
| 4 | SSH 漏洞检查 | `ssh-check.sh` | 检查 sshd 是否受 regreSSHion（CVE-2024-6387）影响，只检查，不修改 |
| 5 | SSH 禁止密码登录 | `Debian/ssh-keyonly.sh` | 只允许密钥登录，可添加公钥、一键恢复 |
| 6 | 修改主机名 | `Debian/hostname.sh` | 修改主机名，同步 `/etc/hosts`，防止 cloud-init 重启后改回 |
| 7 | 内核漏洞 CVE-2026-98432 | `Debian/cve-2026-98432.sh` | 检测内核是否受这个 9.8 分的远程漏洞影响，升级内核修复，或先用 nftables 临时缓解 |
| 8 | sing-box | `Debian/singbox.sh` | 从官方 apt 源安装，配置 AnyTLS / AnyReality 节点并生成链接 |
| 9 | q | `Debian/q.sh` | 添加官方 apt 源，安装 DNS 查询工具 [q](https://github.com/natesales/q) |
| 10 | Go 语言 | `Debian/golong.sh` | 安装官方最新版或指定版本，带 sha256 校验 |
| 11 | Docker + Docker Compose | `Debian/docker.sh` | 从 Docker 官方源（或国内镜像）安装 Docker 和 Compose 插件 |
| 12 | 登录面板（motd） | `update-motd/` | 安装 SSH 登录时显示的 logo 和系统信息面板 |

每个子脚本也可以不经过菜单单独运行，用法写在各自文件的开头。

### 1. 系统清理

| 项目 | 默认 | 说明 |
|---|---|---|
| 旧内核 | 选中 | 始终保留正在运行的内核和已安装的最新内核。删除前先让 apt 模拟一遍，会连带删除别的包时再问一次 |
| 不再需要的依赖包 | 选中 | `apt-get autoremove --purge` |
| APT 下载缓存 | 选中 | `apt-get clean` |
| systemd 日志 | 选中 | 按保留天数和总大小收缩，可修改 |
| 已轮转的旧日志 | 选中 | `/var/log` 下的 `*.gz`、`*.1` 等，当前日志不受影响 |
| 清空当前日志文件 | 不选 | 把 `*.log`、`syslog` 等清零 |
| 临时文件 | 选中 | 只删 `/tmp`、`/var/tmp` 里超过 N 天没用过的文件，跳过服务正在使用的目录 |
| 用户缓存 `~/.cache` | 不选 | |
| Docker | 不选 | 分 3 档，第 3 档会删除未使用的数据卷，需要再次确认 |

单独运行时的选项：

```bash
sudo bash Debian/clear.sh             # 交互式清理
sudo bash Debian/clear.sh --dry-run   # 照常选择，只显示将执行的命令
sudo bash Debian/clear.sh --yes       # 不提问，按默认选中项清理（适合 cron）
```

### 2. Swap 管理

功能参考 [spiritLHLS/addswap](https://github.com/spiritLHLS/addswap)，针对 Debian 12/13 重写：

- 建议大小：内存 ≤2G 取 2 倍，≤8G 取 1 倍，更大取 4G，也可以自己填（`1G`、`512M`、纯数字按 MB）。
- 已有 `/swapfile` 时可以直接改成新的大小。创建前会检查磁盘空间，创建后至少给系统留 1G。
- 删除时只关闭 `/swapfile`，swap 分区和 zram 不受影响；swap 里的数据比可用内存多时会先提醒。
- 修改 `/etc/fstab` 前先备份，只改 `/swapfile` 那一行。
- swappiness 保存在 `/etc/sysctl.d/99-zz-swappiness.conf`。
- 支持 ext4、xfs、btrfs（自动关闭写时复制）。不支持 zfs，也不能在 OpenVZ / LXC 等容器里添加 swap。

```bash
sudo bash Debian/swap.sh                  # 交互式菜单
sudo bash Debian/swap.sh --add 2G         # 添加 2G（已有时改为 2G）
sudo bash Debian/swap.sh --remove         # 删除 /swapfile
sudo bash Debian/swap.sh --swappiness 10  # 设置 swappiness
```

在线单独运行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/Debian/swap.sh)
```

### 3. XanMod 内核

- 会执行一次完整的系统升级（`dist-upgrade`），没有交换空间时创建 1G 的 `/swapfile`。
- 按 CPU 支持的指令集自动选择 x64v1 到 x64v4，可以选择 LTS / MAIN / RT 分支。所选的包在软件源里不存在时，自动退到更低的级别或 LTS。
- 网络参数写在 `/etc/sysctl.d/99-xanmod-optimizations.conf`，不需要时删掉这个文件即可。
- 装完需要重启才会使用新内核。

### 5. SSH 禁止密码登录

- 不改 `/etc/ssh/sshd_config` 本身，只写一个单独的文件 `/etc/ssh/sshd_config.d/00-linux-tools-keyonly.conf`：

  ```
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitEmptyPasswords no
  PermitRootLogin prohibit-password   # 可选：只允许密钥 / 完全禁止 / 不修改
  ```

  文件名用 `00` 开头，是因为 sshd 只认同一选项第一次出现的值，这样能排在云服务器上 cloud-init 写的 `50-cloud-init.conf`（里面常有 `PasswordAuthentication yes`）前面。
- **不会**设置 `UsePAM no`：Debian 上关掉 PAM，登录面板（motd）、资源限制、systemd 登录会话都会失效。关掉 `KbdInteractiveAuthentication` 就足以让 PAM 不再询问密码。网上教程里的 `ChallengeResponseAuthentication` 是它的旧名字。
- 应用前会列出每个用户有几把公钥。没有任何公钥时拒绝执行；当前使用的用户没有公钥时会警告并再确认一次。
- 写入后先用 `sshd -t` 检查语法、用 `sshd -T` 确认真的生效，不对就自动撤销；最后用 `systemctl reload ssh`，已连着的会话不会断开。
- 菜单里可以直接粘贴公钥添加到某个用户的 `authorized_keys`，权限会自动设好。

**应用后请先不要关闭当前的 SSH 窗口**，另开一个终端确认密钥能登录。万一登不上，在原窗口或服务商的 VNC / 控制台执行：

```bash
rm -f /etc/ssh/sshd_config.d/00-linux-tools-keyonly.conf && systemctl reload ssh
```

```bash
sudo bash Debian/ssh-keyonly.sh            # 交互式菜单
sudo bash Debian/ssh-keyonly.sh --status   # 查看当前生效的登录设置
sudo bash Debian/ssh-keyonly.sh --restore  # 恢复原来的登录方式
```

### 6. 修改主机名

```bash
sudo bash Debian/hostname.sh           # 交互式输入
sudo bash Debian/hostname.sh web01     # 直接修改
```

- 用 `hostnamectl set-hostname` 修改；没有 systemd 的环境改写 `/etc/hostname`。
- 同步修改 `/etc/hosts` 里的 `127.0.1.1` 一行（先备份）。不改的话，每次用 `sudo` 都会提示 `unable to resolve host`。
- 云服务器上的 cloud-init 默认会在重启时把主机名改回去。检测到时会询问是否写入 `preserve_hostname: true`。
- 主机名只能包含字母、数字、`-` 和 `.`，大写会自动转成小写。

### 7. 内核漏洞 CVE-2026-98432

[CVE-2026-98432](https://www.cve.org/CVERecord?id=CVE-2026-98432)：Linux 内核 IPv4 TCP 握手时的 use-after-free，CVSS 9.8。远程未认证的对端在 SYN 里带上 IP 选项就能触发，可能泄露或写坏内核内存、让内核崩溃。影响 4.4 以来的内核。

| 系统 / 分支 | 修复版本 |
|---|---|
| Debian 12（linux） | 6.1.190-1（DLA-4841-1） |
| Debian 12（linux-6.12） | 6.12.113-1~deb12u1（DLA-4850-1） |
| Debian 13 | 6.12.113-1（DSA-6568-1） |
| 上游 / XanMod | 5.10.272、5.15.223、6.1.190、6.6.159、6.12.113、6.18.56、7.2.10，7.3 及以上 |

```bash
sudo bash Debian/cve-2026-98432.sh           # 交互式菜单
sudo bash Debian/cve-2026-98432.sh --check   # 只检测：0 不受影响，1 受影响，2 等待重启，3 无法判断
sudo bash Debian/cve-2026-98432.sh --fix     # 不提问，升级内核（不自动重启）
```

- **检测**：Debian 内核按 `uname -v` 里的真实包版本（如 `6.1.176-1`）对照 Debian 安全公告；XanMod 等内核按上游版本号判断。同时列出所有已安装的内核，装了修复版但没重启时会提示。
- **修复**：升级已安装的内核元包（`linux-image-amd64`、`linux-image-cloud-amd64`、`linux-xanmod-*` 等），然后重启。没配 Debian 安全更新源时会给出要加的那一行。
- **临时缓解**（不用重启）：用 nftables 在 prerouting 最早阶段丢弃带 IP 选项的 IPv4 TCP 包，漏洞需要的选项就到不了 TCP 握手。正常流量几乎不带 IP 选项。开机自动加载（`lt-cve-2026-98432.service`）；`net.ipv4.tcp_migrate_req` 为 1 时会建议改成 0。升级并重启后可在菜单里移除。
- 容器（LXC / OpenVZ）用的是宿主机内核，只能检测，修复要在宿主机上做。Ubuntu 会把补丁移植到旧版本号，脚本无法判断，请看 Ubuntu 安全公告。

### 8. sing-box（AnyTLS / AnyReality）

- 从 sing-box 官方 apt 源安装稳定版（会校验签名密钥），AnyTLS 需要 1.12.0 以上。
- 可配置三种模式：仅 AnyReality、仅 AnyTLS（自签证书）、两者都开。端口、密码、SNI 都可以自己填，回车用默认值，密码默认随机生成。
- 写入前备份原配置到 `/etc/sing-box/config.json.bak`，写入后先用 `sing-box check` 检查，不通过就恢复原配置、不重启服务。
- 配置完成后输出 `anytls://` 链接，以后也可以在菜单里再次查看。节点信息保存在 `/root/.sb_info.json`，只有 root 能读。
- ufw 防火墙开着时，会询问是否放行端口。

```bash
sudo bash Debian/singbox.sh             # 交互式菜单
sudo bash Debian/singbox.sh --install   # 只安装 / 升级 sing-box 程序
sudo bash Debian/singbox.sh --link      # 显示节点链接
```

### 10. Go 语言

```bash
sudo bash Debian/golong.sh                    # 最新稳定版
sudo GO_VERSION=1.23.4 bash Debian/golong.sh  # 指定版本
```

安装到 `/usr/local/go`，PATH 写入 `/etc/profile.d/go.sh`，重新登录后生效。

### 11. Docker + Docker Compose

```bash
sudo bash Debian/docker.sh                                  # 交互式菜单
sudo bash Debian/docker.sh --install                        # 不提问，按默认选项安装 / 升级
sudo DOCKER_MIRROR=aliyun bash Debian/docker.sh --install   # 用阿里云镜像（也可以是 tuna）
sudo bash Debian/docker.sh --uninstall                      # 卸载
```

- 按 Docker 官方文档添加 apt 源，安装 `docker-ce`、`docker-buildx-plugin`、`docker-compose-plugin` 等。Compose 是 v2 插件，命令是 `docker compose`；可选装一个 `docker-compose` 兼容命令。
- 软件源可选 Docker 官方、阿里云、清华。软件源里没有当前系统代号时，会询问是否改用 bookworm 的包。
- 装过系统自带的 `docker.io`、`podman-docker` 等冲突包时，会列出来确认后再卸载，`/var/lib/docker` 里的数据保留。
- 可选配置容器日志轮转（每个容器最多 3 个 10M 文件），避免日志写满磁盘。
- 可选把当前 sudo 用户加入 docker 组（会提醒这等同于 root 权限）。
- 卸载时删除镜像、容器和数据卷之前会单独确认，默认保留。
- 注意：`docker run -p` 发布的端口会绕过 ufw 直接对外开放，只想本机访问时写成 `-p 127.0.0.1:8080:80`。

### 12. 登录面板（motd）

装好后，每次 SSH 登录会显示：

- **logo**：4 种可选，彩色或黑白、40×20 或 32×16。彩色版需要终端支持 256 色。只会保留一个，换新的时旧的会被删除（以前手动装的小写 `20-dsh-*` 也会一起处理）。
- **系统信息面板**（`25-sysinfo`）：系统版本、开机时长、负载、内存、交换、磁盘占用条、TCP 连接、网卡流量、最近 5 次 SSH 登录。在容器里会按 cgroup 限额显示内存和 CPU。

子菜单还可以隐藏 Debian 默认的内核版本行和 `/etc/motd` 免责声明（原文件会先备份）、预览效果，以及一键卸载恢复默认。

Debian 13 默认没有 `last` 命令，面板里的登录记录需要先安装：

```bash
apt install wtmpdb libpam-wtmpdb
```

## 目录结构

```
.
├── linux-tools.sh        # 方案一：整合版，由 build.sh 生成，请勿直接修改
├── menu.sh               # 方案二：在线版主菜单
├── build.sh              # 生成 linux-tools.sh
├── ssh-check.sh
├── Debian/
│   ├── clear.sh
│   ├── cve-2026-98432.sh
│   ├── docker.sh
│   ├── golong.sh
│   ├── hostname.sh
│   ├── q.sh
│   ├── singbox.sh
│   ├── ssh-keyonly.sh
│   ├── swap.sh
│   └── xanmod-kernel.sh
└── update-motd/
    ├── 20-DSH            # 彩色 40×20
    ├── 20-DSH-32         # 彩色 32×16
    ├── 20-DSH-mono       # 黑白 40×20
    ├── 20-DSH-mono-32    # 黑白 32×16
    └── 25-sysinfo        # 系统信息面板
```

## 修改脚本后

修改了 `menu.sh` 或任何子脚本后，需要重新生成整合版，再一起提交：

```bash
bash build.sh
```

`build.sh` 只做文本拼接，不需要 root，也不会修改系统。

## 兼容性

- 为 Debian 12 和 Debian 13 编写，Ubuntu 等其他 apt 系发行版可能部分可用，但没有针对性处理。
- 需要 bash 4 或更高版本，以及 `curl` 或 `wget`（在线版下载用）。
- 菜单需要在交互式终端里运行。

## 声明

本仓库的全部脚本和本说明文档由 AI（Claude 和 GPT）生成，非人工编写，可能存在错误。请在充分理解代码、并在测试环境验证之后再使用。
