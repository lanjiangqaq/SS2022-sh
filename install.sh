#!/bin/bash
# ==========================================================
# Xray-core (SS2022) 自动化部署与升级脚本
# 协议标准：2022-blake3-aes-256-gcm
# 功能说明：全新安装、无缝升级内核、生成 V2Ray 兼容节点链接
# ==========================================================

set -e

# 1. 权限校验
if [ "$EUID" -ne 0 ]; then
    echo "错误：此脚本必须以 root 权限运行。"
    exit 1
fi

# 2. 系统环境初始化
echo "正在安装基础依赖 (curl, wget, unzip, jq, openssl)..."
if [ -f /etc/debian_version ]; then
    apt-get update -y -qq && apt-get install -y -qq curl wget unzip jq openssl
elif [ -f /etc/redhat-release ]; then
    yum install -y -q epel-release || true
    yum install -y -q curl wget unzip jq openssl
else
    echo "警告：非标准 Debian/CentOS 系统，请确保基础依赖已手动安装。"
fi

CONFIG_PATH="/usr/local/etc/xray/config.json"
REUSE_CONF=false
CIPHER="2022-blake3-aes-256-gcm"

# 3. 配置热更新与参数继承逻辑
if [ -f "$CONFIG_PATH" ]; then
    echo "检测到现有配置，准备执行升级流程并保留旧参数..."
    # 提取旧配置中的端口和密码
    OLD_PORT=$(jq -r '.inbounds[0].port' "$CONFIG_PATH" 2>/dev/null || grep -oP '"port":\s*\K[0-9]+' "$CONFIG_PATH" | head -n1 || true)
    OLD_KEY=$(jq -r '.inbounds[0].settings.password' "$CONFIG_PATH" 2>/dev/null || grep -oP '"password":\s*"\K[^"]+' "$CONFIG_PATH" | head -n1 || true)
    
    if [ -n "$OLD_PORT" ] && [ -n "$OLD_KEY" ] && [ "$OLD_PORT" != "null" ] && [ "$OLD_KEY" != "null" ]; then
        PORT=$OLD_PORT
        KEY=$OLD_KEY
        REUSE_CONF=true
        echo "参数继承成功：保留当前运行端口与密钥设置。"
    else
        echo "无法解析旧配置，将执行全新部署。"
    fi
fi

# 4. 全新安装参数录入
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

# 5. 架构检测与内核获取
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) XRAY_ARCH="64" ;;
    aarch64) XRAY_ARCH="arm64-v8a" ;;
    *) echo "错误：暂不支持的系统架构 $ARCH" ; exit 1 ;;
esac

echo "正在通过 GitHub API 请求 Xray-core 最新版本号..."
TAG=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
if [ -z "$TAG" ] || [ "$TAG" == "null" ]; then
    TAG=$(wget -qO- https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
fi
if [ -z "$TAG" ]; then
    echo "错误：无法获取最新版本号，请检查服务器网络连接。"
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

# 6. 更新路由规则库 (GeoIP/GeoSite)
echo "正在同步最新 GeoIP 与 GeoSite 数据库..."
mkdir -p /usr/local/share/xray
wget -qO /usr/local/share/xray/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat || true
wget -qO /usr/local/share/xray/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat || true

# 7. 写入服务配置文件
echo "正在构建/覆写内核配置文件..."
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

# 8. 系统守护服务注册
echo "正在配置 Systemd 服务..."
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

# 9. 节点订阅链接生成
echo "正在获取公网地址并生成配置链接..."
IP=$(curl -sL ipv4.icanhazip.com || curl -sL api.ipify.org || echo "YOUR_IP_ADDRESS")
REMARK="SS2022-${IP}-${PORT}"
RAW_STR="${CIPHER}:${KEY}"
# 兼容不同系统 Base64 工具的换行符问题
B64_STR=$(echo -n "$RAW_STR" | base64 | tr -d '\n' | tr -d '\r')
SS_LINK="ss://${B64_STR}@${IP}:${PORT}#${REMARK}"

# 10. 部署结果输出
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
echo " 运维状态检查命令: systemctl status xray-ss"
echo " 运维日志查看命令: journalctl -u xray-ss -f"
echo " 注意说明: 每次重新执行本脚本，系统均会自动拉取最新版内核并继承上述配置。"
