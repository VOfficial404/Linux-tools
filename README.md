# Linux-tools

![Debian 12 | 13](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?logo=debian&logoColor=white)
![bash 4+](https://img.shields.io/badge/bash-4%2B-4EAA25?logo=gnubash&logoColor=white)
![AI generated](https://img.shields.io/badge/AI%20generated-Claude%20%26%20GPT-8A63D2)

面向 **Debian 12 (bookworm) / Debian 13 (trixie)** 服务器的一组运维脚本，用一个方向键菜单统一调用：系统清理、Swap、XanMod 内核、SSH 加固与漏洞检查、sing-box、Docker、Go、登录面板等，另外提供网络测试和 DD 重装系统等常用第三方脚本的快捷入口。

> [!WARNING]
> **本仓库的脚本和文档由 AI（Claude 和 GPT）生成，非人工编写。**
> 脚本会以 root 权限修改系统（删除内核和文件、添加软件源、升级系统、写入内核参数等）。使用前请先自己读一遍代码，先在测试机或可以随时重装的 VPS 上试用，确认没问题再用到重要的服务器上。作者不对使用后果负责。

**目录**：[快速开始](#快速开始) · [菜单预览](#菜单预览) · [操作方式](#操作方式) · [功能一览](#功能一览) · [功能说明](#功能说明) · [环境变量](#环境变量) · [常见问题](#常见问题) · [目录结构](#目录结构) · [兼容性](#兼容性)

## 快速开始

用 root 运行下面这一行（整合版，一个文件包含全部脚本）：

```bash
curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/linux-tools.sh -o linux-tools.sh && sudo bash linux-tools.sh
```

<details>
<summary><b>其他运行方式</b>：在线版、克隆仓库</summary>

<br>

三种方式的菜单和功能完全相同。

| 方式 | 适合 | 说明 |
|---|---|---|
| **整合版** `linux-tools.sh` | 大多数情况；访问 GitHub 不稳定的机器 | 所有子脚本都打包在这一个文件里，运行时不再联网拉取本仓库的其他文件 |
| **在线版** `menu.sh` | 想每次都用最新版 | 只有菜单本身。选中某个功能时才从仓库下载对应的子脚本到临时目录，退出时自动删除 |
| **克隆仓库** | 想先读代码、或者自己修改 | 在仓库目录里运行时直接用本地文件，不联网 |

在线版：

```bash
curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/menu.sh -o menu.sh && sudo bash menu.sh
```

已经是 root 时，也可以不保存文件直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/menu.sh)
```

克隆仓库：

```bash
git clone https://github.com/VOfficial404/Linux-tools.git && cd Linux-tools && sudo bash menu.sh
```

菜单查找子脚本的顺序是：本地仓库 → 整合版内置 → 从 GitHub 下载。菜单顶部「脚本」一行会显示当前用的是哪一种。

</details>

## 菜单预览

```text
 ◆ Linux-tools 工具箱 · Debian 12 / 13
──────────────────────────────────────────────────────────────────────────────
 系统  Debian GNU/Linux 13 (trixie)         主机  vps-tokyo-01 · kvm
 内核  6.12.113+deb13-cloud-amd64 · x86_64  运行  14 天 6 小时 · 负载 0.08
 内存  ████░░░░░░ 41% 809M/1.9G             磁盘  ████░░░░░░ 38% 7.5G/19.5G
 脚本  在线下载 raw.githubusercontent.com/VOfficial404/Linux-tools/main
──────────────────────────────────────────────────────────────────────────────
 系统维护 ────────────────────────────────────────────────────────────────────
     1  系统清理                     旧内核、日志、缓存、Docker，逐项勾选
     2  Swap 管理                  ● 1.0G · swappiness 10
 ▸   3  XanMod 内核 + 网络优化     ● 正在使用 XanMod
     4  SSH 漏洞检查                 CVE-2024-6387 regreSSHion，只检查
     5  SSH 禁止密码登录           ▲ 允许密码登录
     6  修改主机名                   当前 vps-tokyo-01
     7  内核漏洞 CVE-2026-98432      严重 9.8 · 检测 / 升级修复 / 临时缓解

 软件与界面 ──────────────────────────────────────────────────────────────────
     8  sing-box 节点              ● 1.12.8 运行中
     9  q（DNS 查询工具）          ○ 未安装
    10  Go 语言                    ● go1.25.3
    11  Docker + Compose           ▲ 28.5.1 未运行
    12  SSH 登录面板（motd）       ● logo 20-DSH-32 系统信息面板

 第三方脚本 运行时从上游下载，原样执行 ───────────────────────────────────────
    13  TcpQuality 网络质量          ibsgss/TcpQuality
    14  NodeQuality 综合测试       ▲ 结果会上传到 nodequality.com
    15  DD 重装：InstallNET        ▲ 清空系统盘 · leitbogioro/Tools
    16  DD 重装：reinstall         ▲ 清空系统盘 · bin456789/reinstall

     0  退出
──────────────────────────────────────────────────────────────────────────────
 ↑↓ 选择 · Enter 执行 · 输入编号直达 · q 退出
```

右侧的状态在终端里是彩色的：<b>●</b> 绿色表示已安装 / 正常，<b>▲</b> 黄色表示需要注意、红色表示危险操作，<b>○</b> 灰色表示未安装。顶部的内存、磁盘占用条超过 70% 变黄，超过 90% 变红。

## 操作方式

| 按键 | 作用 |
|---|---|
| `↑` `↓` 或 `k` `j` | 移动高亮，到头后从另一端继续 |
| `Enter` | 执行高亮的项目 |
| 数字 | 直接输入编号，高亮会立即跳过去，再按 `Enter` 执行；`退格` 修改 |
| `Home` `End` / `PgUp` `PgDn` | 跳到第一项、最后一项 / 一次移动 5 项 |
| `Esc`、`←`、`q` | 子菜单里返回上一级；主菜单里按 `q` 退出 |
| `Ctrl-C` | 正在运行的子脚本被中断，然后回到菜单；在菜单里则直接退出 |

终端太矮时列表会自动滚动，底部横线会提示「↑ 上面还有 / ↓ 下面还有」；终端太窄时系统信息改成单列，过长的文字用省略号截断。

## 功能一览

每个子脚本也可以不经过菜单单独运行，用法写在各自文件的开头和下面的[功能说明](#功能说明)里。

**系统维护**

| 编号 | 功能 | 脚本 | 做什么 |
|:-:|---|---|---|
| 1 | 系统清理 | `Debian/clear.sh` | 扫描并列出每一项能释放多少空间，逐项勾选，确认后才删除。可以预演 |
| 2 | Swap 管理 | `Debian/swap.sh` | 添加、调整、删除 `/swapfile`，设置 swappiness |
| 3 | XanMod 内核 + 网络优化 | `Debian/xanmod-kernel.sh` | 按 CPU 指令集级别安装 XanMod 内核，开启 BBR 等网络参数。仅 x86_64 |
| 4 | SSH 漏洞检查 | `ssh-check.sh` | 检查 sshd 是否受 regreSSHion（CVE-2024-6387）影响。只检查，不修改 |
| 5 | SSH 禁止密码登录 | `Debian/ssh-keyonly.sh` | 只允许密钥登录，可以直接粘贴公钥添加，一键恢复 |
| 6 | 修改主机名 | `Debian/hostname.sh` | 同步 `/etc/hosts`，防止 cloud-init 重启后改回 |
| 7 | 内核漏洞 CVE-2026-98432 | `Debian/cve-2026-98432.sh` | 检测内核是否受这个 9.8 分的远程漏洞影响，升级修复，或先用 nftables 临时缓解 |

**软件与界面**

| 编号 | 功能 | 脚本 | 做什么 |
|:-:|---|---|---|
| 8 | sing-box | `Debian/singbox.sh` | 从官方 apt 源安装，配置 AnyTLS / AnyReality 节点并生成链接 |
| 9 | q | `Debian/q.sh` | 添加官方 apt 源，安装 DNS 查询工具 [q](https://github.com/natesales/q) |
| 10 | Go 语言 | `Debian/golong.sh` | 安装官方最新版或指定版本，带 sha256 校验 |
| 11 | Docker + Compose | `Debian/docker.sh` | 从 Docker 官方源（或国内镜像）安装 Docker 和 Compose 插件 |
| 12 | SSH 登录面板（motd） | `update-motd/` | SSH 登录时显示的 logo 和系统信息面板 |

**第三方脚本**（不是本仓库的脚本，每次从上游下载最新版原样运行，详见 [13–16](#13-16-第三方脚本)）

| 编号 | 功能 | 上游项目 | 注意 |
|:-:|---|---|---|
| 13 | TcpQuality | [ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality) | TCP 网络质量测试 |
| 14 | NodeQuality | [LloydAsp/NodeQuality](https://github.com/LloydAsp/NodeQuality) | 硬件、IP 质量、网络、回程路由综合测试，**结果会上传** |
| 15 | DD 重装：InstallNET | [leitbogioro/Tools](https://github.com/leitbogioro/Tools) | 网络重装 Debian 等系统，**清空系统盘** |
| 16 | DD 重装：reinstall | [bin456789/reinstall](https://github.com/bin456789/reinstall) | 重装为各种 Linux / Windows 或 dd 镜像，**清空系统盘** |

## 功能说明

点开查看每一项的细节和单独运行的方法。

<details>
<summary><b>1. 系统清理</b>：清什么、默认选哪些</summary>

<br>

| 项目 | 默认 | 说明 |
|---|:-:|---|
| 旧内核 | ✓ | 始终保留正在运行的内核和已安装的最新内核。删除前先让 apt 模拟一遍，会连带删除别的包时再问一次 |
| 不再需要的依赖包 | ✓ | `apt-get autoremove --purge` |
| APT 下载缓存 | ✓ | `apt-get clean` |
| systemd 日志 | ✓ | 按保留天数和总大小收缩，可修改 |
| 已轮转的旧日志 | ✓ | `/var/log` 下的 `*.gz`、`*.1` 等，当前日志不受影响 |
| 清空当前日志文件 | | 把 `*.log`、`syslog` 等清零 |
| 临时文件 | ✓ | 只删 `/tmp`、`/var/tmp` 里超过 N 天没用过的文件，跳过服务正在使用的目录 |
| 用户缓存 `~/.cache` | | |
| Docker | | 分 3 档，第 3 档会删除未使用的数据卷，需要再次确认 |

扫描完会出现一个勾选列表：`↑` `↓` 移动，`空格` 或数字键勾选，`a` 全选，`n` 全不选，`回车` 进入下一步，`q` 不做任何修改直接退出。顶部会显示当前项目的说明，下一步还会列出将要执行的内容，确认后才开始删除。

```bash
sudo bash Debian/clear.sh             # 交互式清理
sudo bash Debian/clear.sh --dry-run   # 照常选择，只显示将执行的命令
sudo bash Debian/clear.sh --yes       # 不提问，按默认选中项清理（适合 cron）
```

</details>

<details>
<summary><b>2. Swap 管理</b>：建议大小、支持的文件系统</summary>

<br>

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

</details>

<details>
<summary><b>3. XanMod 内核 + 网络优化</b>：会改动哪些东西</summary>

<br>

- 先选好分支再开始改动系统，在选择界面退出不会做任何修改。
- 会执行一次完整的系统升级（`dist-upgrade`），没有交换空间时创建 1G 的 `/swapfile`。
- 按 CPU 支持的指令集自动选择 x64v1 到 x64v4，可以选择 LTS / MAIN / RT 分支。所选的包在软件源里不存在时，自动退到更低的级别或 LTS。
- 网络参数写在 `/etc/sysctl.d/99-xanmod-optimizations.conf`，不需要时删掉这个文件即可。
- 装完需要重启才会使用新内核。在容器里和非 x86_64 架构上菜单会直接提示不可用。

</details>

<details>
<summary><b>4. SSH 漏洞检查</b>：结果的含义</summary>

<br>

检查本机 OpenSSH 是否受 regreSSHion（CVE-2024-6387）影响，只读取版本信息，不做任何修改。

| 退出码 | 菜单显示 |
|:-:|---|
| 0 | 不受影响 |
| 1 | 受影响，请升级：`apt update && apt install openssh-server` |
| 2 | 系统里没有 sshd / ssh，无需处理 |
| 3 | 无法识别版本，请手动执行 `sshd -V` 查看 |

```bash
sudo bash ssh-check.sh
```

</details>

<details>
<summary><b>5. SSH 禁止密码登录</b>：写入的配置、登不上时怎么恢复</summary>

<br>

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

> [!IMPORTANT]
> 应用后**先不要关闭当前的 SSH 窗口**，另开一个终端确认密钥能登录。万一登不上，在原窗口或服务商的 VNC / 控制台执行：
>
> ```bash
> rm -f /etc/ssh/sshd_config.d/00-linux-tools-keyonly.conf && systemctl reload ssh
> ```

```bash
sudo bash Debian/ssh-keyonly.sh            # 交互式菜单
sudo bash Debian/ssh-keyonly.sh --status   # 查看当前生效的登录设置
sudo bash Debian/ssh-keyonly.sh --restore  # 恢复原来的登录方式
```

</details>

<details>
<summary><b>6. 修改主机名</b></summary>

<br>

- 用 `hostnamectl set-hostname` 修改；没有 systemd 的环境改写 `/etc/hostname`。
- 同步修改 `/etc/hosts` 里的 `127.0.1.1` 一行（先备份）。不改的话，每次用 `sudo` 都会提示 `unable to resolve host`。
- 云服务器上的 cloud-init 默认会在重启时把主机名改回去。检测到时会询问是否写入 `preserve_hostname: true`。
- 主机名只能包含字母、数字、`-` 和 `.`，大写会自动转成小写。

```bash
sudo bash Debian/hostname.sh           # 交互式输入
sudo bash Debian/hostname.sh web01     # 直接修改
```

</details>

<details>
<summary><b>7. 内核漏洞 CVE-2026-98432</b>：修复版本、临时缓解的原理</summary>

<br>

[CVE-2026-98432](https://www.cve.org/CVERecord?id=CVE-2026-98432)：Linux 内核 IPv4 TCP 握手时的 use-after-free，CVSS 9.8。远程未认证的对端在 SYN 里带上 IP 选项就能触发，可能泄露或写坏内核内存、让内核崩溃。影响 4.4 以来的内核。

| 系统 / 分支 | 修复版本 |
|---|---|
| Debian 12（linux） | 6.1.190-1（DLA-4841-1） |
| Debian 12（linux-6.12） | 6.12.113-1~deb12u1（DLA-4850-1） |
| Debian 13 | 6.12.113-1（DSA-6568-1） |
| 上游 / XanMod | 5.10.272、5.15.223、6.1.190、6.6.159、6.12.113、6.18.56、7.2.10，7.3 及以上 |

- **检测**：Debian 内核按 `uname -v` 里的真实包版本（如 `6.1.176-1`）对照 Debian 安全公告；XanMod 等内核按上游版本号判断。同时列出所有已安装的内核，装了修复版但没重启时会提示。
- **修复**：升级已安装的内核元包（`linux-image-amd64`、`linux-image-cloud-amd64`、`linux-xanmod-*` 等），然后重启。没配 Debian 安全更新源时会给出要加的那一行。
- **临时缓解**（不用重启）：用 nftables 在 prerouting 最早阶段丢弃带 IP 选项的 IPv4 TCP 包，漏洞需要的选项就到不了 TCP 握手。正常流量几乎不带 IP 选项。开机自动加载（`lt-cve-2026-98432.service`）；`net.ipv4.tcp_migrate_req` 为 1 时会建议改成 0。升级并重启后可在菜单里移除。
- 容器（LXC / OpenVZ）用的是宿主机内核，只能检测，修复要在宿主机上做。Ubuntu 会把补丁移植到旧版本号，脚本无法判断，请看 Ubuntu 安全公告。

```bash
sudo bash Debian/cve-2026-98432.sh           # 交互式菜单
sudo bash Debian/cve-2026-98432.sh --check   # 只检测：0 不受影响，1 受影响，2 等待重启，3 无法判断
sudo bash Debian/cve-2026-98432.sh --fix     # 不提问，升级内核（不自动重启）
```

</details>

<details>
<summary><b>8. sing-box（AnyTLS / AnyReality）</b></summary>

<br>

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

</details>

<details>
<summary><b>9. q（DNS 查询工具）</b></summary>

<br>

添加 [q](https://github.com/natesales/q) 的官方 apt 软件源和签名密钥，然后用 apt 安装；已安装时会升级到最新版。

```bash
sudo bash Debian/q.sh
```

</details>

<details>
<summary><b>10. Go 语言</b></summary>

<br>

安装到 `/usr/local/go`，PATH 写入 `/etc/profile.d/go.sh`，重新登录后生效。菜单里可以输入版本号，直接回车装官方最新稳定版。

```bash
sudo bash Debian/golong.sh                    # 最新稳定版
sudo GO_VERSION=1.23.4 bash Debian/golong.sh  # 指定版本
```

</details>

<details>
<summary><b>11. Docker + Docker Compose</b></summary>

<br>

- 按 Docker 官方文档添加 apt 源，安装 `docker-ce`、`docker-buildx-plugin`、`docker-compose-plugin` 等。Compose 是 v2 插件，命令是 `docker compose`；可选装一个 `docker-compose` 兼容命令。
- 软件源可选 Docker 官方、阿里云、清华。软件源里没有当前系统代号时，会询问是否改用 bookworm 的包。
- 装过系统自带的 `docker.io`、`podman-docker` 等冲突包时，会列出来确认后再卸载，`/var/lib/docker` 里的数据保留。
- 可选配置容器日志轮转（每个容器最多 3 个 10M 文件），避免日志写满磁盘。
- 可选把当前 sudo 用户加入 docker 组（会提醒这等同于 root 权限）。
- 卸载时删除镜像、容器和数据卷之前会单独确认，默认保留。
- 注意：`docker run -p` 发布的端口会绕过 ufw 直接对外开放，只想本机访问时写成 `-p 127.0.0.1:8080:80`。

```bash
sudo bash Debian/docker.sh                                  # 交互式菜单
sudo bash Debian/docker.sh --install                        # 不提问，按默认选项安装 / 升级
sudo DOCKER_MIRROR=aliyun bash Debian/docker.sh --install   # 用阿里云镜像（也可以是 tuna）
sudo bash Debian/docker.sh --uninstall                      # 卸载
```

</details>

<details>
<summary><b>12. SSH 登录面板（motd）</b></summary>

<br>

装好后，每次 SSH 登录会显示：

- **logo**：4 种可选，彩色或黑白、40×20 或 32×16。安装前会先预览。彩色版需要终端支持 256 色。只会保留一个，换新的时旧的会被删除（以前手动装的小写 `20-dsh-*` 也会一起处理）。
- **系统信息面板**（`25-sysinfo`）：系统版本、开机时长、负载、内存、交换、磁盘占用条、TCP 连接、网卡流量、最近 5 次 SSH 登录。在容器里会按 cgroup 限额显示内存和 CPU。

子菜单还可以隐藏 Debian 默认的内核版本行和 `/etc/motd` 免责声明（原文件会先备份）、预览效果，以及一键卸载恢复默认。

Debian 13 默认没有 `last` 命令，面板里的登录记录需要先安装：

```bash
apt install wtmpdb libpam-wtmpdb
```

</details>

<a id="13-16-第三方脚本"></a>
<details>
<summary><b>13–16. 第三方脚本</b>：菜单为它们做了什么</summary>

<br>

这 4 项**不是本仓库的脚本**，菜单只是快捷入口：每次选中时从上游下载最新版到临时目录，**原样运行，不做任何修改**，也不会打包进整合版（所以整合版用这几项时同样需要联网）。脚本内容由各自作者负责，使用前请先看上游项目的说明。

菜单为它们做的事只有这些：

- 下载成真实文件再用 `bash 文件 参数` 运行，不用 `bash <(curl ...)`。InstallNET.sh 出错时会执行 `bash $0`，reinstall.sh 会用 `$0` 读取自身，在 `/dev/fd/63` 上运行会出问题。
- 把标准输入接到终端。这几个脚本用普通的 `read` 提问，用 `curl ... | bash` 打开菜单时 stdin 是管道，不接的话会读不到输入。
- 运行前说明会做什么、询问常用参数，运行后按各脚本的实际行为解释结果（它们的退出码含义不同，见下表）。
- Ctrl-C 只中断第三方脚本，然后回到菜单。

| 编号 | 上游运行方式 | 菜单的处理 |
|---|---|---|
| 13 TcpQuality | `bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)` | 可以输入附加参数（如 `-v4`、`--intl`、`--all`、`--no-rootfs`），原样传给脚本。默认在临时 Debian rootfs 里测试，不往本机装软件 |
| 14 NodeQuality | `bash <(curl -sL https://run.NodeQuality.com)` | 运行前提醒：结果会上传到 nodequality.com 生成分享链接（包含本机 IP）；它会挂载 `/proc` `/sys` `/dev` 并 chroot 到临时系统。它默认把工作目录建在**当前目录**，菜单固定加 `-d /root`。它无论成功失败都返回 1，菜单不按退出码判断，结束后检查有没有残留的工作目录 |
| 15 InstallNET.sh | `bash InstallNET.sh -debian 13 -pwd 密码 -port 22` | 选 Debian 13 / 12 或自定义参数；密码不回显、输入两次。**不设密码时新系统用公开的默认密码 `LeitboGi0ro`**（装 Alpine 时总是用它），菜单会明确提醒。它只写好 GRUB 启动项，不会自己重启；成功和失败都返回 1，菜单请你看输出里有没有 `[Finish]` 再决定是否重启 |
| 16 reinstall.sh | `bash reinstall.sh debian 13 --ssh-port 22` | 选 Debian 13 / 12、Ubuntu 24.04 或自定义参数（如 `alpine 3.22`、`dd --img=<网址>`、`--ssh-key <公钥>`）。用户名和密码由脚本自己询问（留空则随机生成）。GitHub 下载失败时改用 cnb.cool 镜像。成功后可选：立即重启、取消这次重装（`reinstall.sh reset`）、稍后自己重启 |

> [!CAUTION]
> 两个 DD 重装脚本会**清空整块系统盘**。运行前菜单会列出本机磁盘，并要求**输入本机主机名**确认；在容器里直接拒绝。请先备份，并确认自己会用服务商的 VNC / 控制台。

</details>

## 环境变量

| 变量 | 作用 |
|---|---|
| `LT_REPO_RAW` | 在线下载子脚本的地址，可以改成自己的 fork 或镜像，如 `https://raw.githubusercontent.com/<用户>/<仓库>/<分支>` |
| `LT_ASCII=1` | 只用 ASCII 字符画线条、圆点和占用条（主菜单和各子脚本都生效） |
| `LT_PLAIN=1` | 不用方向键菜单，改为列出全部条目、输入编号（主菜单和各子脚本都生效） |

例如：

```bash
sudo LT_ASCII=1 bash linux-tools.sh
```

`bash linux-tools.sh --help` 可以查看按键和这些变量的说明。

## 常见问题

<details>
<summary><b>线条、圆点显示成方块或问号，或者中文错位</b></summary>

<br>

终端或字体不支持这些字符，或者 SSH 客户端没有用 UTF-8。先把客户端的字符编码改成 UTF-8；还不行就用 `LT_ASCII=1` 运行。脚本发现系统 locale 不是 UTF-8 时，会自己改用 `C.UTF-8`（只对脚本自身生效，不影响它调用的其他程序）。

</details>

<details>
<summary><b>方向键没反应、屏幕上出现 <code>^[[A</code> 之类的字符</b></summary>

<br>

终端不支持光标控制（例如某些网页控制台）。用 `LT_PLAIN=1` 运行，改为输入编号。`TERM=dumb` 或输出不是终端时会自动这样做。

</details>

<details>
<summary><b>下载子脚本失败</b></summary>

<br>

在线版要从 `raw.githubusercontent.com` 下载子脚本，访问 GitHub 困难时：

- 改用[整合版](#快速开始)，除第三方脚本外不需要再联网；
- 或者用 `LT_REPO_RAW` 指向能访问的镜像。

登录面板的文件在 GitHub 下载失败时会自动改用备用短链接；reinstall.sh 会自动改用 cnb.cool 镜像。

</details>

<details>
<summary><b>退出菜单后终端光标不见了</b></summary>

<br>

正常退出和 Ctrl-C 时菜单都会恢复光标；如果 SSH 连接中途断开等原因没能恢复，执行 `reset` 或 `tput cnorm` 即可。

</details>

## 目录结构

```
.
├── linux-tools.sh        # 整合版，由 build.sh 生成，请勿直接修改
├── menu.sh               # 在线版主菜单
├── build.sh              # 同步公共代码、生成 linux-tools.sh
├── ssh-check.sh
├── lib/
│   ├── ui.sh             # 公共的颜色、提问、排版函数
│   └── menu.sh           # 公共的方向键菜单
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

每个脚本都要能单独下载运行，所以 `lib/` 里的公共代码在每个脚本里各有一份，夹在 `# >>> lib/ui.sh >>>` 和 `# <<< lib/ui.sh <<<` 这样的标记行之间。要改公共代码请改 `lib/` 下的文件，不要直接改脚本里的那一段。

修改了 `lib/`、`menu.sh` 或任何子脚本后，运行：

```bash
bash build.sh
```

它分两步：先把 `lib/` 的内容同步到各脚本的标记行之间，再重新生成整合版 `linux-tools.sh`。然后把改动一起提交。

`build.sh` 只做文本处理，不需要 root，也不会修改系统。

## 兼容性

- 为 Debian 12 和 Debian 13 编写，Ubuntu 等其他 apt 系发行版可能部分可用，但没有针对性处理。
- 需要 bash 4 或更高版本，以及 `curl` 或 `wget`。
- 菜单需要在交互式终端里运行。终端宽度至少 40 列，推荐 80 列以上。
- 13–16 的第三方脚本运行时总是需要联网下载。

## 声明

本仓库的全部脚本和本说明文档由 AI（Claude 和 GPT）生成，非人工编写，可能存在错误。请在充分理解代码、并在测试环境验证之后再使用。
