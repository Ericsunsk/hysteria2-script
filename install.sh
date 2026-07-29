#!/usr/bin/env bash
# ==============================================================================
# Hysteria 2 官方标准深度调优与一键自动化管理脚本 (hy2)
# GitHub 官方仓库: https://github.com/apernet/hysteria
# 本项目地址: https://github.com/Ericsunsk/hysteria2-script
# 参照官方最新文档配置 (内置 ACME 证书 / Salamander 混淆 / 原生端口跳跃 / 全动态 QUIC / Cron 自动运维)
# Supported OS: Debian / Ubuntu / CentOS / AlmaLinux / RockyLinux / Arch
# ==============================================================================

export LANG=C.UTF-8

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 打印日志函数
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查是否为 Root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "该脚本必须以 Root 权限运行！请使用 sudo -i 切换到 root 后再执行。"
        exit 1
    fi
}

# 注册 hy2 全局命令快捷键
shortcut_register() {
    if [[ -f "/Users/sunshikang/Desktop/一件脚本/install.sh" ]]; then
        return
    fi
    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [[ -f "$script_path" && ! -f "/usr/local/bin/hy2" ]]; then
        ln -sf "$script_path" /usr/local/bin/hy2 2>/dev/null
        chmod +x /usr/local/bin/hy2 2>/dev/null
        log_success "已快捷注册系统命令 'hy2'！今后在终端任何位置输入 hy2 即可唤出管理菜单。"
    fi
}

# 检查 UDP 端口是否已被系统进程占用
is_port_occupied() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tuln | awk '{print $5}' | grep -E ":${port}$" &>/dev/null
    elif command -v lsof &>/dev/null; then
        lsof -iUDP:${port} &>/dev/null
    else
        return 1
    fi
}

# 智能查找未被占用的可用 UDP 端口 (冲突自动递增避让，最多尝试 200 次)
get_free_port() {
    local port=$1
    local max_tries=200
    local tries=0
    while is_port_occupied "$port"; do
        log_warn "检测到 UDP 端口 ${port} 已被系统进程占用，正在智能跳过并切换下一个可用端口..."
        port=$((port + 1))
        tries=$((tries + 1))
        if [ "$port" -gt 65535 ]; then
            port=10000
        fi
        if [ "$tries" -ge "$max_tries" ]; then
            log_err "连续尝试 ${max_tries} 个端口均被占用，请手动指定端口。"
            exit 1
        fi
    done
    echo "$port"
}

# 智能检测 VPS 的 IP 协议栈支持情况 (IPv4 / IPv6 双栈)
detect_ip_stack() {
    if ip -6 addr show 2>/dev/null | grep -q "inet6.*global"; then
        echo "dual" # 具有公网 IPv6 地址，使用双栈监听 [::]:port
    else
        echo "ipv4" # 仅支持 IPv4 或 IPv6 未启用，使用 0.0.0.0:port 避免启动失败
    fi
}

# 检查并安装 Docker 环境
install_docker_if_needed() {
    if ! command -v docker &>/dev/null; then
        log_info "未检测到 Docker 环境，正在从官方安装 Docker Engine..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker &>/dev/null
        systemctl start docker &>/dev/null
    fi
}

# 检查是否为 Docker 模式部署
is_docker_mode() {
    if [[ -f /etc/hysteria/docker-compose.yml ]]; then
        return 0
    else
        return 1
    fi
}

# 获取服务运行状态 (自动区分 Systemd 与 Docker)
get_service_status() {
    if is_docker_mode; then
        if command -v docker &>/dev/null && docker inspect -f '{{.State.Running}}' hysteria-server &>/dev/null; then
            local is_running
            is_running=$(docker inspect -f '{{.State.Running}}' hysteria-server 2>/dev/null)
            if [[ "$is_running" == "true" ]]; then
                echo -e "${GREEN}运行中 (Docker 容器)${NC}"
            else
                echo -e "${RED}已停止 (Docker 容器)${NC}"
            fi
        else
            echo -e "${RED}已停止 (Docker 容器)${NC}"
        fi
    else
        if ! command -v hysteria &>/dev/null; then
            echo -e "${YELLOW}未安装 (Not Installed)${NC}"
        elif systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
            echo -e "${GREEN}运行中 (Systemd)${NC}"
        else
            echo -e "${RED}已停止 (Systemd)${NC}"
        fi
    fi
}

# 获取当前已安装的 Hysteria 2 内核版本
get_hysteria_version() {
    if is_docker_mode; then
        if command -v docker &>/dev/null && docker exec hysteria-server hysteria version &>/dev/null; then
            docker exec hysteria-server hysteria version 2>/dev/null | head -n1 | awk '{print $3}' || echo "Docker 镜像"
        else
            echo "Docker 最新版"
        fi
    else
        if command -v hysteria &>/dev/null; then
            hysteria version 2>/dev/null | head -n1 | awk '{print $3}' || echo "已安装"
        else
            echo "无"
        fi
    fi
}

# 获取当前公网 IP
get_public_ip() {
    local ip=""
    ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org || curl -s4 --connect-timeout 5 https://ifconfig.me/ip || curl -s4 --connect-timeout 5 https://icanhazip.com)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6 --connect-timeout 5 https://api64.ipify.org || echo "YOUR_SERVER_IP")
    fi
    echo "$ip"
}

# 随机密码生成器 (16位强密码)
gen_random_pass() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16
}

# 随机端口生成器 (10000 - 60000)，使用 /dev/urandom 突破 RANDOM 的 32767 上限
gen_random_port() {
    if command -v shuf &>/dev/null; then
        shuf -i 10000-60000 -n 1
    else
        local rand
        rand=$(od -An -tu2 -N2 /dev/urandom | tr -d ' ')
        echo $(( 10000 + rand % 50001 ))
    fi
}

# 字节数转人类可读格式 (KB/MB/GB)
format_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", ${bytes}/1073741824}") GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", ${bytes}/1048576}") MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", ${bytes}/1024}") KB"
    else
        echo "${bytes} Bytes"
    fi
}

