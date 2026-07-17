# ss2022

SS2022 一键脚本

## 项目简介
本项目提供针对 Shadowsocks 2022 (SS2022) 规范的自动化服务端部署方案，底层采用高性能的 `shadowsocks-rust` 内核。该脚本旨在提供兼具极致安全性与高可用性的现代代理环境。

**核心特性：**
*   **极强加密标准**：强制启用抗探测能力最强的 `2022-blake3-aes-256-gcm` 协议，并由系统自动生成符合严格规范的 32 字节 Base64 专属密钥。
*   **自动时间校验**：内置系统级网络时间同步（NTP/Chrony）模块，自动校准服务器时间与时区，从根本上解决 SS2022 防重放攻击机制（Anti-Replay）中常见的 `invalid timestamp` 握手失败问题。
*   **严格规范输出**：生成的节点分享链接严格遵守 SIP002 URI 规范（仅对认证信息进行安全的 Base64 编码），确保与各类现代代理客户端（如 v2rayN、Clash Meta/Mihomo、Shadowrocket 等）完美兼容。
*   **全自动化部署**：一键完成系统架构检测、必要依赖安装、内核下载部署及 `systemd` 进程守护托管。

---

## 一键使用方式

请务必确保以 `root` 权限登录您的 Linux 服务器，在终端中复制并运行以下命令即可开始全自动安装：

**推荐使用 `curl` 执行：**
```bash
curl -sSL [https://raw.githubusercontent.com/lanjiangqaq/SS2022-sh/main/install.sh](https://raw.githubusercontent.com/lanjiangqaq/SS2022-sh/main/install.sh) | bash
