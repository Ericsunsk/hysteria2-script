# 🚀 Hysteria 2 官方深度调优与一键自动化管理脚本 (`hy2`)

[![GitHub Repository](https://img.shields.io/badge/GitHub-Ericsunsk%2Fhysteria2--script-blue?logo=github)](https://github.com/Ericsunsk/hysteria2-script)
[![Hysteria Version](https://img.shields.io/badge/Hysteria-v2.x-brightgreen)](https://v2.hysteria.network)
[![Platform Support](https://img.shields.io/badge/OS-Linux%20(Debian%2FUbuntu%2FCentOS%2FArch)-orange)](https://github.com/apernet/hysteria)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

基于 [Hysteria 2 官方标准文档](https://v2.hysteria.network) 与 [GitHub 官方仓库 (apernet/hysteria)](https://github.com/apernet/hysteria) 深度打造的高性能、自动化 VPS 部署与调优脚本。

---

## ⚡ 极简一键安装

在你的 Linux VPS 服务器终端中直接运行以下一行命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Ericsunsk/hysteria2-script/main/install.sh)
```

> **提示**：首次运行后，脚本会自动注册系统快捷命令 `hy2`。以后在 VPS 终端任何目录下，直接输入 **`hy2`** 即可快捷呼出控制台！

---

## ✨ 核心特性

- **🐳 Systemd 与 Docker Compose 双部署模式**：支持自由选择 Systemd 本地运行或 Docker Compose 容器隔离部署（`apernet/hysteria:latest` 官方镜像，支持环境隔离与自动重启守护）。
- **🦎 Salamander QUIC 报文混淆加密 (`obfs.type: salamander`)**：支持官方原生 QUIC 协议首部混淆加密，打乱 UDP 报文结构，彻底防止 DPI 深度流量特征识别与主动探测。
- **📜 官方内置 ACME 证书申请**：支持自动获取并续签 Let's Encrypt 正规 TLS 证书（客户端实现 `insecure=0` 强安全校验），同时支持无域名时的 100 年自签名证书。
- **🔀 官方原生端口跳跃 (Port Hopping)**：支持自定义端口范围（如 `:20000-50000`），客户端随机跳跃发包，彻底规避运营商针对 UDP 的 QoS 限制与阻断。
- **⚡ 端口冲突智能自动避让**：自动检测 UDP 端口占用状态（通过 `ss` / `lsof`），端口被占用时自动找到下一个可用端口。
- **🌐 IPv4 / IPv6 双栈自适应识别**：自动检测 VPS 网络协议栈，支持时自动应用 `:port` 双栈监听，无 IPv6 时自动降级为 `0.0.0.0:port`。
- **🔥 平滑热重载 (Hot Reload) 与语法校验**：配置文件修改后先自动执行 `hysteria check` 校验语法，成功后通过热重载更新参数，连接不中断。
- **📊 流量统计看板 (Traffic Stats API)**：内置 127.0.0.1 流量统计接口，可在控制台中实时查看各节点的累计上行/下行消耗流量（自动格式化为 KB/MB/GB）。
- **📈 VPS 实际带宽跑分与动态 QUIC 窗口**：基于 VPS 实际测速结果与物理内存容量，全动态计算最佳 `BDP` 带宽上限与 QUIC 单流/连接接收窗口参数，防止爆内存与发包抖动。
- **🚀 Linux 系统内核底层加速 & Cgroups 保护**：一键开启 `TCP BBR` + `FQ` 队列，系统 UDP 缓冲区扩充至 **32MB**，并配置句柄数与最大内存保护。
- **🛡️ 局域网 ACL 安全防护**：默认拦截 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 等私有 IP 地址，防止节点被用于局域网扫描与滥用。
- **🎲 随机强安全参数**：监听端口与 16 位认证密码默认随机生成（端口覆盖 10000–60000 全区间），同时支持一键自定义。
- **🔄 一键版本升级与维护**：可实时检测并从官方 GitHub Releases 直接升级 Hysteria 2 内核。
- **⏰ Cron 自动化运维与日志定期清理**：默认安装每周日凌晨 3 点自动清理超过 3 天的历史日志，并自动检查升级 Hysteria 2 内核与平滑重载。

---

## 📋 快捷指令参考

| 快捷命令 | 功能说明 (Standard Command) |
| :--- | :--- |
| `hy2` | 呼出控制台面板 (Management Console) |
| `hy2 install` | 安装 / 重新配置服务 (Install / Reconfigure Service) |
| `hy2 tune` | 测速与网络优化 (Speedtest & Network Tuning) |
| `hy2 stats` | 流量统计面板 (Traffic Statistics) |
| `hy2 cron` | 配置 Cron 定时运维 (Cron Auto Maintenance) |
| `hy2 update` | 检查与升级内核 (Update Hysteria Core) |
| `hy2 status` / `hy2 log` | 查看服务日志 (Service Logs) |
| `hy2 restart` | 重启服务 (Restart Service) |
| `hy2 stop` | 停止服务 (Stop Service) |
| `hy2 info` | 查看节点配置与分享链接 (View Node Info) |
| `hy2 uninstall` | 卸载服务 (Uninstall Service) |

---

## 📄 客户端配置参考

### 1. 分享链接格式 (`hy2://`)
安装完成后会自动生成节点分享链接，可直接复制并导入到 **V2RayN**、**Nekobox**、**Sing-box**、**Shadowrocket** 或 **Clash Verge** 等客户端：

```text
hy2://<password>@<server_ip>:<port_range>?insecure=<0_or_1>&sni=<domain>#Hysteria2_Node
```

### 2. Clash Meta (Mihomo) 配置片段
```yaml
proxies:
  - name: Hysteria2-Node
    type: hysteria2
    server: your.vps.ip
    port: 38492  # 或端口跳跃范围 20000-30000
    password: your_secure_password
    sni: bing.com
    skip-cert-verify: true  # 使用 ACME 证书时设为 false
```

---

## 📜 开源许可

本项目使用 [MIT License](LICENSE) 开源。

## 🛠️ 参考链接

- **Hysteria 2 GitHub 官方仓库**：[apernet/hysteria](https://github.com/apernet/hysteria)
- **Hysteria 2 官方文档**：[v2.hysteria.network](https://v2.hysteria.network)
- **本项目仓库**：[Ericsunsk/hysteria2-script](https://github.com/Ericsunsk/hysteria2-script)