# 安装基础依赖
install_dependencies() {
    log_info "正在检查并安装基础依赖 (curl, openssl, tar, iptables, nftables, python3, jq, cron)..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y curl openssl tar ufw iptables nftables python3 jq cron speedtest-cli
    elif command -v yum &>/dev/null; then
        yum install -y curl openssl tar firewalld iptables nftables python3 jq crontabs speedtest-cli
    elif command -v dnf &>/dev/null; then
        dnf install -y curl openssl tar firewalld iptables nftables python3 jq crontabs speedtest-cli
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm curl openssl tar iptables nftables python3 jq cronie
    fi
}

# 优化 Linux 内核网络参数 (UDP缓冲区, BBR, 队列深度)
optimize_kernel_network() {
    log_info "正在优化 Linux 系统内核网络参数 (BBR + QUIC UDP 32MB 缓冲区)..."
    
    # 尝试加载 BBR 模块
    modprobe tcp_bbr &>/dev/null
    
    cat << EOF > /etc/sysctl.d/99-hysteria.conf
# Hysteria 2 / QUIC 高性能网络调优 (GitHub: Ericsunsk/hysteria2-script)
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.netdev_max_backlog = 10000
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
EOF

    sysctl -p /etc/sysctl.d/99-hysteria.conf &>/dev/null || sysctl --system &>/dev/null
    log_success "内核网络参数与 BBR 加速配置已成功生效！"
}

# 根据 VPS 物理内存与实测带宽动态计算 QUIC 接收窗口
calculate_dynamic_quic_windows() {
    local down_mbps=$1
    local total_ram_mb
    total_ram_mb=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo "1024")

    # 基于 200ms 跨国 RTT 与 2 倍 BDP 安全余量计算 BDP (单位: 字节)
    local bdp_bytes=$(( down_mbps * 1000000 / 8 * 2 / 10 ))

    local init_stream=$(( bdp_bytes / 4 ))
    if [ "$init_stream" -lt 2097152 ]; then init_stream=2097152; fi

    local max_stream=$(( bdp_bytes / 2 ))
    if [ "$max_stream" -lt 8388608 ]; then max_stream=8388608; fi

    local init_conn=$(( bdp_bytes / 2 ))
    if [ "$init_conn" -lt 4194304 ]; then init_conn=4194304; fi

    local max_conn=$bdp_bytes
    if [ "$max_conn" -lt 16777216 ]; then max_conn=16777216; fi

    local max_cap=33554432 # 默认 32MB
    if [ "$total_ram_mb" -le 1024 ]; then
        max_cap=16777216 # 1GB 及以下内存最高限制 16MB 窗口
    elif [ "$total_ram_mb" -le 2048 ]; then
        max_cap=33554432 # 2GB 内存最高限制 32MB 窗口
    else
        max_cap=67108864 # >2GB 内存可放开至 64MB 窗口
    fi

    if [ "$max_stream" -gt "$max_cap" ]; then max_stream=$max_cap; fi
    if [ "$init_stream" -gt "$max_stream" ]; then init_stream=$((max_stream / 2)); fi
    if [ "$max_conn" -gt "$max_cap" ]; then max_conn=$max_cap; fi
    if [ "$init_conn" -gt "$max_conn" ]; then init_conn=$((max_conn / 2)); fi

    echo "${init_stream}:${max_stream}:${init_conn}:${max_conn}"
}

# VPS 测速与带宽分析
run_network_speedtest() {
    log_info "正在针对 VPS 实际网络带宽进行测速分析 (请稍候)..."
    
    local down_mbps=500
    local up_mbps=200

    if command -v speedtest-cli &>/dev/null; then
        local st_out
        st_out=$(speedtest-cli --simple 2>/dev/null)
        if [[ -n "$st_out" ]]; then
            local dl_val ul_val
            dl_val=$(echo "$st_out" | grep -i "Download" | awk '{print $2}' | cut -d. -f1)
            ul_val=$(echo "$st_out" | grep -i "Upload" | awk '{print $2}' | cut -d. -f1)
            if [[ -n "$dl_val" && "$dl_val" -gt 10 ]]; then down_mbps=$dl_val; fi
            if [[ -n "$ul_val" && "$ul_val" -gt 10 ]]; then up_mbps=$ul_val; fi
            log_success "测速成功！检测到 VPS 实际下行: ${down_mbps} Mbps | 上行: ${up_mbps} Mbps"
        else
            log_warn "Speedtest 测速超时，启用推荐预设网络参数 (上行 200 Mbps / 下行 500 Mbps)"
        fi
    else
        log_warn "未找到 speedtest 工具，使用默认推荐参数 (上行 200 Mbps / 下行 500 Mbps)"
    fi

    local tuned_up=$((up_mbps * 85 / 100))
    local tuned_down=$((down_mbps * 85 / 100))

    if [ "$tuned_up" -lt 50 ]; then tuned_up=50; fi
    if [ "$tuned_down" -lt 100 ]; then tuned_down=100; fi

    echo "${tuned_up}:${tuned_down}:${down_mbps}"
}

# 配置防火墙端口 (支持单端口或端口范围放行)
configure_firewall() {
    local port_spec=$1
    log_info "正在尝试在系统防火墙中放行 UDP 端口/范围: ${port_spec}..."

    # UFW
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${port_spec}/udp" &>/dev/null
        log_success "UFW 防火墙已放行 UDP ${port_spec}"
    fi

    # Firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        if [[ "$port_spec" == *-* ]]; then
            firewall-cmd --permanent --add-port="${port_spec//-/:}/udp" &>/dev/null
        else
            firewall-cmd --permanent --add-port="${port_spec}/udp" &>/dev/null
        fi
        firewall-cmd --reload &>/dev/null
        log_success "Firewalld 防火墙已放行 UDP ${port_spec}"
    fi

    log_warn "提示：若使用的是阿里云、腾讯云、AWS、GCP等云服务器，请务必在【云控制台安全组】中额外放行 UDP ${port_spec} 端口范围！"
}

