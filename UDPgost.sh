#!/bin/bash
# GOST v3 一键安装脚本 — L2TP/IPsec over QUIC 隧道
# 强制使用 UTF-8 编码
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# 端口配置（可按需修改）
# ============================================================
# 服务端 QUIC 监听端口 — 分别对应 IKE / NAT-T / L2TP
SVR_PORT_500=8443
SVR_PORT_4500=8444
SVR_PORT_1701=8445
# 客户端本地 UDP 监听端口
CLI_PORT_500=500
CLI_PORT_4500=4500
CLI_PORT_1701=1701

echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}    GOST v3 一键安装 — L2TP/IPsec over QUIC     ${NC}"
echo -e "${GREEN}===============================================${NC}"

# ============================================================
# 1. 检查 Root 权限
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：必须使用 root 权限或 sudo 运行此脚本！${NC}"
    exit 1
fi

# ============================================================
# 2. 检查必要工具 (wget / curl)
# ============================================================
if command -v wget &>/dev/null; then
    DL_CMD="wget"
elif command -v curl &>/dev/null; then
    DL_CMD="curl"
else
    echo -e "${RED}错误：未找到 wget 或 curl，请先安装其中之一！${NC}"
    exit 1
fi

# ============================================================
# 3. 检测系统架构
# ============================================================
ARCH=$(uname -m)
echo -e "${YELLOW}正在检测系统架构... 当前架构为: ${ARCH}${NC}"

GOST_VER="3.2.6"
case "$ARCH" in
    x86_64|amd64)
        ARCH_NAME="amd64"
        ;;
    aarch64|arm64|armv8*)
        ARCH_NAME="arm64"
        ;;
    *)
        echo -e "${RED}不支持的系统架构: ${ARCH}！仅支持 x86_64 / arm64。${NC}"
        exit 1
        ;;
esac

URL="https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${ARCH_NAME}.tar.gz"
echo -e "${YELLOW}下载地址: ${URL}${NC}"

# ============================================================
# 4. 下载与安装 Gost
# ============================================================
echo -e "${YELLOW}正在创建配置目录 /etc/gost ...${NC}"
mkdir -p /etc/gost

echo -e "${YELLOW}正在下载 Gost v${GOST_VER} ...${NC}"
if [ "$DL_CMD" = "wget" ]; then
    wget -O /tmp/gost.tar.gz "$URL"
else
    curl -L -o /tmp/gost.tar.gz "$URL"
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败，请检查网络或 GitHub 连通性！${NC}"
    rm -f /tmp/gost.tar.gz
    exit 1
fi

echo -e "${YELLOW}正在解压并安装到 /usr/local/bin/gost ...${NC}"
# 精确提取 gost 二进制，避免目录结构问题
tar -zxf /tmp/gost.tar.gz -C /usr/local/bin gost 2>/dev/null
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}精确解压失败，尝试全量解压...${NC}"
    tar -zxf /tmp/gost.tar.gz -C /tmp
    if [ -f /tmp/gost ]; then
        mv -f /tmp/gost /usr/local/bin/gost
    else
        echo -e "${RED}无法找到 gost 二进制文件，请手动安装。${NC}"
        rm -f /tmp/gost.tar.gz
        exit 1
    fi
fi
chmod +x /usr/local/bin/gost
rm -f /tmp/gost.tar.gz

# 验证安装
echo -e "${YELLOW}验证二进制文件...${NC}"
GOST_VERSION_OUTPUT=$(/usr/local/bin/gost -V 2>&1) || true
if echo "$GOST_VERSION_OUTPUT" | grep -qi "gost\|version"; then
    echo -e "${GREEN}Gost 安装成功！版本信息：${NC}"
    echo -e "${CYAN}${GOST_VERSION_OUTPUT}${NC}"
else
    echo -e "${RED}警告：gost 二进制可能不兼容。输出: ${GOST_VERSION_OUTPUT}${NC}"
    echo -e "${RED}架构: uname -m = ${ARCH}，下载: ${ARCH_NAME}${NC}"
    exit 1
