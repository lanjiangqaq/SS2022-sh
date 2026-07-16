#!/bin/bash
# ==========================================================
# Xray-core (SS2022) 自动化管理与维护脚本
# 协议标准：2022-blake3-aes-256-gcm
# 适用仓库：https://github.com/lanjiangqaq/ss2022
# ==========================================================

set -e

# 1. 权限校验
if [ "$EUID" -ne 0 ]; then
    echo "错误：此脚本必须以 root 权限运行。"
    exit 1
fi

CONFIG_PATH="/usr/local/etc/xray/config.json"
CIPHER="2022-blake3-aes-256-gcm"

# 2. 核心安装与升级函数
install_xray() {
    echo "正在准备系统环境并安装依赖 (curl, wget, unzip, jq, openssl)..."
    if [ -f /etc/debian_version ]; then
        apt-get update -y -qq && apt-get install -y -qq curl wget unzip jq openssl
    elif [ -f /etc/redhat-release ]; then
        yum install -y -q epel-release || true
        yum install -y -q curl wget unzip jq openssl
    else
        echo "警告：非标准 Debian/CentOS 系统，请确保基础依赖已手动安装。"
    fi

    REUSE_CONF=false

    # 检查现有配置以执行热更新
    if [ -f "$CONFIG_PATH" ]; then
        echo "检测到现有配置，准备执行升级流程并保留旧参数..."
        OLD_PORT=$(jq -r '.inbounds[0].port' "$CONFIG_PATH" 2>/dev/null || grep -oP '"port":\s*\K[0-9]+' "$CONFIG_PATH" | head -n1 || true)
        OLD_KEY=$(jq -r '.inbounds[0].settings.password' "$CONFIG_PATH" 2>/dev/null || grep -oP '"password":\s*"\K[^"]+' "$CONFIG_PATH" | head -n1 || true)
        
        if [ -n "$OLD_PORT" ] && [ -n "$OLD_KEY" ] && [ "$OLD_PORT" != "null" ] && [ "$OLD_KEY" != "null" ]; then
            PORT=$OLD_PORT
            KEY=$OLD_KEY
            REUSE_CONF=true
            echo "参数继承成功：将继续使用端口 [$PORT]。"
        else
            echo "解析旧配置失败，执行全新部署。"
        fi
    fi

    # 全新配置录入
    if [ "$REUSE_CONF" = false ]; then
        read -p "请输入自定义端口 [1-65535] (默认 8388): " INPUT_PORT
        PORT=${INPUT_PORT:-8388}
        
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            echo "端口输入错误或越界，已强制重置为默认端口 8388。"
            PORT=8388
        fi
        
        echo "正在生成符合 SS2022 规范的 32 字节 Base64 强加密密钥..."
        KEY=$(openssl rand -base64 32)
    fi

    # 架构检测
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64" ;;
        aarch64) XRAY_ARCH="arm64-v8a" ;;
        *) echo "错误：暂不支持的系统架构 $ARCH" ; exit 1 ;;
    esac

    # 获取最新内核版本
    echo "正在获取 Xray-core 最新版本号..."
    TAG=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
    if [ -z "$TAG" ] || [ "$TAG" == "null" ]; then
        TAG=$(wget -qO- https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    if [ -z "$TAG" ]; then
        echo "错误：无法获取最新版本号，请检查网络连接。"
        exit 1
    fi

    echo "目标版本: $TAG，正在下载内核并进行解压部署..."
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${TAG}/Xray-linux-${XRAY_ARCH}.zip"
    wget -qO /tmp/xray.zip "$XRAY_URL"

    mkdir -p /usr/local/bin
    rm -f /usr/local/bin/xray
    unzip -qo /tmp/xray.zip xray -d /usr/local/bin/
    chmod +x /usr/local/bin/xray
    rm -f /tmp/xray.zip

    # 更新地理数据路由库
    echo "正在同步最新 GeoIP 与 GeoSite 数据库..."
    mkdir -p /usr/local/share/xray
    wget -qO /usr/local/share/xray/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat || true
    wget -qO /usr/local/share/xray/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat || true

    # 构建配置文件
    echo "正在构建内核配置文件..."
    mkdir -p /usr/local/etc/xray
    cat > "$CONFIG_PATH" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "$CIPHER",
        "password": "$KEY",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

    # 配置守护服务
    echo "正在配置 Systemd 守护服务..."
    cat > /etc/systemd/system/xray-ss.service <<EOF
[Unit]
Description=Xray SS2022 Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config $CONFIG_PATH
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-ss --now
    systemctl restart xray-ss

    # 生成标准订阅链接
    echo "正在获取公网地址并生成配置链接..."
    IP=$(curl -sL ipv4.icanhazip.com || curl -sL api.ipify.org || echo "YOUR_IP_ADDRESS")
    REMARK="SS2022-${IP}-${PORT}"
    RAW_STR="${CIPHER}:${KEY}"
    B64_STR=$(echo -n "$RAW_STR" | base64 | tr -d '\n' | tr -d '\r')
    SS_LINK="ss://${B64_STR}@${IP}:${PORT}#${REMARK}"

    echo ""
    echo "=========================================================="
    if [ "$REUSE_CONF" = true ]; then
        echo " Xray-core SS2022 热更新与升级已完成"
    else
        echo " Xray-core SS2022 全新部署已完成"
    fi
    echo "=========================================================="
    echo " 核心版本 : $TAG"
    echo " 节点 IP  : $IP"
    echo " 运行端口 : $PORT"
    echo " 加密协议 : $CIPHER"
    echo " 节点密码 : $KEY"
    echo "=========================================================="
    echo " V2Ray / Xray 客户端订阅链接 (请复制以下整行)："
    echo ""
    echo "$SS_LINK"
    echo ""
    echo "=========================================================="
}

# 3. 一键卸载函数
uninstall_xray() {
    echo "=========================================================="
    echo "警告：该操作将完全停用并删除 Xray SS2022 相关服务及所有配置！"
    echo "=========================================================="
    read -p "确认卸载？[y/N]: " CONFIRM
    CONFIRM=${CONFIRM:-n}
    
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        echo "正在终止并禁用守护服务..."
        systemctl stop xray-ss 2>/dev/null || true
        systemctl disable xray-ss 2>/dev/null || true
        
        echo "正在清理系统服务文件、程序二进制与全部配置数据..."
        rm -f /etc/systemd/system/xray-ss.service
        rm -f /usr/local/bin/xray
        rm -rf /usr/local/etc/xray
        rm -rf /usr/local/share/xray
        
        systemctl daemon-reload
        echo "Xray SS2022 服务卸载完成，系统环境已恢复。"
    else
        echo "卸载操作已取消。"
    fi
}

# 4. 主页/菜单导航
show_menu() {
    clear
    echo "=========================================================="
    echo "        Xray-core (SS2022) 自动化控制中心"
    echo "        适用仓库: lanjiangqaq/ss2022"
    echo "=========================================================="
    echo "  1. 安装 / 升级 Xray-core SS2022 节点"
    echo "  2. 一键完全卸载 Xray-core SS2022 服务"
    echo "  0. 退出管理面板"
    echo "=========================================================="
    read -p "请选择操作 [0-2]: " CHOICE
    CHOICE=${CHOICE:-0}

    case "$CHOICE" in
        1)
            install_xray
            ;;
        2)
            uninstall_xray
            ;;
        0)
            echo "已退出管理面板。"
            exit 0
            ;;
        *)
            echo "错误：无效输入，请选择正确的操作序号。"
            sleep 2
            show_menu
            ;;
    esac
}

# 运行主页
show_menu