# 配置 Cron 自动化运维任务
setup_cron_maintenance() {
    check_root
    echo -e "\n${CYAN}Cron 自动化运维与日志清理配置:${NC}"
    echo -e " 1) 开启每周日凌晨 3 点自动清理日志 + 检查内核升级"
    echo -e " 2) 关闭并删除定时运维任务"
    read -rp "请选择操作 [默认: 1]: " cron_choice
    cron_choice=${cron_choice:-1}

    if [[ "$cron_choice" == "1" ]]; then
        cat << 'EOF' > /etc/cron.d/hysteria-maintenance
# Hysteria 2 自动化运维任务 (每周日凌晨 3 点执行日志清理与平滑升级)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * 0 root journalctl --vacuum-time=3d &>/dev/null && /usr/local/bin/hy2 update &>/dev/null
EOF
        chmod 644 /etc/cron.d/hysteria-maintenance
        log_success "已成功配置 Cron 自动化运维定时任务！(/etc/cron.d/hysteria-maintenance)"
    else
        rm -f /etc/cron.d/hysteria-maintenance
        log_success "已关闭并清理定时运维任务。"
    fi
}

# 检查更新 Hysteria 2 内核 (兼容 Systemd 与 Docker)
update_hysteria_binary() {
    check_root
    if is_docker_mode; then
        log_info "正在从 GitHub 官方 Docker Registry 拉取最新的 apernet/hysteria 镜像..."
        if docker compose version &>/dev/null; then
            docker compose -f /etc/hysteria/docker-compose.yml pull
            docker compose -f /etc/hysteria/docker-compose.yml up -d
        else
            docker-compose -f /etc/hysteria/docker-compose.yml pull
            docker-compose -f /etc/hysteria/docker-compose.yml up -d
        fi
        log_success "Docker 版 Hysteria 2 镜像已成功升级至最新版本！"
    else
        log_info "正在从 GitHub 官方 Release (apernet/hysteria) 更新 Hysteria 2 内核..."
        bash <(curl -fsSL https://get.hy2.sh/)
        if [[ $? -eq 0 ]]; then
            log_success "Hysteria 2 内核已更新至最新版本！"
            systemctl restart hysteria-server.service &>/dev/null
        else
            log_err "更新失败，请检查网络连接。"
        fi
    fi
}

# 升级管理脚本自身 (Update hy2 script from GitHub)
update_script() {
    check_root
    log_info "正在从 GitHub 官方仓库 (Ericsunsk/hysteria2-script) 拉取最新管理脚本..."
    local tmp_script="/tmp/hy2_install_tmp.sh"
    curl -fsSL https://raw.githubusercontent.com/Ericsunsk/hysteria2-script/main/install.sh -o "$tmp_script"
    if [[ $? -eq 0 && -s "$tmp_script" ]]; then
        local script_path
        script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
        if [[ -f "$script_path" ]]; then
            cp -f "$tmp_script" "$script_path" 2>/dev/null
            chmod +x "$script_path" 2>/dev/null
        fi
        cp -f "$tmp_script" /usr/local/bin/hy2 2>/dev/null
        chmod +x /usr/local/bin/hy2 2>/dev/null
        rm -f "$tmp_script"
        log_success "管理脚本已成功升级至 GitHub 最新版本！"
    else
        rm -f "$tmp_script"
        log_err "升级脚本失败，请检查网络连接。"
    fi
}

# 查询流量统计数据 (使用官方 Traffic Stats API，人类可读格式)
query_traffic_stats() {
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        log_err "未找到配置文件 /etc/hysteria/config.yaml！"
        return
    fi

    local stats_secret
    stats_secret=$(grep 'secret:' /etc/hysteria/config.yaml | head -n1 | awk '{print $2}')
    if [[ -z "$stats_secret" ]]; then
        log_err "未启用 Traffic Stats API！"
        return
    fi

    log_info "正在查询 Hysteria 2 服务端流量消耗数据..."
    local stats_json
    stats_json=$(curl -s -H "Authorization: ${stats_secret}" http://127.0.0.1:9090/traffic 2>/dev/null)

    if [[ -n "$stats_json" && "$stats_json" != "{}" ]]; then
        echo -e "\n${GREEN}================ 📊 流量统计看板 (Traffic Statistics) ================${NC}"
        if command -v jq &>/dev/null; then
            echo "$stats_json" | jq -r 'to_entries[] | "\(.key) \(.value.tx) \(.value.rx)"' | while read -r user tx rx; do
                local tx_h rx_h
                tx_h=$(format_bytes "$tx")
                rx_h=$(format_bytes "$rx")
                echo -e "  客户端标识: ${CYAN}${user}${NC}"
                echo -e "    ⬆️ 发送流量 (Tx): ${GREEN}${tx_h}${NC}"
                echo -e "    ⬇️ 接收流量 (Rx): ${GREEN}${rx_h}${NC}"
                echo ""
            done
        else
            echo "$stats_json"
        fi
        echo -e "${GREEN}========================================================================${NC}\n"
    else
        log_warn "暂无活动流量数据，或服务未成功启动。API Endpoint: http://127.0.0.1:9090/traffic"
    fi
}

# 从已有 config.yaml 中安全提取字段值
# 用法: extract_yaml_field "auth" "password"  -> 提取 auth 下的 password
extract_config_listen_port() {
    # 从 listen 行中提取纯端口或端口范围，兼容 :port、0.0.0.0:port、:start-end 格式
    grep 'listen:' /etc/hysteria/config.yaml 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/.*://'
}

extract_config_auth_password() {
    # 提取 auth 块下的 password（跳过 salamander 块的 password）
    awk '/^auth:/{found=1} found && /password:/{print $2; exit}' /etc/hysteria/config.yaml 2>/dev/null
}

extract_config_obfs_password() {
    # 提取 salamander 块下的 password
    awk '/salamander:/{found=1} found && /password:/{print $2; exit}' /etc/hysteria/config.yaml 2>/dev/null
}

extract_config_sni() {
    # 优先从 ACME domains 提取，fallback 到证书 CN，最终 fallback 到 bing.com
    local sni=""
    if grep -q "acme:" /etc/hysteria/config.yaml 2>/dev/null; then
        sni=$(awk '/domains:/{getline; print $2; exit}' /etc/hysteria/config.yaml 2>/dev/null | tr -d '- ')
    fi
    if [[ -z "$sni" && -f /etc/hysteria/server.crt ]]; then
        sni=$(openssl x509 -noout -subject -in /etc/hysteria/server.crt 2>/dev/null | sed 's/.*CN *= *//')
    fi
    echo "${sni:-bing.com}"
}

# 主安装逻辑
install_hysteria2() {
    check_root
    install_dependencies
    shortcut_register

    echo -e "\n${PURPLE}====================================================${NC}"
    echo -e "${PURPLE}     Hysteria 2 服务端配置与智能部署                ${NC}"
    echo -e "${PURPLE}====================================================${NC}\n"

    # 自动优化系统内核网络参数
    optimize_kernel_network

    # 0. 部署模式选择 (Systemd vs Docker Compose 容器)
    echo -e "${CYAN}请选择安装与运行模式 (Deployment Mode):${NC}"
    echo -e " 1) Systemd 本地部署 (性能极佳，适合大部分 VPS)"
    echo -e " 2) Docker Compose 容器化部署 (环境彻底隔离，全自动守护更新)"
    read -rp "请选择部署模式 [默认: 1]: " DEPLOY_MODE
    DEPLOY_MODE=${DEPLOY_MODE:-1}

    # 1. 证书模式选择 (自签证书 vs 内置 ACME 官方申请)
    echo -e "\n${CYAN}请选择 TLS 证书模式 (TLS Certificate Mode):${NC}"
    echo -e " 1) 自签名证书模式 (Self-Signed Cert, 免域名)"
    echo -e " 2) ACME 自动申请模式 (Let's Encrypt, 需真实域名)"
    read -rp "请选择证书模式 [默认: 1]: " CERT_MODE
    CERT_MODE=${CERT_MODE:-1}

    local domain_name="bing.com"
    local acme_email=""

    if [[ "$CERT_MODE" == "2" ]]; then
        read -rp "请输入解析到本机 IP 的真实域名: " domain_name
        if [[ -z "$domain_name" ]]; then
            log_err "域名不能为空，回退使用自签名证书模式。"
            CERT_MODE=1
            domain_name="bing.com"
        else
            read -rp "请输入联系邮箱 (用于 Let's Encrypt 通知): " acme_email
            acme_email=${acme_email:-"admin@${domain_name}"}
        fi
    fi

    # 2. Salamander 混淆加密配置 (官方混淆抗 DPI)
    read -rp "是否开启 Hysteria 2 官方 Salamander QUIC 报文混淆加密？(y/N) [默认: n]: " ENABLE_OBFS
    ENABLE_OBFS=${ENABLE_OBFS:-"n"}
    local OBFS_PASS=""
    if [[ "$ENABLE_OBFS" =~ ^[Yy]$ ]]; then
        local default_obfs_pass
        default_obfs_pass=$(gen_random_pass)
        read -rp "请输入 Salamander 混淆密钥 [默认随机: ${default_obfs_pass}]: " OBFS_PASS
        OBFS_PASS=${OBFS_PASS:-$default_obfs_pass}
    fi

    # 智能协议栈识别与端口冲突检测避让
    local ip_stack
    ip_stack=$(detect_ip_stack)
    local listen_prefix=""
    if [[ "$ip_stack" == "dual" ]]; then
        listen_prefix=":" # 监听 [::]:port (双栈)
        log_info "检测到系统支持公网 IPv6，自动开启 IPv4/IPv6 双栈监听支持！"
    else
        listen_prefix="0.0.0.0:" # 仅指定 IPv4
        log_info "检测到系统单栈 IPv4 环境，配置 0.0.0.0 监听。"
    fi

    # 3. 端口模式选择 (单端口 vs 官方原生端口跳跃 Port Hopping)
    local default_p
    default_p=$(gen_random_port)
    default_p=$(get_free_port "$default_p")

    echo -e "\n${CYAN}请选择监听端口模式 (Port Listening Mode):${NC}"
    echo -e " 1) 标准单端口模式 (Single Port: ${default_p})"
    echo -e " 2) 官方原生端口跳跃模式 (Port Hopping: 10000-50000)"
    read -rp "请选择端口模式 [默认: 1]: " PORT_MODE
    PORT_MODE=${PORT_MODE:-1}

    local LISTEN_CONFIG=""
    local PORT_SHOW=""
    local HOP_RANGE=""

    if [[ "$PORT_MODE" == "2" ]]; then
        local hop_start=$((10000 + RANDOM % 20000))
        hop_start=$(get_free_port "$hop_start")
        local hop_end=$((hop_start + 10000))
        read -rp "请输入端口跳跃范围 [默认随机: ${hop_start}-${hop_end}]: " HOP_RANGE
        HOP_RANGE=${HOP_RANGE:-"${hop_start}-${hop_end}"}
        LISTEN_CONFIG="${listen_prefix}${HOP_RANGE}"
        PORT_SHOW="${HOP_RANGE}"
    else
        read -rp "请输入 Hysteria 2 监听端口 [默认随机可用端口: ${default_p}]: " PORT_INPUT
        PORT_INPUT=${PORT_INPUT:-$default_p}
        PORT_INPUT=$(get_free_port "$PORT_INPUT")
        LISTEN_CONFIG="${listen_prefix}${PORT_INPUT}"
        PORT_SHOW="${PORT_INPUT}"
    fi

    # 4. 认证密码与 Traffic Stats Secret
    local default_pass
    default_pass=$(gen_random_pass)
    read -rp "请输入认证密码 [默认随机: ${default_pass}]: " PASSWORD
    PASSWORD=${PASSWORD:-$default_pass}

    local stats_secret
    stats_secret=$(gen_random_pass)

    # 5. 伪装网址
    read -rp "请输入 HTTP 伪装网址 [默认: https://bing.com]: " MASQ_URL
    MASQ_URL=${MASQ_URL:-"https://bing.com"}

    # 6. 网络实测
    read -rp "是否开启网络实测 + QUIC 动态接收窗口优化？(Y/n) [默认: Y]: " ENABLE_TUNE
    ENABLE_TUNE=${ENABLE_TUNE:-"Y"}

    local up_limit="200 mbps"
    local down_limit="500 mbps"
    local raw_down=500

    if [[ "$ENABLE_TUNE" =~ ^[Yy]$ ]]; then
        local tune_result
        tune_result=$(run_network_speedtest)
        local tuned_u
        tuned_u=$(echo "$tune_result" | cut -d: -f1)
        local tuned_d
        tuned_d=$(echo "$tune_result" | cut -d: -f2)
        raw_down=$(echo "$tune_result" | cut -d: -f3)

        up_limit="${tuned_u} mbps"
        down_limit="${tuned_d} mbps"
    fi

    # 动态计算 QUIC 4 项窗口参数
    local quic_wins
    quic_wins=$(calculate_dynamic_quic_windows "$raw_down")
    local init_str
    init_str=$(echo "$quic_wins" | cut -d: -f1)
    local max_str
    max_str=$(echo "$quic_wins" | cut -d: -f2)
    local init_cn
    init_cn=$(echo "$quic_wins" | cut -d: -f3)
    local max_cn
    max_cn=$(echo "$quic_wins" | cut -d: -f4)

    # 准备目录
    mkdir -p /etc/hysteria

    # 混淆配置 YAML 构造
    local obfs_yaml=""
    if [[ -n "$OBFS_PASS" ]]; then
        obfs_yaml="obfs:
  type: salamander
  salamander:
    password: \"${OBFS_PASS}\""
    fi

    # 编写 config.yaml (所有用户输入值均使用 YAML 双引号包裹防注入)
    log_info "正在生成官方标准 Hysteria 2 配置文件 /etc/hysteria/config.yaml..."

    if [[ "$CERT_MODE" == "2" ]]; then
        # ACME 模式
        cat << EOF > /etc/hysteria/config.yaml
listen: ${LISTEN_CONFIG}

acme:
  domains:
    - ${domain_name}
  email: "${acme_email}"

auth:
  type: password
  password: "${PASSWORD}"

${obfs_yaml}

masquerade:
  type: proxy
  proxy:
    url: "${MASQ_URL}"
    rewriteHost: true

bandwidth:
  up: ${up_limit}
  down: ${down_limit}

quic:
  initStreamReceiveWindow: ${init_str}
  maxStreamReceiveWindow: ${max_str}
  initConnReceiveWindow: ${init_cn}
  maxConnReceiveWindow: ${max_cn}
  maxIdleTimeout: 30s
  keepAliveInterval: 10s
  disablePathMTUDiscovery: false

sniff:
  enable: true

trafficStats:
  listen: 127.0.0.1:9090
  secret: "${stats_secret}"

acl:
  inline:
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(127.0.0.0/8)
EOF
    else
        # 自签证书模式
        log_info "正在生成 100 年梯度的 EC 自签名 TLS 证书..."
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/hysteria/server.key \
            -out /etc/hysteria/server.crt \
            -subj "/CN=${domain_name}" \
            -days 36500 &>/dev/null

        if id "hysteria" &>/dev/null; then
            chown -R hysteria:hysteria /etc/hysteria/
        fi
        chmod 600 /etc/hysteria/server.key
        chmod 644 /etc/hysteria/server.crt

        cat << EOF > /etc/hysteria/config.yaml
listen: ${LISTEN_CONFIG}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "${PASSWORD}"

${obfs_yaml}

masquerade:
  type: proxy
  proxy:
    url: "${MASQ_URL}"
    rewriteHost: true

bandwidth:
  up: ${up_limit}
  down: ${down_limit}

quic:
  initStreamReceiveWindow: ${init_str}
  maxStreamReceiveWindow: ${max_str}
  initConnReceiveWindow: ${init_cn}
  maxConnReceiveWindow: ${max_cn}
  maxIdleTimeout: 30s
  keepAliveInterval: 10s
  disablePathMTUDiscovery: false

sniff:
  enable: true

trafficStats:
  listen: 127.0.0.1:9090
  secret: "${stats_secret}"

acl:
  inline:
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(127.0.0.0/8)
EOF
    fi

    # 防火墙
    configure_firewall "${PORT_SHOW}"

    # 默认开启 Cron 自动运维 (含 PATH 声明)
    cat << 'EOF' > /etc/cron.d/hysteria-maintenance
# Hysteria 2 自动化运维任务 (每周日凌晨 3 点执行日志清理与平滑升级)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * 0 root journalctl --vacuum-time=3d &>/dev/null && /usr/local/bin/hy2 update &>/dev/null
EOF
    chmod 644 /etc/cron.d/hysteria-maintenance 2>/dev/null

    # 根据 DEPLOY_MODE 进行 Systemd 部署或 Docker Compose 容器部署
    if [[ "$DEPLOY_MODE" == "2" ]]; then
        # Docker 部署分支
        install_docker_if_needed
        log_info "生成 Docker Compose 配置文件 /etc/hysteria/docker-compose.yml..."
        cat << EOF > /etc/hysteria/docker-compose.yml
version: '3.8'
services:
  hysteria:
    image: apernet/hysteria:latest
    container_name: hysteria-server
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    volumes:
      - /etc/hysteria:/etc/hysteria
    command: ["server", "-c", "/etc/hysteria/config.yaml"]
EOF

        # 清除旧的 systemd 服务以防冲突
        systemctl stop hysteria-server.service &>/dev/null
        systemctl disable hysteria-server.service &>/dev/null

        log_info "正在启动 Docker 容器版 Hysteria 2..."
        if docker compose version &>/dev/null; then
            docker compose -f /etc/hysteria/docker-compose.yml up -d
        else
            docker-compose -f /etc/hysteria/docker-compose.yml up -d
        fi

        sleep 2
        if command -v docker &>/dev/null && docker inspect -f '{{.State.Running}}' hysteria-server 2>/dev/null | grep -q "true"; then
            log_success "Docker 版 Hysteria 2 容器已成功运行！"
        else
            log_err "Docker 容器启动失败，请检查日志！"
            exit 1
        fi
    else
        # Systemd 部署分支
        rm -f /etc/hysteria/docker-compose.yml &>/dev/null
        log_info "开始从 GitHub 官方拉取安装 Hysteria 2 内核..."
        bash <(curl -fsSL https://get.hy2.sh/)
        if [[ $? -ne 0 ]]; then
            log_err "Hysteria 2 官方脚本安装失败，请检查网络连通性。"
            exit 1
        fi

        # 给 systemd 赋予网络修改与资源守护限制 (Cgroups 内存/句柄防护)
        if [[ -f /etc/systemd/system/hysteria-server.service ]]; then
            if ! grep -q "CAP_NET_ADMIN" /etc/systemd/system/hysteria-server.service 2>/dev/null; then
                sed -i '/\[Service\]/a AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE\nLimitNOFILE=1048576\nMemoryMax=85%' /etc/systemd/system/hysteria-server.service 2>/dev/null
            fi
        fi

        # 验证语法校验
        if command -v hysteria &>/dev/null; then
            hysteria check -c /etc/hysteria/config.yaml &>/dev/null
            if [[ $? -ne 0 ]]; then
                log_err "Hysteria 配置文件语法校验失败，请检查设置！"
                exit 1
            fi
        fi

        log_info "配置开机自启并启动服务..."
        systemctl daemon-reload
        systemctl enable hysteria-server.service
        systemctl restart hysteria-server.service

        sleep 2
        if systemctl is-active --quiet hysteria-server.service; then
            log_success "Systemd Hysteria 2 服务已成功运行！"
        else
            log_err "Hysteria 2 服务启动失败，请检查日志！"
            exit 1
        fi
    fi

    # 生成节点链接与客户端配置
    local server_ip
    server_ip=$(get_public_ip)
    local insecure_param="1"
    if [[ "$CERT_MODE" == "2" ]]; then insecure_param="0"; fi

    local main_host="${server_ip}"
    if [[ "$CERT_MODE" == "2" ]]; then main_host="${domain_name}"; fi

    local obfs_query=""
    if [[ -n "$OBFS_PASS" ]]; then
        obfs_query="&obfs=salamander&obfs-password=${OBFS_PASS}"
    fi

    local share_link="hy2://${PASSWORD}@${main_host}:${PORT_SHOW}?insecure=${insecure_param}&sni=${domain_name}${obfs_query}#Hysteria2_${main_host}"

    echo -e "\n${GREEN}====================================================${NC}"
    echo -e "${GREEN}      🎉 Hysteria 2 官方深度调优部署完成！           ${NC}"
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${CYAN}运行模式           :${NC} $(is_docker_mode && echo "Docker Compose 容器" || echo "Systemd")"
    echo -e "${CYAN}服务器地址 / IP    :${NC} ${main_host}"
    echo -e "${CYAN}监听端口 / 范围    :${NC} UDP ${PORT_SHOW} ($([ "$ip_stack" == "dual" ] && echo "IPv4/IPv6 双栈" || echo "IPv4 单栈"))"
    echo -e "${CYAN}认证密码           :${NC} ${PASSWORD}"
    echo -e "${CYAN}Salamander 混淆    :${NC} $([ -n "$OBFS_PASS" ] && echo "已开启 (密钥: ${OBFS_PASS})" || echo "未启用")"
    echo -e "${CYAN}SNI 域名           :${NC} ${domain_name}"
    echo -e "${CYAN}证书验证 (insecure):${NC} ${insecure_param} ($([ "$insecure_param" == "0" ] && echo "正规 ACME 证书安全连接" || echo "自签证书跳过验证"))"
    echo -e "${CYAN}动态带宽限制       :${NC} 上行 ${up_limit} | 下行 ${down_limit}"
    echo -e "${CYAN}流量统计 API       :${NC} http://127.0.0.1:9090/traffic"
    echo -e "${CYAN}内网 ACL 防护      :${NC} 已启用 (自动拒绝内网与私有 IP 扫描)"
    echo -e "${CYAN}Cron 定时运维      :${NC} 每周日凌晨 3 点自动清理日志与检查升级"
    echo -e "${GREEN}----------------------------------------------------${NC}"
    echo -e "${YELLOW}🔗 V2RayN / Nekobox / Sing-box / Shadowrocket 一键分享链接:${NC}"
    echo -e "${PURPLE}${share_link}${NC}"
    echo -e "${GREEN}----------------------------------------------------${NC}"
    echo -e "${CYAN}📄 Clash Meta / Mihomo 客户端配置参考片段:${NC}"
    cat << EOF
proxies:
  - name: Hysteria2-Node
    type: hysteria2
    server: ${main_host}
    port: ${PORT_SHOW}
    password: ${PASSWORD}
$([ -n "$OBFS_PASS" ] && echo "    obfs: salamander")
$([ -n "$OBFS_PASS" ] && echo "    obfs-password: ${OBFS_PASS}")
    sni: ${domain_name}
    skip-cert-verify: $([ "$insecure_param" == "1" ] && echo "true" || echo "false")
EOF
    echo -e "${GREEN}====================================================${NC}\n"
}

# 独立运行网络优化与配置更新 (带平滑热重载)
tune_existing_config() {
    check_root
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        log_err "未找到配置文件 /etc/hysteria/config.yaml，请先安装！"
        return 1
    fi

    optimize_kernel_network
    local tune_result
    tune_result=$(run_network_speedtest)
    local tuned_u
    tuned_u=$(echo "$tune_result" | cut -d: -f1)
    local tuned_d
    tuned_d=$(echo "$tune_result" | cut -d: -f2)
    local raw_d
    raw_d=$(echo "$tune_result" | cut -d: -f3)

    local quic_wins
    quic_wins=$(calculate_dynamic_quic_windows "$raw_d")
    local init_str
    init_str=$(echo "$quic_wins" | cut -d: -f1)
    local max_str
    max_str=$(echo "$quic_wins" | cut -d: -f2)
    local init_cn
    init_cn=$(echo "$quic_wins" | cut -d: -f3)
    local max_cn
    max_cn=$(echo "$quic_wins" | cut -d: -f4)

    log_info "正在根据实测结果重新计算并更新 /etc/hysteria/config.yaml..."

    # 备份原始配置
    cp /etc/hysteria/config.yaml /etc/hysteria/config.yaml.bak

    # 更新 bandwidth 部分
    sed -i "s/^  up: .*/  up: ${tuned_u} mbps/" /etc/hysteria/config.yaml
    sed -i "s/^  down: .*/  down: ${tuned_d} mbps/" /etc/hysteria/config.yaml

    # 更新 QUIC 窗口参数
    sed -i "s/^  initStreamReceiveWindow: .*/  initStreamReceiveWindow: ${init_str}/" /etc/hysteria/config.yaml
    sed -i "s/^  maxStreamReceiveWindow: .*/  maxStreamReceiveWindow: ${max_str}/" /etc/hysteria/config.yaml
    sed -i "s/^  initConnReceiveWindow: .*/  initConnReceiveWindow: ${init_cn}/" /etc/hysteria/config.yaml
    sed -i "s/^  maxConnReceiveWindow: .*/  maxConnReceiveWindow: ${max_cn}/" /etc/hysteria/config.yaml

    # 语法检测 (如果安装了二进制)
    if command -v hysteria &>/dev/null; then
        if ! hysteria check -c /etc/hysteria/config.yaml &>/dev/null; then
            log_err "语法校验错误，正在回滚配置..."
            mv /etc/hysteria/config.yaml.bak /etc/hysteria/config.yaml
            return 1
        fi
    fi

    rm -f /etc/hysteria/config.yaml.bak

    # 平滑热重载 (优先使用 reload 避免中断在线连接)
    if is_docker_mode; then
        if docker compose version &>/dev/null; then
            docker compose -f /etc/hysteria/docker-compose.yml restart
        else
            docker-compose -f /etc/hysteria/docker-compose.yml restart
        fi
    else
        systemctl reload hysteria-server.service 2>/dev/null || systemctl restart hysteria-server.service
    fi
    log_success "网络跑分优化完成！已应用配置更新。"
    log_info "已更新动态带宽: 上行 ${tuned_u}Mbps / 下行 ${tuned_d}Mbps"
}

# 查看运行日志 (区分 Systemd 与 Docker)
view_logs() {
    if is_docker_mode; then
        log_info "正在查看 Hysteria 2 Docker 容器日志 (按 Ctrl+C 退出)..."
        docker logs -f --tail 50 hysteria-server
    else
        log_info "正在查看 Hysteria 2 Systemd 实时日志 (按 Ctrl+C 退出)..."
        journalctl -u hysteria-server.service -n 50 -f
    fi
}

# 重启服务
restart_service() {
    log_info "正在重启 Hysteria 2 服务..."
    if is_docker_mode; then
        if docker compose version &>/dev/null; then
            docker compose -f /etc/hysteria/docker-compose.yml restart
        else
            docker-compose -f /etc/hysteria/docker-compose.yml restart
        fi
        log_success "Hysteria 2 Docker 容器已重启成功！"
    else
        systemctl restart hysteria-server.service
        if systemctl is-active --quiet hysteria-server.service; then
            log_success "Hysteria 2 Systemd 服务已重启成功！"
        else
            log_err "服务重启后未成功运行，请检查日志。"
        fi
    fi
}

# 停止服务
stop_service() {
    log_info "正在停止 Hysteria 2 服务..."
    if is_docker_mode; then
        if docker compose version &>/dev/null; then
            docker compose -f /etc/hysteria/docker-compose.yml stop
        else
            docker-compose -f /etc/hysteria/docker-compose.yml stop
        fi
        log_success "Hysteria 2 Docker 容器已停止。"
    else
        systemctl stop hysteria-server.service
        log_success "Hysteria 2 Systemd 服务已停止。"
    fi
}

# 卸载 Hysteria 2
uninstall_hysteria2() {
    check_root
    read -rp "确定要卸载 Hysteria 2 并清除相关配置文件与容器吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在停止并清理服务..."
        if is_docker_mode; then
            if docker compose version &>/dev/null; then
                docker compose -f /etc/hysteria/docker-compose.yml down &>/dev/null
            else
                docker-compose -f /etc/hysteria/docker-compose.yml down &>/dev/null
            fi
            docker rm -f hysteria-server &>/dev/null
        fi

        systemctl stop hysteria-server.service &>/dev/null
        systemctl disable hysteria-server.service &>/dev/null
        
        log_info "清除配置文件及证书..."
        rm -rf /etc/hysteria
        rm -f /etc/sysctl.d/99-hysteria.conf
        rm -f /etc/cron.d/hysteria-maintenance
        rm -f /usr/local/bin/hy2
        
        log_info "卸载二进制程序..."
        rm -f /usr/local/bin/hysteria
        rm -f /etc/systemd/system/hysteria-server.service
        systemctl daemon-reload
        
        log_success "Hysteria 2 已彻底卸载完成。"
    else
        log_info "已取消卸载操作。"
    fi
}

# 查看当前节点配置与分享链接
show_node_info() {
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        log_err "未找到配置文件 /etc/hysteria/config.yaml，请先安装！"
        return
    fi

    local pass port_spec sni obfs_p
    pass=$(extract_config_auth_password)
    port_spec=$(extract_config_listen_port)
    sni=$(extract_config_sni)
    obfs_p=$(extract_config_obfs_password)
    local server_ip
    server_ip=$(get_public_ip)
    local is_acme=0
    if grep -q "acme:" /etc/hysteria/config.yaml; then is_acme=1; fi
    local insecure_val="1"
    if [ "$is_acme" -eq 1 ]; then insecure_val="0"; fi

    local obfs_q=""
    if [[ -n "$obfs_p" ]]; then
        obfs_q="&obfs=salamander&obfs-password=${obfs_p}"
    fi

    local share_link="hy2://${pass}@${server_ip}:${port_spec}?insecure=${insecure_val}&sni=${sni}${obfs_q}#Hysteria2_${server_ip}"
    
    echo -e "\n${GREEN}================ 当前节点配置信息 ================${NC}"
    echo -e "${CYAN}运行模式       :${NC} $(is_docker_mode && echo "Docker Compose 容器" || echo "Systemd")"
    echo -e "${CYAN}服务器 IP      :${NC} ${server_ip}"
    echo -e "${CYAN}监听端口 / 范围:${NC} UDP ${port_spec}"
    echo -e "${CYAN}认证密码       :${NC} ${pass}"
    echo -e "${CYAN}Salamander 混淆:${NC} $([ -n "$obfs_p" ] && echo "已开启 (密钥: ${obfs_p})" || echo "未启用")"
    echo -e "${CYAN}SNI 域名       :${NC} ${sni}"
    echo -e "${CYAN}节点链接       :${NC} ${share_link}"
    echo -e "${GREEN}==================================================${NC}\n"
}

# 主菜单 (标准化控制台，循环交互)
show_menu() {
    while true; do
        clear
        local service_stat
        service_stat=$(get_service_status)
        local current_ver
        current_ver=$(get_hysteria_version)

        local listen_info="无"
        local obfs_info="未启用"
        if [[ -f /etc/hysteria/config.yaml ]]; then
            listen_info=$(grep 'listen:' /etc/hysteria/config.yaml | head -n1 | awk '{print $2}')
            if grep -q "salamander" /etc/hysteria/config.yaml 2>/dev/null; then
                obfs_info="Salamander 混淆"
            fi
        fi

        echo -e "${CYAN}================================================================${NC}"
        echo -e "${CYAN}             Hysteria 2 自动化管理面板 (v2.5)                   ${NC}"
        echo -e "${CYAN}  官方项目: https://github.com/apernet/hysteria                 ${NC}"
        echo -e "${CYAN}  开源脚本: https://github.com/Ericsunsk/hysteria2-script       ${NC}"
        echo -e "${CYAN}================================================================${NC}"
        echo -e "  服务状态 (Status)  : ${service_stat}"
        echo -e "  内核版本 (Version) : ${GREEN}${current_ver}${NC}"
        echo -e "  监听配置 (Listen)  : ${PURPLE}${listen_info}${NC}"
        echo -e "  报文混淆 (Obfs)    : ${YELLOW}${obfs_info}${NC}"
        echo -e "${CYAN}================================================================${NC}"
        echo -e "  ${GREEN}1.${NC} 安装 / 重新配置服务      (Systemd / Docker Compose)"
        echo -e "  ${GREEN}2.${NC} 测速与网络优化         (Speedtest & Network Tuning)"
        echo -e "  ${GREEN}3.${NC} 流量统计面板           (Traffic Statistics)"
        echo -e "  ${GREEN}4.${NC} 检查与升级内核         (Update Hysteria Core / Docker Image)"
        echo -e "  ${GREEN}5.${NC} 配置 Cron 定时运维     (Cron Auto Maintenance)"
        echo -e "  ${GREEN}6.${NC} 查看服务日志           (Service Logs)"
        echo -e "  ${GREEN}7.${NC} 重启服务               (Restart Service)"
        echo -e "  ${GREEN}8.${NC} 停止服务               (Stop Service)"
        echo -e "  ${GREEN}9.${NC} 查看节点与配置         (View Config & Links)"
        echo -e " ${GREEN}10.${NC} 卸载服务              (Uninstall Service)"
        echo -e " ${GREEN}00.${NC} 升级管理脚本           (Update hy2 Script)"
        echo -e "  ${GREEN}0.${NC} 退出                   (Exit Console)"
        echo -e "${CYAN}================================================================${NC}"
        read -rp "请输入选项 [0-10, 00]: " choice

        case "$choice" in
            1) install_hysteria2 ;;
            2) tune_existing_config ;;
            3) query_traffic_stats ;;
            4) update_hysteria_binary ;;
            5) setup_cron_maintenance ;;
            6) view_logs ;;
            7) restart_service ;;
            8) stop_service ;;
            9) show_node_info ;;
            10) uninstall_hysteria2 ;;
            00) update_script ;;
            0) exit 0 ;;
            *) log_err "无效选项，请重新输入！" ;;
        esac

        echo ""
        read -rp "按 Enter 键返回主菜单..." _
    done
}

# 入口
shortcut_register

if [[ "$1" == "install" ]]; then
    install_hysteria2
elif [[ "$1" == "tune" ]]; then
    tune_existing_config
elif [[ "$1" == "stats" || "$1" == "traffic" ]]; then
    query_traffic_stats
elif [[ "$1" == "cron" ]]; then
    setup_cron_maintenance
elif [[ "$1" == "update" ]]; then
    update_hysteria_binary
elif [[ "$1" == "00" || "$1" == "update-script" || "$1" == "upgrade" || "$1" == "self-update" ]]; then
    update_script
elif [[ "$1" == "uninstall" ]]; then
    uninstall_hysteria2
elif [[ "$1" == "restart" ]]; then
    restart_service
elif [[ "$1" == "stop" ]]; then
    stop_service
elif [[ "$1" == "status" || "$1" == "log" || "$1" == "logs" ]]; then
    view_logs
elif [[ "$1" == "info" || "$1" == "node" ]]; then
    show_node_info
else
    show_menu
fi