fi

# ============================================================
# 5. 选择角色并生成配置
# ============================================================
echo ""
echo -e "${GREEN}-----------------------------------------------${NC}"
echo -e "${YELLOW}请选择这台服务器的角色：${NC}"
echo -e "  ${CYAN}[1]${NC} 部署在 ${GREEN}美国服务器${NC} (QUIC 接收端 / relay 服务端)"
echo -e "  ${CYAN}[2]${NC} 部署在 ${GREEN}本地/中转服务器${NC} (QUIC 发送端 / UDP 客户端)"
read -p "请输入数字 [1 或 2]: " ROLE

# ============================================================
# 角色 1 — 美国服务端
# ============================================================
if [ "$ROLE" = "1" ]; then
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}  服务端端口规划:${NC}"
    echo -e "${YELLOW}    QUIC :${SVR_PORT_500}  →  UDP 127.0.0.1:500   (IKE)${NC}"
    echo -e "${YELLOW}    QUIC :${SVR_PORT_4500} →  UDP 127.0.0.1:4500  (NAT-T)${NC}"
    echo -e "${YELLOW}    QUIC :${SVR_PORT_1701} →  UDP 127.0.0.1:1701  (L2TP)${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo ""

    cat << EOF > /etc/gost/config.json
{
  "services": [
    {
      "name": "svc-ike",
      "addr": ":${SVR_PORT_500}",
      "handler": {"type": "relay"},
      "listener": {"type": "quic"},
      "forwarder": {
        "nodes": [{"name": "ike-backend", "addr": "127.0.0.1:${CLI_PORT_500}"}]
      }
    },
    {
      "name": "svc-nat-t",
      "addr": ":${SVR_PORT_4500}",
      "handler": {"type": "relay"},
      "listener": {"type": "quic"},
      "forwarder": {
        "nodes": [{"name": "nat-t-backend", "addr": "127.0.0.1:${CLI_PORT_4500}"}]
      }
    },
    {
      "name": "svc-l2tp",
      "addr": ":${SVR_PORT_1701}",
      "handler": {"type": "relay"},
      "listener": {"type": "quic"},
      "forwarder": {
        "nodes": [{"name": "l2tp-backend", "addr": "127.0.0.1:${CLI_PORT_1701}"}]
      }
    }
  ]
}
EOF
    echo -e "${GREEN}服务端配置已生成: /etc/gost/config.json${NC}"
    echo -e "${YELLOW}请确保防火墙已开放 TCP+UDP 端口: ${SVR_PORT_500}, ${SVR_PORT_4500}, ${SVR_PORT_1701}${NC}"

