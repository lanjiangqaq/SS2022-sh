#!/bin/bash
# Shadowsocks Rust SS2022 Installation Script
# Modified Version with Time Synchronization

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# Root权限检查
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本必须以root用户身份运行!${PLAIN}" 1>&2
        exit 1
    fi
}

# 安装依赖包 (新增 chrony 和 tzdata)
install_dependencies() {
    echo -e "${CYAN}安装必要的依赖包...${PLAIN}"
    
    if command -v apt-get &>/dev/null; then
        apt-get update -q
        apt-get install -y -q gzip wget curl unzip xz-utils jq openssl chrony tzdata
    elif command -v dnf &>/dev/null; then
        dnf -q update -y
        dnf -q install -y gzip wget curl unzip xz jq openssl chrony tzdata
    elif command -v yum &>/dev/null; then
        yum -q update -y
        yum -q install -y epel-release
        yum -q install -y gzip wget curl unzip xz jq openssl chrony tzdata
    else
        echo -e "${RED}不支持的Linux发行版，请手动安装依赖！${PLAIN}"
        exit 1
    fi
    
    echo -e "${GREEN}依赖包安装完成${PLAIN}"
}

# 同步系统时间 (新增函数)
sync_system_time() {
    echo -e "${CYAN}正在配置系统时区并强制同步时间...${PLAIN}"
    
    # 设置时区为亚洲/上海
    timedatectl set-timezone Asia/Shanghai 2>/dev/null
    
    # 启动 chrony 服务 (兼容不同发行版的进程命名)
    if systemctl list-unit-files | grep -qw chronyd.service; then
        systemctl enable chronyd --now >/dev/null 2>&1
    else
        systemctl enable chrony --now >/dev/null 2>&1
    fi
    
    # 强制步进同步时间以消除误差
    if command -v chronyc &>/dev/null; then
        chronyc makestep >/dev/null 2>&1
        echo -e "${GREEN}系统时间同步完成。当前服务器时间: $(date)${PLAIN}"
    else
        echo -e "${YELLOW}警告: 无法执行 chronyc 命令，时间同步可能未完全生效。${PLAIN}"
    fi
}

# 生成随机密码和端口
generate_credentials() {
    echo -e "${CYAN}正在生成 SS2022 标准 32 字节 Base64 密钥...${PLAIN}"
    SS_PASSWORD=$(openssl rand -base64 32)
    echo -e "${GREEN}密钥生成成功: ${SS_PASSWORD}${PLAIN}"

    echo -e "${YELLOW}请输入端口号 [1-65535]${PLAIN}"
    echo -e "${YELLOW}默认: 随机端口 (15秒后自动选择随机端口)${PLAIN}"
    read -t 15 -p "> " SS_PORT
    if [[ -z "$SS_PORT" ]]; then
        SS_PORT=$(shuf -i 10000-65000 -n 1)
    elif ! [[ "$SS_PORT" =~ ^[0-9]+$ ]] || [[ "$SS_PORT" -lt 1 ]] || [[ "$SS_PORT" -gt 65535 ]]; then
        echo -e "${YELLOW}输入的端口无效，使用随机端口${PLAIN}"
        SS_PORT=$(shuf -i 10000-65000 -n 1)
    fi
}

# 获取服务器IP地址
get_server_ip() {
    echo -e "${CYAN}正在获取服务器IP地址...${PLAIN}"
    
    IP=""
    
    if [[ -z "$IP" ]]; then
        IP=$(curl -s -4 --max-time 10 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}' | tr -d '\n')
    fi
    
    if [[ -z "$IP" ]]; then
        IP=$(curl -s -6 --max-time 10 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}' | tr -d '\n')
    fi
    
    if [[ -z "$IP" ]]; then
        IP=$(curl -s -4 --max-time 10 https://api.ipify.org || curl -s -4 --max-time 10 https://ipinfo.io/ip)
    fi

    if [[ -z "$IP" ]]; then
        echo -e "${RED}无法获取服务器IP地址，请手动检查网络连接${PLAIN}"
        IP="<未知IP地址>"
    fi
}

# 确定系统架构
detect_architecture() {
    echo -e "${CYAN}检测系统架构...${PLAIN}"
    
    ARCH=""
    UNAME=$(uname -m)
    
    case "$UNAME" in
        i386|i686)
            ARCH="i686"
            ;;
        x86_64|amd64)
            ARCH="x86_64"
            ;;
        armv7l|armv7)
            ARCH="arm"
            ;;
        armv8|aarch64)
            ARCH="aarch64"
            ;;
        *)
            echo -e "${RED}不支持的架构: $UNAME${PLAIN}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}系统架构: $ARCH${PLAIN}"
}

