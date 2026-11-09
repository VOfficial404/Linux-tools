# Linux-tools

![Debian 12 | 13](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?logo=debian&logoColor=white)
![bash 4+](https://img.shields.io/badge/bash-4%2B-4EAA25?logo=gnubash&logoColor=white)
![AI generated](https://img.shields.io/badge/AI%20generated-Claude%20%26%20GPT-8A63D2)

面向 **Debian 12 / 13** 服务器的一组运维脚本，用一个方向键菜单统一调用。

> [!WARNING]
> **本仓库的脚本和文档由 AI（Claude 和 GPT）生成，非人工编写，可能存在错误。**
> 脚本会以 root 权限修改系统（删除内核和文件、添加软件源、升级系统、写入内核参数等）。使用前请先自己读一遍代码，先在测试机或可以随时重装的 VPS 上试用，确认没问题再用到重要的服务器上。作者不对使用后果负责。

## 运行方式

用 root 运行（整合版，一个文件包含全部脚本，推荐）：

```bash
curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/linux-tools.sh -o linux-tools.sh && sudo bash linux-tools.sh
```

在线版（只下载菜单，用到哪个功能再下载对应的脚本，每次都是最新版）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/VOfficial404/Linux-tools/main/menu.sh)
```

克隆仓库（先看代码或自己修改，运行时直接用本地文件）：

```bash
git clone https://github.com/VOfficial404/Linux-tools.git && cd Linux-tools && sudo bash menu.sh
```

菜单里用 `↑` `↓` 选择、`Enter` 执行，也可以直接输入编号；`q` 退出。终端不支持方向键时加 `LT_PLAIN=1`，线条显示成乱码时加 `LT_ASCII=1`，例如 `sudo LT_PLAIN=1 bash linux-tools.sh`。

## 功能

- **系统维护**：系统清理、Swap 管理、XanMod 内核 + 网络优化、SSH 漏洞检查、SSH 禁止密码登录、修改主机名、内核漏洞 CVE-2026-98432 检测与修复
- **软件与界面**：sing-box 节点、q（DNS 查询工具）、Go 语言、Docker + Compose、SSH 登录面板（motd）
- **第三方脚本**（每次从上游下载原样运行）：TcpQuality、NodeQuality、流媒体解锁检测、DD 重装（InstallNET / reinstall）

每一项的细节、单独运行子脚本的方法、常见问题和构建说明见 **[使用说明](docs/README.md)**。

## 声明

本仓库的全部脚本和文档由 AI（Claude 和 GPT）生成，非人工编写。请在充分理解代码、并在测试环境验证之后再使用。