# ============================================================
# 角色 2 — 本地/中转客户端
# ============================================================
elif [ "$ROLE" = "2" ]; then
    read -p "请输入【美国服务器】的公网 IP: " US_IP
    while [ -z "$US_IP" ]; do
        read -p "IP 不能为空，请重新输入: " US_IP
    done

    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}  客户端端口规划:${NC}"
    echo -e "${YELLOW}    UDP :${CLI_PORT_500}  → relay+quic → ${US_IP}:${SVR_PORT_500}   (IKE)${NC}"
    echo -e "${YELLOW}    UDP :${CLI_PORT_4500} → relay+quic → ${US_IP}:${SVR_PORT_4500}  (NAT-T)${NC}"
    echo -e "${YELLOW}    UDP :${CLI_PORT_1701} → relay+quic → ${US_IP}:${SVR_PORT_1701}  (L2TP)${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo ""

    # 客户端配置：每个 service 绑定独立 chain，
    # 通过 handler.chain 引用，而非在 forwarder node 里写 connector
    cat << EOF > /etc/gost/config.json
{
  "services": [
    {
      "name": "local-ike",
      "addr": ":${CLI_PORT_500}",
      "handler": {"type": "udp", "chain": "chain-ike"},
      "listener": {"type": "udp"},
      "forwarder": {
        "nodes": [{"name": "target", "addr": "${US_IP}:${SVR_PORT_500}"}]
      }
    },
    {
      "name": "local-nat-t",
      "addr": ":${CLI_PORT_4500}",
      "handler": {"type": "udp", "chain": "chain-nat-t"},
      "listener": {"type": "udp"},
      "forwarder": {
        "nodes": [{"name": "target", "addr": "${US_IP}:${SVR_PORT_4500}"}]
      }
    },
    {
      "name": "local-l2tp",
      "addr": ":${CLI_PORT_1701}",
      "handler": {"type": "udp", "chain": "chain-l2tp"},
      "listener": {"type": "udp"},
      "forwarder": {
        "nodes": [{"name": "target", "addr": "${US_IP}:${SVR_PORT_1701}"}]
      }
    }
  ],
  "chains": [
    {
      "name": "chain-ike",
      "hops": [{
        "name": "hop-0",
        "nodes": [{
          "name": "server",
          "addr": "${US_IP}:${SVR_PORT_500}",
          "connector": {"type": "relay"},
          "dialer":    {"type": "quic"}
        }]
      }]
    },
    {
      "name": "chain-nat-t",
      "hops": [{
        "name": "hop-0",
        "nodes": [{
          "name": "server",
          "addr": "${US_IP}:${SVR_PORT_4500}",
          "connector": {"type": "relay"},
          "dialer":    {"type": "quic"}
        }]
      }]
    },
    {
      "name": "chain-l2tp",
      "hops": [{
        "name": "hop-0",
        "nodes": [{
          "name": "server",
          "addr": "${US_IP}:${SVR_PORT_1701}",
          "connector": {"type": "relay"},
          "dialer":    {"type": "quic"}
        }]
      }]
    }
  ]
}
EOF
    echo -e "${GREEN}客户端配置已生成: /etc/gost/config.json${NC}"
else
    echo -e "${RED}无效的选择！未生成配置文件。请稍后手动配置 /etc/gost/config.json${NC}"
fi

# ============================================================
# 6. Systemd 守护进程
# ============================================================
if ! command -v systemctl &>/dev/null; then
    echo ""
    echo -e "${RED}警告：当前系统未检测到 systemd，无法配置守护进程。${NC}"
    echo -e "${GREEN}手动运行命令:${NC}"
    echo -e "${CYAN}  /usr/local/bin/gost -c /etc/gost/config.json${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}正在配置 Systemd 守护进程（断线自动重启 + 开机自启）...${NC}"

cat << 'EOF' > /etc/systemd/system/gost.service
[Unit]
Description=Gost v3 L2TP/IPsec over QUIC Tunnel
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/gost
ExecStart=/usr/local/bin/gost -c /etc/gost/config.json
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# ============================================================
# 7. 启动服务
# ============================================================
systemctl daemon-reload
systemctl enable gost
systemctl start gost
sleep 1

# ============================================================
# 8. 状态检查
# ============================================================
echo ""
echo -e "${GREEN}===============================================${NC}"
if systemctl is-active --quiet gost; then
    echo -e "${GREEN}  ✓ Gost 服务已成功运行，已设置开机自启${NC}"
    echo -e "${GREEN}  ✓ 断线后守护进程将在 5 秒内自动拉起${NC}"
    echo -e "${GREEN}===============================================${NC}"
    echo ""
    echo -e "${CYAN}查看实时日志:${NC}"
    echo -e "  journalctl -u gost -f"
    echo ""
    echo -e "${CYAN}查看当前状态:${NC}"
    echo -e "  systemctl status gost"
else
    echo -e "${RED}  ✗ Gost 服务未能启动${NC}"
    echo -e "${GREEN}===============================================${NC}"
    echo ""
    echo -e "${YELLOW}请运行以下命令排查：${NC}"
    echo -e "  ${CYAN}journalctl -u gost -n 50 --no-pager${NC}"
    echo -e "  ${CYAN}gost -c /etc/gost/config.json${NC}   (前台试跑)"
fi
