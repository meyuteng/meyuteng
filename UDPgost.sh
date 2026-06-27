#!/bin/bash

# 强制使用 UTF-8 编码，防止中文提示词乱码
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 颜色定义，方便看清提示
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}      GOST v3 一键安装与 Systemd 守护配置脚本       ${NC}"
echo -e "${GREEN}===============================================${NC}"

# 1. 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：必须使用 root 权限或 sudo 运行此脚本！${NC}"
    exit 1
fi

# 2. 检测系统架构并获取最新下载链接
ARCH=$(uname -m)
echo -e "${YELLOW}正在检测系统架构... 当前架构为: ${ARCH}${NC}"

if [ "$ARCH" = "x86_64" ]; then
    URL="https://github.com"
elif [ "$ARCH" = "aarch64" ]; then
    URL="https://github.com"
else
    echo -e "${RED}不支持的系统架构！仅支持 x86_64 和 arm64。${NC}"
    exit 1
fi

# 3. 下载与安装 Gost
echo -e "${YELLOW}正在创建配置目录 /etc/gost ...${NC}"
mkdir -p /etc/gost

echo -e "${YELLOW}正在从 GitHub 下载最新稳定版 Gost v3...${NC}"
wget -O /tmp/gost.tar.gz "$URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败，请检查服务器网络或 GitHub 连接！${NC}"
    exit 1
fi

echo -e "${YELLOW}正在解压并安装到 /usr/local/bin/gost ...${NC}"
tar -zxf /tmp/gost.tar.gz -C /tmp
mv /tmp/gost /usr/local/bin/gost
chmod +x /usr/local/bin/gost
rm -f /tmp/gost.tar.gz

echo -e "${GREEN}Gost 主程序安装成功！当前版本：$(gost -V)${NC}"

# 4. 提示用户选择配置模板
echo -e "${GREEN}-----------------------------------------------${NC}"
echo -e "${YELLOW}请选择这台服务器的角色以生成对应的配置文件：${NC}"
echo -e "  [1] 部署在美国服务器 (QUIC 服务端接收端)"
echo -e "  [2] 部署在本地/日本中转服务器 (QUIC 客户端发送端)"
read -p "请输入数字 [1 或 2]: " ROLE

if [ "$ROLE" = "1" ]; then
    # 生成美国服务端配置
    echo -e "${YELLOW}正在生成美国服务端配置文件 /etc/gost/config.json ...${NC}"
    cat << 'EOF' > /etc/gost/config.json
{
  "services": [
    {
      "name": "l2tp-quic-tunnel",
      "addr": ":443",
      "handler": {
        "type": "forward"
      },
      "listener": {
        "type": "quic"
      },
      "forwarder": {
        "nodes": [
          {"name": "udp-500", "addr": "127.0.0.1:500", "protocol": "udp"},
          {"name": "udp-4500", "addr": "127.0.0.1:4500", "protocol": "udp"},
          {"name": "udp-1701", "addr": "127.0.0.1:1701", "protocol": "udp"}
        ]
      }
    }
  ]
}
EOF
elif [ "$ROLE" = "2" ]; then
    # 生成本地客户端配置
    read -p "请输入您【美国服务器】的公网 IP 地址: " US_IP
    while [ -z "$US_IP" ]; do
        read -p "IP 不能为空，请重新输入美国服务器 IP: " US_IP
    done

    echo -e "${YELLOW}正在生成本地客户端配置文件 /etc/gost/config.json ...${NC}"
    cat << EOF > /etc/gost/config.json
{
  "services": [
    {
      "name": "local-500", "addr": ":500",
      "handler": {"type": "forward"}, "listener": {"type": "udp"},
      "forwarder": {"nodes": [{"url": "quic://$US_IP:443"}]}
    },
    {
      "name": "local-4500", "addr": ":4500",
      "handler": {"type": "forward"}, "listener": {"type": "udp"},
      "forwarder": {"nodes": [{"url": "quic://$US_IP:443"}]}
    },
    {
      "name": "local-1701", "addr": ":1701",
      "handler": {"type": "forward"}, "listener": {"type": "udp"},
      "forwarder": {"nodes": [{"url": "quic://$US_IP:443"}]}
    }
  ]
}
EOF
else
    echo -e "${RED}无效的选择！未生成配置文件。请稍后手动在 /etc/gost/config.json 中配置。${NC}"
fi

# 5. 创建 Systemd 守护进程服务文件
echo -e "${YELLOW}正在配置 Systemd 后台服务守护（包含断线重启与开机自启）...${NC}"

cat << 'EOF' > /etc/systemd/system/gost.service
[Unit]
Description=Gost v3 Tunnel Service
After=network.target network-online.target nss-lookup.target

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

# 6. 重新加载 Systemd 配置并启动服务
systemctl daemon-reload
systemctl enable gost
systemctl start gost

# 7. 检查服务运行状态
echo -e "${GREEN}===============================================${NC}"
if systemctl is-active --quiet gost; then
    echo -e "${GREEN}恭喜！Gost 服务已成功在后台运行，并已设置为开机自启。${NC}"
    echo -e "${GREEN}如果连接中断，守护进程会在 5 秒内自动将其拉起重启。${NC}"
else
    echo -e "${RED}警告：Gost 服务未能成功启动，请运行 'journalctl -u gost -n 50' 查看错误日志。${NC}"
fi
echo -e "${GREEN}===============================================${NC}"