# 下载并安装Shadowsocks Rust
install_shadowsocks() {
    echo -e "${CYAN}下载Shadowsocks Rust...${PLAIN}"
    
    LATEST_VERSION=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | 
                    jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    
    if [[ -z "$LATEST_VERSION" ]]; then
        echo -e "${RED}无法获取最新版本信息，请检查网络连接或者GitHub API限制${PLAIN}"
        exit 1
    fi
    
    echo -e "${GREEN}最新版本: $LATEST_VERSION${PLAIN}"
    
    DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VERSION}/shadowsocks-${LATEST_VERSION}.${ARCH}-unknown-linux-gnu.tar.xz"
    echo -e "${CYAN}正在从 $DOWNLOAD_URL 下载...${PLAIN}"
    
    wget --no-check-certificate -q --show-progress -N "$DOWNLOAD_URL"
    
    if [[ $? -ne 0 || ! -e "shadowsocks-${LATEST_VERSION}.${ARCH}-unknown-linux-gnu.tar.xz" ]]; then
        echo -e "${RED}下载失败！尝试备用方法...${PLAIN}"
        curl -L --progress-bar -o "shadowsocks-${LATEST_VERSION}.${ARCH}-unknown-linux-gnu.tar.xz" "$DOWNLOAD_URL"
        
        if [[ $? -ne 0 || ! -e "shadowsocks-${LATEST_VERSION}.${ARCH}-unknown-linux-gnu.tar.xz" ]]; then
            echo -e "${RED}Shadowsocks Rust 下载失败！请检查网络连接或手动下载${PLAIN}"
            exit 1
        fi
    fi
    
    echo -e "${CYAN}解压文件...${PLAIN}"
    tar -xf "shadowsocks-${LATEST_VERSION}.${ARCH}-unknown-linux-gnu.tar.xz"
    
    if [[ ! -e "ssserver" ]]; then
        echo -e "${RED}解压失败！${PLAIN}"
        exit 1
    fi
    
    chmod +x ssserver
    mv -f ssserver /usr/local/bin/
    
    rm -f "shadowsocks-${LATEST_VERSION}.${ARCH}-unknown-linux-gnu.tar.xz"
    rm -f sslocal ssmanager ssservice ssurl 2>/dev/null
    
    echo -e "${GREEN}Shadowsocks Rust 安装完成！${PLAIN}"
}

# 配置Shadowsocks
configure_shadowsocks() {
    echo -e "${CYAN}配置Shadowsocks...${PLAIN}"
    
    mkdir -p /etc/shadowsocks
    
    cat > /etc/shadowsocks/config.json << EOF
{
    "server":"::",
    "server_port":$SS_PORT,
    "password":"$SS_PASSWORD",
    "timeout":600,
    "mode":"tcp_and_udp",
    "method":"2022-blake3-aes-256-gcm"
}
EOF
    
    cat > /etc/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Rust Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable shadowsocks.service
    systemctl restart shadowsocks.service
    
    rm -f tcp-wss.sh ss-rust.sh 2>/dev/null
    
    echo -e "${GREEN}Shadowsocks 配置完成！${PLAIN}"
}

# 生成客户端配置 (严格遵循 SIP002 规范)
generate_client_info() {
    echo -e "${CYAN}生成客户端配置信息...${PLAIN}"
    
    USER_INFO=$(echo -n "2022-blake3-aes-256-gcm:${SS_PASSWORD}" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    
    SS_STATUS=$(systemctl is-active shadowsocks.service)
    if [[ "$SS_STATUS" == "active" ]]; then
        SERVICE_STATUS="${GREEN}运行中${PLAIN}"
    else
        SERVICE_STATUS="${RED}未运行${PLAIN}"
    fi
    
    clear
    echo -e "==========================================="
    echo -e "       ${GREEN}Shadowsocks 安装已经完成${PLAIN}"
    echo -e "==========================================="
    echo -e ""
    echo -e "${CYAN}Shadowsocks 2022 配置参数:${PLAIN}"
    echo -e "-------------------------------------------"
    echo -e "${YELLOW}服务器地址:${PLAIN} ${IP}"
    echo -e "${YELLOW}端口:${PLAIN} ${SS_PORT}"
    echo -e "${YELLOW}密码:${PLAIN} ${SS_PASSWORD}"
    echo -e "${YELLOW}加密方式:${PLAIN} 2022-blake3-aes-256-gcm"
    echo -e "${YELLOW}传输协议:${PLAIN} tcp+udp"
    echo -e "-------------------------------------------"
    echo -e "${YELLOW}服务状态:${PLAIN} ${SERVICE_STATUS}"
    echo -e ""
    echo -e "${YELLOW}SS URL:${PLAIN}"
    echo -e ""
    echo -e "ss://${USER_INFO}@${IP}:${SS_PORT}"
    echo -e ""
    echo -e "${GREEN}可使用此URL在客户端快速导入配置${PLAIN}"
    echo -e "==========================================="
}

# 主函数
main() {
    check_root
    install_dependencies
    sync_system_time
    generate_credentials
    detect_architecture
    install_shadowsocks
    configure_shadowsocks
    get_server_ip
    generate_client_info
}

# 执行主函数
main
