#!/bin/bash
set -e

# ========== 默认参数 ==========
DEFAULT_PASSWORD="hysteria-l2tp"
DEFAULT_L2TP_SUBNET="172.28.42.0/24"
TUN_MTU=1300

# ========== 检查 root ==========
if [[ $(id -u) -ne 0 ]]; then
    echo "请使用 sudo 运行此脚本"
    exit 1
fi

# ========== 检查依赖 ==========
check_deps() {
    for dep in curl openssl iptables; do
        if ! command -v $dep &>/dev/null; then
            echo "[*] 安装依赖: $dep..."
            apt-get update -qq && apt-get install -y -qq $dep
        fi
    done
}

# ========== 安装 Hysteria ==========
install_hysteria() {
    if command -v hysteria &>/dev/null; then
        echo "[*] Hysteria 已安装: $(hysteria version 2>&1 | head -1)"
    else
        echo "[*] 正在安装 Hysteria..."
        bash <(curl -fsSL https://get.hy2.sh/)
    fi
}

# ========== 服务端部署 ==========
deploy_server() {
    check_deps
    install_hysteria
    mkdir -p /etc/hysteria

    # 生成自签证书
    openssl req -x509 -newkey rsa:2048 \
        -keyout /etc/hysteria/server.key \
        -out /etc/hysteria/server.crt \
        -days 3650 -nodes \
        -subj "/CN=www.nintendo.com" 2>/dev/null

    # 配置文件
    cat > /etc/hysteria/server.yaml <<EOF
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${DEFAULT_PASSWORD}

tun:
  name: hys-tun
  address: 10.10.10.1/24
  mtu: ${TUN_MTU}

masquerade:
  type: proxy
  proxy:
    url: https://www.nintendo.com
    rewriteHost: true
EOF

    # 系统转发
    sysctl -w net.ipv4.ip_forward=1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # 出口网卡
    OUT_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    echo "[*] 出口网卡: ${OUT_IF}"

    # 先清理旧规则，避免重复添加
    iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o ${OUT_IF} -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s 10.10.10.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 10.10.10.0/24 -j ACCEPT 2>/dev/null || true

    # NAT
    iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o ${OUT_IF} -j MASQUERADE
    iptables -A FORWARD -s 10.10.10.0/24 -j ACCEPT
    iptables -A FORWARD -d 10.10.10.0/24 -j ACCEPT

    # 持久化
    if ! command -v netfilter-persistent &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq iptables-persistent || apt-get install -y -qq netfilter-persistent 2>/dev/null || true
    fi
    command -v netfilter-persistent &>/dev/null && netfilter-persistent save || { apt-get install -y -qq iptables-persistent && netfilter-persistent save; } 2>/dev/null || true

    # systemd
    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/server.yaml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server
    echo "✅ 服务端部署完成，监听 UDP 443"
}

# ========== 客户端部署 ==========
deploy_client() {
    check_deps
    install_hysteria
    read -p "请输入海外 VPS 的 IP 地址: " VPS_IP
    if [[ -z "$VPS_IP" ]]; then
        echo "❌ IP 不能为空"
        exit 1
    fi

    mkdir -p /etc/hysteria
    cat > /etc/hysteria/client.yaml <<EOF
server: ${VPS_IP}:443

auth: ${DEFAULT_PASSWORD}

tls:
  insecure: true

tun:
  name: hys-tun
  address: 10.10.10.2/24
  mtu: ${TUN_MTU}
  route: all

masquerade:
  type: proxy
  proxy:
    url: https://www.nintendo.com
    rewriteHost: true
EOF

    sysctl -w net.ipv4.ip_forward=1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # 先清理旧规则，避免重复添加
    iptables -t nat -D POSTROUTING -s ${DEFAULT_L2TP_SUBNET} -o hys-tun -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s ${DEFAULT_L2TP_SUBNET} -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d ${DEFAULT_L2TP_SUBNET} -j ACCEPT 2>/dev/null || true

    # L2TP 流量导入
    iptables -t nat -A POSTROUTING -s ${DEFAULT_L2TP_SUBNET} -o hys-tun -j MASQUERADE
    iptables -A FORWARD -s ${DEFAULT_L2TP_SUBNET} -j ACCEPT
    iptables -A FORWARD -d ${DEFAULT_L2TP_SUBNET} -j ACCEPT

    # 持久化
    if ! command -v netfilter-persistent &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq iptables-persistent || apt-get install -y -qq netfilter-persistent 2>/dev/null || true
    fi
    command -v netfilter-persistent &>/dev/null && netfilter-persistent save || { apt-get install -y -qq iptables-persistent && netfilter-persistent save; } 2>/dev/null || true

    cat > /etc/systemd/system/hysteria-client.service <<EOF
[Unit]
Description=Hysteria Client
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria client -c /etc/hysteria/client.yaml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-client

    echo "✅ 客户端部署完成"
    echo "============================================"
    echo " 请手动优化 L2TP（在 ppp 选项中添加）："
    echo "   mtu 1200"
    echo "   mru 1200"
    echo "   mppe no"
    echo "   noccp"
    echo "============================================"
}

# ========== 主菜单 ==========
echo "============================================"
echo "       Hysteria + L2TP 一键部署脚本"
echo "============================================"
echo " 请选择部署模式:"
echo "   1) 服务端 (海外 VPS)"
echo "   2) 客户端 (本地运行 L2TP 的机器)"
echo "============================================"
read -p "请输入序号 (1 或 2): " choice

case $choice in
    1) deploy_server ;;
    2) deploy_client ;;
    *) echo "❌ 无效选择，请输入 1 或 2" ; exit 1 ;;
esac