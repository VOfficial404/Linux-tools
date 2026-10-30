# Linux-tools

面向 Debian 12 (bookworm) / Debian 13 (trixie) 服务器的一组运维脚本，通过一个交互式菜单统一调用：系统清理、XanMod 内核、sing-box、Go、SSH 漏洞检查、登录面板等。

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
| 2 | XanMod 内核 + 网络优化 | `Debian/xanmod-kernel.sh` | 按 CPU 指令集级别安装 XanMod 内核，并开启 BBR 等网络参数。仅 x86_64 |
| 3 | SSH 漏洞检查 | `ssh-check.sh` | 检查 sshd 是否受 regreSSHion（CVE-2024-6387）影响，只检查，不修改 |
| 4 | sing-box | `Debian/singbox.sh` | 添加 sing-box 官方 apt 源并安装或升级 |
| 5 | q | `Debian/q.sh` | 添加官方 apt 源，安装 DNS 查询工具 [q](https://github.com/natesales/q) |
| 6 | Go 语言 | `Debian/golong.sh` | 安装官方最新版或指定版本，带 sha256 校验 |
| 7 | 登录面板（motd） | `update-motd/` | 安装 SSH 登录时显示的 logo 和系统信息面板 |

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

### 2. XanMod 内核

- 会执行一次完整的系统升级（`dist-upgrade`），没有交换空间时创建 1G 的 `/swapfile`。
- 按 CPU 支持的指令集自动选择 x64v1 到 x64v4，可以选择 LTS / MAIN / RT 分支。所选的包在软件源里不存在时，自动退到更低的级别或 LTS。
- 网络参数写在 `/etc/sysctl.d/99-xanmod-optimizations.conf`，不需要时删掉这个文件即可。
- 装完需要重启才会使用新内核。

### 6. Go 语言

```bash
sudo bash Debian/golong.sh                    # 最新稳定版
sudo GO_VERSION=1.23.4 bash Debian/golong.sh  # 指定版本
```

安装到 `/usr/local/go`，PATH 写入 `/etc/profile.d/go.sh`，重新登录后生效。

### 7. 登录面板（motd）

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
│   ├── golong.sh
│   ├── q.sh
│   ├── singbox.sh
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
