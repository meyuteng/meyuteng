#!/bin/bash
set -e

# ==================== Hysteria2 + L2TP 一键部署脚本 ====================
# 适用: Hysteria v2.9.x  /  TUN 模式  /  L2TP 流量转发
# 部署: 服务端选1 (海外VPS) / 客户端选2 (本地L2TP机器)
# ======================================================================

DEFAULT_PASSWORD="hysteria-l2tp"
TUN_MTU=1300

# ==================== 检查 root ====================
if [[ $(id -u) -ne 0 ]]; then
    echo "请使用 sudo 运行此脚本"
    exit 1
fi

# ==================== 检查依赖 ====================
check_deps() {
    for dep in curl openssl iptables; do
        if ! command -v $dep &>/dev/null; then
            echo "[*] 安装依赖: $dep..."
            apt-get update -qq && apt-get install -y -qq $dep
        fi
    done
}

# ==================== 安装 Hysteria2 ====================
install_hysteria() {
    if command -v hysteria &>/dev/null; then
        echo "[*] Hysteria 已安装: $(hysteria version 2>&1 | head -3 | tail -1)"
    else
        echo "[*] 正在安装 Hysteria2..."
        bash <(curl -fsSL https://get.hy2.sh/)
    fi
}

# ==================== 保存 iptables ====================
save_iptables() {
    if ! command -v netfilter-persistent &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq iptables-persistent || apt-get install -y -qq netfilter-persistent 2>/dev/null || true
    fi
    command -v netfilter-persistent &>/dev/null && netfilter-persistent save || true
}

# ==================== 服务端部署 ====================
deploy_server() {
    check_deps
    install_hysteria
    mkdir -p /etc/hysteria

    # 生成自签证书
    if [[ ! -f /etc/hysteria/server.crt ]]; then
        openssl req -x509 -newkey rsa:2048 \
            -keyout /etc/hysteria/server.key \
            -out /etc/hysteria/server.crt \
            -days 3650 -nodes \
            -subj "/CN=www.nintendo.com" 2>/dev/null
    fi

    # 检测出口网卡
    OUT_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    echo "[*] 出口网卡: ${OUT_IF}"

    # 写入配置 (v2.9.x TUN 格式)
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
  mtu: ${TUN_MTU}
  address:
    ipv4: 10.10.10.1/30

masquerade:
  type: proxy
  proxy:
    url: https://www.nintendo.com
    rewriteHost: true

quic:
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
EOF

    # 系统转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # 清理所有可能冲突的旧 NAT 规则
    iptables -t nat -D POSTROUTING -s 10.10.10.0/30 -o ${OUT_IF} -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o ${OUT_IF} -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s 10.10.10.0/30 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 10.10.10.0/30 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -s 10.10.10.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 10.10.10.0/24 -j ACCEPT 2>/dev/null || true

    # 添加 NAT — Hysteria TUN 子网出站
    iptables -t nat -A POSTROUTING -s 10.10.10.0/30 -o ${OUT_IF} -j MASQUERADE
    iptables -A FORWARD -s 10.10.10.0/30 -j ACCEPT
    iptables -A FORWARD -d 10.10.10.0/30 -j ACCEPT

    save_iptables

    # systemd 服务
    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/server.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server

    echo "============================================"
    echo "  服务端部署完成"
    echo "  监听: UDP 443"
    echo "  TUN : 10.10.10.1/30"
    echo "  出口: ${OUT_IF}"
    echo "============================================"
}

# ==================== 客户端部署 ====================
deploy_client() {
    check_deps
    install_hysteria

    read -p "请输入海外 VPS 的 IP 地址: " VPS_IP
    if [[ -z "$VPS_IP" ]]; then
        echo "❌ IP 不能为空"
        exit 1
    fi

    # 自动检测 L2TP 子网
    L2TP_SUBNET=""
    # 从 ppp 接口获取实际 IP
    if ip addr show ppp0 &>/dev/null; then
        L2TP_PEER=$(ip addr show ppp0 | grep -oP 'peer \K[\d.]+')
        if [[ -n "$L2TP_PEER" ]]; then
            L2TP_SUBNET="${L2TP_PEER%.*}.0/24"
            echo "[*] 检测到 L2TP: ppp0 peer=${L2TP_PEER} → 子网 ${L2TP_SUBNET}"
        fi
    fi

    # 没检测到则手动输入
    if [[ -z "$L2TP_SUBNET" ]]; then
        read -p "未检测到 L2TP 连接，请输入 L2TP 分配的 IP 子网 (如 172.28.42.0/24): " L2TP_SUBNET
        if [[ -z "$L2TP_SUBNET" ]]; then
            L2TP_SUBNET="172.28.42.0/24"
        fi
    fi

    # 检测物理出口网卡 (用于后续清理脏规则)
    OUT_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    echo "[*] 物理出口: ${OUT_IF}"

    mkdir -p /etc/hysteria

    # 写入配置 (v2.9.x TUN 格式 + DNS + 排除局域网)
    cat > /etc/hysteria/client.yaml <<EOF
server: ${VPS_IP}:443

auth: ${DEFAULT_PASSWORD}

tls:
  insecure: true

tun:
  name: hys-tun
  mtu: ${TUN_MTU}
  address:
    ipv4: 10.10.10.2/30
  route:
    ipv4:
      - 0.0.0.0/0
    ipv4Exclude:
      - 192.168.0.0/16
      - 172.16.0.0/12
      - 10.0.0.0/8


dns:
  servers:
    - 8.8.8.8
    - 1.1.1.1

masquerade:
  type: proxy
  proxy:
    url: https://www.nintendo.com
    rewriteHost: true

quic:
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
EOF

    # 系统转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # ====== 清理脏 iptables 规则 ======
    echo "[*] 清理旧 iptables 规则..."

    # 清理物理网卡上可能抢流量的旧 L2TP-NAT 规则
    iptables -t nat -D POSTROUTING -s ${L2TP_SUBNET} -o ${OUT_IF} -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 172.28.42.0/24 -o ${OUT_IF} -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 172.28.42.0/24 -o eth0 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 172.28.42.0/24 -o enp3s0 -j MASQUERADE 2>/dev/null || true

    # 清理旧的 hys-tun 规则
    iptables -t nat -D POSTROUTING -s ${L2TP_SUBNET} -o hys-tun -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s ${L2TP_SUBNET} -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d ${L2TP_SUBNET} -j ACCEPT 2>/dev/null || true

    # ====== 添加正确规则 — L2TP 流量走 hys-tun ======
    iptables -t nat -A POSTROUTING -s ${L2TP_SUBNET} -o hys-tun -j MASQUERADE
    iptables -A FORWARD -s ${L2TP_SUBNET} -j ACCEPT
    iptables -A FORWARD -d ${L2TP_SUBNET} -j ACCEPT

    # 确认没有被其他规则抢在前面
    echo "[*] POSTROUTING 链 (按顺序):"
    iptables -t nat -L POSTROUTING -n -v --line-numbers | grep -E "hys-tun|${L2TP_SUBNET}" || true

    save_iptables

    # systemd 服务
    cat > /etc/systemd/system/hysteria-client.service <<EOF
[Unit]
Description=Hysteria Client
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria client -c /etc/hysteria/client.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-client

    echo "============================================"
    echo "  客户端部署完成"
    echo "  服务器 : ${VPS_IP}:443"
    echo "  TUN    : 10.10.10.2/30"
    echo "  L2TP子网: ${L2TP_SUBNET} → hys-tun"
    echo "  DNS    : 8.8.8.8, 1.1.1.1"
    echo "============================================"
}

# ==================== 主菜单 ====================
echo "============================================"
echo "   Hysteria2 + L2TP 一键部署脚本"
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
