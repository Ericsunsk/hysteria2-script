#!/usr/bin/env bash
# ==============================================================================
# Hysteria 2 官方标准深度调优与一键自动化管理脚本 (hy2)
# GitHub 官方仓库: https://github.com/apernet/hysteria
# 本项目地址: https://github.com/Ericsunsk/hysteria2-script
# 参照官方最新文档配置 (内置 ACME 证书 / 原生端口跳跃 / 全动态 QUIC / 流量统计 API)
# Supported OS: Debian / Ubuntu / CentOS / AlmaLinux / RockyLinux / Arch
# ==============================================================================

export LANG=C.UTF-8

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
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

# 获取服务运行状态
get_service_status() {
    if ! command -v hysteria &>/dev/null; then
        echo -e "${YELLOW}未安装 (Not Installed)${NC}"
    elif systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
        echo -e "${GREEN}运行中 (Running)${NC}"
    else
        echo -e "${RED}已停止 (Stopped)${NC}"
    fi
}

# 获取当前已安装的 Hysteria 2 内核版本
get_hysteria_version() {
    if command -v hysteria &>/dev/null; then
        hysteria version 2>/dev/null | head -n1 | awk '{print $3}' || echo "已安装"
    else
        echo "无"
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

# 随机端口生成器 (10000 - 60000)
gen_random_port() {
    echo $((10000 + RANDOM % 40000))
}

# 安装基础依赖
install_dependencies() {
    log_info "正在检查并安装基础依赖 (curl, openssl, tar, iptables, nftables, python3, jq)..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y curl openssl tar ufw iptables nftables python3 jq speedtest-cli
    elif command -v yum &>/dev/null; then
        yum install -y curl openssl tar firewalld iptables nftables python3 jq speedtest-cli
    elif command -v dnf &>/dev/null; then
        dnf install -y curl openssl tar firewalld iptables nftables python3 jq speedtest-cli
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm curl openssl tar iptables nftables python3 jq
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

# 检查更新 Hysteria 2 内核
update_hysteria_binary() {
    check_root
    log_info "正在从 GitHub 官方 Release (apernet/hysteria) 更新 Hysteria 2 内核..."
    bash <(curl -fsSL https://get.hy2.sh/)
    if [[ $? -eq 0 ]]; then
        log_success "Hysteria 2 内核已更新至最新版本！"
        systemctl restart hysteria-server.service &>/dev/null
    else
        log_err "更新失败，请检查网络连接。"
    fi
}

# 查询流量统计数据 (使用官方 Traffic Stats API)
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

    if [[ -n "$stats_json" ]]; then
        echo -e "\n${GREEN}================ 📊 流量统计看板 (Traffic Statistics) ================${NC}"
        if command -v jq &>/dev/null; then
            echo "$stats_json" | jq -r 'to_entries[] | "客户端标识/密码: " + .key + "\n  ⬆️ 发送流量 (Tx): " + (.value.tx | tostring) + " Bytes\n  ⬇️ 接收流量 (Rx): " + (.value.rx | tostring) + " Bytes\n"'
        else
            echo "$stats_json"
        fi
        echo -e "${GREEN}========================================================================${NC}\n"
    else
        log_warn "暂无活动流量数据，或服务未成功启动。API Endpoint: http://127.0.0.1:9090/traffic"
    fi
}

# 主安装逻辑
install_hysteria2() {
    check_root
    install_dependencies
    shortcut_register

    echo -e "\n${PURPLE}====================================================${NC}"
    echo -e "${PURPLE}     Hysteria 2 服务端配置与自动化部署              ${NC}"
    echo -e "${PURPLE}====================================================${NC}\n"

    # 自动优化系统内核网络参数
    optimize_kernel_network

    # 1. 证书模式选择 (自签证书 vs 内置 ACME 官方申请)
    echo -e "${CYAN}请选择 TLS 证书模式 (TLS Certificate Mode):${NC}"
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

    # 2. 端口模式选择 (单端口 vs 官方原生端口跳跃 Port Hopping)
    local default_p
    default_p=$(gen_random_port)
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
        local hop_end=$((hop_start + 10000))
        read -rp "请输入端口跳跃范围 [默认随机: ${hop_start}-${hop_end}]: " HOP_RANGE
        HOP_RANGE=${HOP_RANGE:-"${hop_start}-${hop_end}"}
        LISTEN_CONFIG=":${HOP_RANGE}"
        PORT_SHOW="${HOP_RANGE}"
    else
        read -rp "请输入 Hysteria 2 监听端口 [默认随机: ${default_p}]: " PORT_INPUT
        PORT_INPUT=${PORT_INPUT:-$default_p}
        LISTEN_CONFIG=":${PORT_INPUT}"
        PORT_SHOW="${PORT_INPUT}"
    fi

    # 3. 认证密码与 Traffic Stats Secret
    local default_pass
    default_pass=$(gen_random_pass)
    read -rp "请输入认证密码 [默认随机: ${default_pass}]: " PASSWORD
    PASSWORD=${PASSWORD:-$default_pass}

    local stats_secret
    stats_secret=$(gen_random_pass)

    # 4. 伪装网址
    read -rp "请输入 HTTP 伪装网址 [默认: https://bing.com]: " MASQ_URL
    MASQ_URL=${MASQ_URL:-"https://bing.com"}

    # 5. 网络实测
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

    log_info "开始从 GitHub 官方拉取安装 Hysteria 2 内核..."
    bash <(curl -fsSL https://get.hy2.sh/)
    if [[ $? -ne 0 ]]; then
        log_err "Hysteria 2 官方脚本安装失败，请检查网络或 URL 连通性。"
        exit 1
    fi

    # 准备目录
    mkdir -p /etc/hysteria

    # 编写 config.yaml
    log_info "正在生成官方标准 Hysteria 2 配置文件 /etc/hysteria/config.yaml..."

    if [[ "$CERT_MODE" == "2" ]]; then
        # ACME 模式
        cat << EOF > /etc/hysteria/config.yaml
listen: ${LISTEN_CONFIG}

acme:
  domains:
    - ${domain_name}
  email: ${acme_email}

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
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
  secret: ${stats_secret}

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
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
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
  secret: ${stats_secret}

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

    # 给 systemd 赋予网络修改权限 (用于内置端口跳跃 iptables/nftables)
    if [[ -f /etc/systemd/system/hysteria-server.service ]]; then
        if ! grep -q "CAP_NET_ADMIN" /etc/systemd/system/hysteria-server.service 2>/dev/null; then
            sed -i '/\[Service\]/a AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE' /etc/systemd/system/hysteria-server.service 2>/dev/null
        fi
    fi

    log_info "配置开机自启并启动服务..."
    systemctl daemon-reload
    systemctl enable hysteria-server.service
    systemctl restart hysteria-server.service

    # 检查状态
    sleep 2
    if systemctl is-active --quiet hysteria-server.service; then
        log_success "Hysteria 2 高性能深度调优服务已成功运行！"
    else
        log_err "Hysteria 2 服务启动失败，请执行 'systemctl status hysteria-server.service' 或检查日志！"
        exit 1
    fi

    # 生成节点链接与客户端配置
    local server_ip
    server_ip=$(get_public_ip)
    local insecure_param="1"
    if [[ "$CERT_MODE" == "2" ]]; then insecure_param="0"; fi

    local main_host="${server_ip}"
    if [[ "$CERT_MODE" == "2" ]]; then main_host="${domain_name}"; fi

    local share_link="hy2://${PASSWORD}@${main_host}:${PORT_SHOW}?insecure=${insecure_param}&sni=${domain_name}#Hysteria2_${main_host}"

    echo -e "\n${GREEN}====================================================${NC}"
    echo -e "${GREEN}      🎉 Hysteria 2 官方深度调优部署完成！           ${NC}"
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${CYAN}服务器地址 / IP    :${NC} ${main_host}"
    echo -e "${CYAN}监听端口 / 范围    :${NC} UDP ${PORT_SHOW}"
    echo -e "${CYAN}认证密码           :${NC} ${PASSWORD}"
    echo -e "${CYAN}SNI 域名           :${NC} ${domain_name}"
    echo -e "${CYAN}证书验证 (insecure):${NC} ${insecure_param} ($([ "$insecure_param" == "0" ] && echo "正规 ACME 证书安全连接" || echo "自签证书跳过验证"))"
    echo -e "${CYAN}动态带宽限制       :${NC} 上行 ${up_limit} | 下行 ${down_limit}"
    echo -e "${CYAN}流量统计 API       :${NC} http://127.0.0.1:9090/traffic"
    echo -e "${CYAN}内网 ACL 防护      :${NC} 已启用 (自动拒绝内网与私有 IP 扫描)"
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
    sni: ${domain_name}
    skip-cert-verify: $([ "$insecure_param" == "1" ] && echo "true" || echo "false")
EOF
    echo -e "${GREEN}====================================================${NC}\n"
}

# 独立运行网络优化与配置更新
tune_existing_config() {
    check_root
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        log_err "未找到配置文件 /etc/hysteria/config.yaml，请先安装！"
        exit 1
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
    
    if grep -q "bandwidth:" /etc/hysteria/config.yaml; then
        sed -i "/bandwidth:/,/down:/c\bandwidth:\n  up: ${tuned_u} mbps\n  down: ${tuned_d} mbps" /etc/hysteria/config.yaml
    fi

    systemctl restart hysteria-server.service
    log_success "网络跑分优化完成！"
    log_info "已更新动态带宽: 上行 ${tuned_u}Mbps / 下行 ${tuned_d}Mbps"
}

# 查看运行日志
view_logs() {
    log_info "正在查看 Hysteria 2 实时日志 (按 Ctrl+C 退出)..."
    journalctl -u hysteria-server.service -n 50 -f
}

# 重启服务
restart_service() {
    log_info "正在重启 Hysteria 2 服务..."
    systemctl restart hysteria-server.service
    if systemctl is-active --quiet hysteria-server.service; then
        log_success "Hysteria 2 服务已重启成功！"
    else
        log_err "服务重启后未成功运行，请检查日志。"
    fi
}

# 停止服务
stop_service() {
    log_info "正在停止 Hysteria 2 服务..."
    systemctl stop hysteria-server.service
    log_success "Hysteria 2 服务已停止。"
}

# 卸载 Hysteria 2
uninstall_hysteria2() {
    check_root
    read -rp "确定要卸载 Hysteria 2 并清除相关配置文件吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在停止并禁用服务..."
        systemctl stop hysteria-server.service &>/dev/null
        systemctl disable hysteria-server.service &>/dev/null
        
        log_info "清除配置文件及证书..."
        rm -rf /etc/hysteria
        rm -f /etc/sysctl.d/99-hysteria.conf
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

# 主菜单 (标准化控制台)
show_menu() {
    clear
    local service_stat
    service_stat=$(get_service_status)
    local current_ver
    current_ver=$(get_hysteria_version)

    local listen_info="无"
    if [[ -f /etc/hysteria/config.yaml ]]; then
        listen_info=$(grep 'listen:' /etc/hysteria/config.yaml | head -n1 | awk '{print $2}')
    fi

    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}             Hysteria 2 自动化管理面板 (v2.0)                   ${NC}"
    echo -e "${CYAN}  官方项目: https://github.com/apernet/hysteria                 ${NC}"
    echo -e "${CYAN}  开源脚本: https://github.com/Ericsunsk/hysteria2-script       ${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  服务状态 (Status)  : ${service_stat}"
    echo -e "  内核版本 (Version) : ${GREEN}${current_ver}${NC}"
    echo -e "  监听配置 (Listen)  : ${PURPLE}${listen_info}${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 安装 / 重新配置服务 (Install / Reconfigure)"
    echo -e "  ${GREEN}2.${NC} 测速与网络优化     (Speedtest & Network Tuning)"
    echo -e "  ${GREEN}3.${NC} 流量统计面板       (Traffic Statistics)"
    echo -e "  ${GREEN}4.${NC} 检查与升级内核     (Update Hysteria Core)"
    echo -e "  ${GREEN}5.${NC} 查看服务日志       (Service Logs)"
    echo -e "  ${GREEN}6.${NC} 重启服务          (Restart Service)"
    echo -e "  ${GREEN}7.${NC} 停止服务          (Stop Service)"
    echo -e "  ${GREEN}8.${NC} 查看节点与配置     (View Config & Links)"
    echo -e "  ${GREEN}9.${NC} 卸载服务          (Uninstall Service)"
    echo -e "  ${GREEN}0.${NC} 退出              (Exit Console)"
    echo -e "${CYAN}================================================================${NC}"
    read -rp "请输入选项 [0-9]: " choice

    case "$choice" in
        1) install_hysteria2 ;;
        2) tune_existing_config ;;
        3) query_traffic_stats ;;
        4) update_hysteria_binary ;;
        5) view_logs ;;
        6) restart_service ;;
        7) stop_service ;;
        8)
            if [[ -f /etc/hysteria/config.yaml ]]; then
                local pass port_spec sni
                pass=$(grep 'password:' /etc/hysteria/config.yaml | head -n1 | awk '{print $2}')
                port_spec=$(grep 'listen:' /etc/hysteria/config.yaml | head -n1 | awk '{print $2}' | tr -d ':')
                sni=$(grep -m1 'domains:' -A1 /etc/hysteria/config.yaml 2>/dev/null | tail -n1 | awk '{print $2}' || grep -m1 'CN=' /etc/hysteria/server.crt 2>/dev/null | sed 's/.*CN=//' || echo "bing.com")
                local server_ip
                server_ip=$(get_public_ip)
                local is_acme=0
                if grep -q "acme:" /etc/hysteria/config.yaml; then is_acme=1; fi
                local insecure_val="1"
                if [ "$is_acme" -eq 1 ]; then insecure_val="0"; fi

                local share_link="hy2://${pass}@${server_ip}:${port_spec}?insecure=${insecure_val}&sni=${sni}#Hysteria2_${server_ip}"
                
                echo -e "\n${GREEN}================ 当前节点配置信息 ================${NC}"
                echo -e "${CYAN}服务器 IP      :${NC} ${server_ip}"
                echo -e "${CYAN}监听端口 / 范围:${NC} UDP ${port_spec}"
                echo -e "${CYAN}认证密码       :${NC} ${pass}"
                echo -e "${CYAN}SNI 域名       :${NC} ${sni}"
                echo -e "${CYAN}节点链接       :${NC} ${share_link}"
                echo -e "${GREEN}==================================================${NC}\n"
            else
                log_err "未找到配置文件 /etc/hysteria/config.yaml，请先安装！"
            fi
            ;;
        9) uninstall_hysteria2 ;;
        0) exit 0 ;;
        *) log_err "无效选项！"; exit 1 ;;
    esac
}

# 入口
shortcut_register

if [[ "$1" == "install" ]]; then
    install_hysteria2
elif [[ "$1" == "tune" ]]; then
    tune_existing_config
elif [[ "$1" == "stats" || "$1" == "traffic" ]]; then
    query_traffic_stats
elif [[ "$1" == "update" ]]; then
    update_hysteria_binary
elif [[ "$1" == "uninstall" ]]; then
    uninstall_hysteria2
elif [[ "$1" == "restart" ]]; then
    restart_service
elif [[ "$1" == "status" || "$1" == "log" || "$1" == "logs" ]]; then
    view_logs
else
    show_menu
fi
