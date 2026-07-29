# 🚀 Hysteria 2 官方深度调优与一键自动化管理脚本 (`hy2`)

[![GitHub Repository](https://img.shields.io/badge/GitHub-apernet%2Fhysteria-blue?logo=github)](https://github.com/apernet/hysteria)
[![Hysteria Version](https://img.shields.io/badge/Hysteria-v2.x-brightgreen)](https://v2.hysteria.network)
[![Platform Support](https://img.shields.io/badge/OS-Linux%20(Debian%2FUbuntu%2FCentOS%2FArch)-orange)](https://github.com/apernet/hysteria)

基于 [Hysteria 2 官方标准文档](https://v2.hysteria.network) 与 [GitHub 官方仓库 (apernet/hysteria)](https://github.com/apernet/hysteria) 深度打造的高性能、自动化 VPS 部署与调优脚本。

---

## ⚡ 快速开始

在你的 Linux VPS 服务器终端中运行以下一键指令：

```bash
curl -fsSL https://raw.githubusercontent.com/username/repo/main/install.sh -o install.sh && chmod +x install.sh && sudo ./install.sh
```

> **提示**：首次运行后，脚本会自动注册系统快捷命令 `hy2`。以后在 VPS 终端任何目录下，直接输入 **`hy2`** 即可快捷呼出控制台！

---

## ✨ 核心特性

- **📜 官方内置 ACME 证书申请**：支持自动获取并续签 Let's Encrypt 正规 TLS 证书（客户端实现 `insecure=0` 强安全校验），同时支持无域名时的 100 年自签名证书。
- **🔀 官方原生端口跳跃 (Port Hopping)**：支持自定义端口范围（如 `:20000-50000`），客户端随机跳跃发包，彻底规避运营商针对 UDP 的 QoS 限制与阻断。
- **📊 VPS 实际带宽跑分与动态 QUIC 窗口**：基于 VPS 实际测速结果与物理内存容量，全动态计算最佳 `BDP` 带宽上限与 QUIC 单流/连接接收窗口参数，防止爆内存与发包抖动。
- **🚀 Linux 系统内核底层加速**：一键开启 `TCP BBR` + `FQ` 队列，并将系统 UDP 接收/发送缓冲区扩充至 **32MB**。
- **🛡️ 局域网 ACL 安全防护**：默认拦截 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 等私有 IP 地址，防止节点被用于局域网扫描与滥用。
- **🎲 随机强安全参数**：监听端口与 16 位认证密码默认随机生成，同时支持一键自定义。
- **🔄 一键版本升级与维护**：可实时检测并从官方 GitHub Releases 直接升级 Hysteria 2 内核。

---

## 📋 菜单命令行选项

脚本支持直接通过命令行参数调用常用功能：

| 快捷命令 | 功能说明 |
| :--- | :--- |
| `hy2` | 唤出脚本主控制台菜单 |
| `hy2 install` | 直接执行全自动安装与网络跑分调优 |
| `hy2 tune` | 重新测速并重新优化 QUIC 窗口与带宽 |
| `hy2 update` | 检查并更新 Hysteria 2 内核到官方最新版 |
| `hy2 status` / `hy2 log` | 查看服务运行状态与实时日志 |
| `hy2 restart` | 重启 Hysteria 2 服务 |
| `hy2 uninstall` | 彻底卸载 Hysteria 2 服务与配置文件 |

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

## 🛠️ 参考链接

- **Hysteria 2 GitHub 官方仓库**：[apernet/hysteria](https://github.com/apernet/hysteria)
- **Hysteria 2 官方文档**：[v2.hysteria.network](https://v2.hysteria.network)
