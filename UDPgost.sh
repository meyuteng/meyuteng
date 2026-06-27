#!/bin/bash
# 强制使用 UTF-8 编码，防止中文提示词乱码
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 颜色定义
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

# 2. 检查必要工具
if command -v wget &>/dev/null; then
    DL_CMD="wget -O"
elif command -v curl &>/dev/null; then
    DL_CMD="curl -L -o"
else
    echo -e "${RED}错误：未找到 wget 或 curl，请先安装其中之一！${NC}"
    exit 1
fi

# 3. 检测系统架构并获取最新下载链接
ARCH=$(uname -m)
echo -e "${YELLOW}正在检测系统架构... 当前架构为: ${ARCH}${NC}"

# GOST 最新稳定版 v3.2.6
GOST_VER="3.2.6"
case "$ARCH" in
    x86_64|amd64)
        ARCH_NAME="amd64"
        ;;
    aarch64|arm64|armv8*)
        ARCH_NAME="arm64"
        ;;
    *)
        echo -e "${RED}不支持的系统架构: ${ARCH}！仅支持 x86_64 和 arm64。${NC}"
        exit 1
        ;;
esac

URL="https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${ARCH_NAME}.tar.gz"
echo -e "${YELLOW}下载地址: ${URL}${NC}"

# 4. 下载与安装 Gost
echo -e "${YELLOW}正在创建配置目录 /etc/gost ...${NC}"
mkdir -p /etc/gost

echo -e "${YELLOW}正在从 GitHub 下载 Gost v${GOST_VER} 稳定版...${NC}"
if [ "$DL_CMD" = "wget -O" ]; then
    wget -O /tmp/gost.tar.gz "$URL"
else
    curl -L -o /tmp/gost.tar.gz "$URL"
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败，请检查服务器网络或 GitHub 连接！${NC}"
    rm -f /tmp/gost.tar.gz
    exit 1
fi

echo -e "${YELLOW}正在解压并安装到 /usr/local/bin/gost ...${NC}"
# 显式解压 gost 二进制文件，避免目录结构导致的 mv 失败
tar -zxf /tmp/gost.tar.gz -C /usr/local/bin gost 2>/dev/null
if [ $? -ne 0 ]; then
    echo -e "${RED}解压失败！压缩包可能结构异常，尝试备用方式...${NC}"
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
if /usr/local/bin/gost -V &>/dev/null; then
    echo -e "${GREEN}Gost 主程序安装成功！当前版本：$('/usr/local/bin/gost' -V)${NC}"
else
    echo -e "${RED}警告：gost 二进制文件无法执行，可能与当前系统不兼容。${NC}"
    echo -e "${RED}请检查: uname -m = ${ARCH}, 下载架构 = ${ARCH_NAME}${NC}"
    exit 1
fi

# 5. 提示用户选择配置模板
echo -e "${GREEN}-----------------------------------------------${NC}"
echo -e "${YELLOW}请选择这台服务器的角色以生成对应的配置文件：${NC}"
echo -e "  [1] 部署在美国服务器 (QUIC 服务端接收端)"
echo -e "  [2] 部署在本地/日本中转服务器 (QUIC 客户端发送端)"
read -p "请输入数字 [1 或 2]: " ROLE

if [ "$ROLE" = "1" ]; then
    # 生成美国服务端配置
    # GOST v3 格式：QUIC 监听 → forward 处理器 → 转发到本地 UDP 端口
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
          {"name": "udp-500",  "addr": "127.0.0.1:500"},
          {"name": "udp-4500","addr": "127.0.0.1:4500"},
          {"name": "udp-1701","addr": "127.0.0.1:1701"}
        ]
      }
    }
  ]
}
EOF
    echo -e "${YELLOW}注意：forwarder 节点采用 GOST v3 标准 addr 格式。${NC}"
    echo -e "${YELLOW}如果后端是 UDP 服务，可能需要调整 handler 类型为 \"udp\"。${NC}"

elif [ "$ROLE" = "2" ]; then
    # 生成本地客户端配置
    read -p "请输入您【美国服务器】的公网 IP 地址: " US_IP
    while [ -z "$US_IP" ]; do
        read -p "IP 不能为空，请重新输入美国服务器 IP: " US_IP
    done

    echo -e "${YELLOW}正在生成本地客户端配置文件 /etc/gost/config.json ...${NC}"
    # GOST v3 格式：UDP 监听 → forward 处理器 → relay over QUIC 转发到远程
    cat << EOF > /etc/gost/config.json
{
  "services": [
    {
      "name": "local-500",
      "addr": ":500",
      "handler": {"type": "forward"},
      "listener": {"type": "udp"},
      "forwarder": {
        "nodes": [{
          "name": "remote",
          "addr": "$US_IP:443",
          "connector": {"type": "relay"},
          "dialer": {"type": "quic"}
        }]
      }
    },
    {
      "name": "local-4500",
      "addr": ":4500",
      "handler": {"type": "forward"},
      "listener": {"type": "udp"},
      "forwarder": {
        "nodes": [{
          "name": "remote",
          "addr": "$US_IP:443",
          "connector": {"type": "relay"},
          "dialer": {"type": "quic"}
        }]
      }
    },
    {
      "name": "local-1701",
      "addr": ":1701",
      "handler": {"type": "forward"},
      "listener": {"type": "udp"},
      "forwarder": {
        "nodes": [{
          "name": "remote",
          "addr": "$US_IP:443",
          "connector": {"type": "relay"},
          "dialer": {"type": "quic"}
        }]
      }
    }
  ]
}
EOF
else
    echo -e "${RED}无效的选择！未生成配置文件。请稍后手动在 /etc/gost/config.json 中配置。${NC}"
fi

# 6. 创建 Systemd 守护进程服务文件
if ! command -v systemctl &>/dev/null; then
    echo -e "${RED}警告：当前系统未检测到 systemd，无法配置守护进程。${NC}"
    echo -e "${RED}请手动使用 nohup 或 supervisord 等方式运行 gost。${NC}"
    echo -e "${GREEN}手动运行命令: /usr/local/bin/gost -c /etc/gost/config.json${NC}"
    exit 0
fi

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

# 7. 重新加载 Systemd 配置并启动服务
systemctl daemon-reload
systemctl enable gost
systemctl start gost

# 8. 检查服务运行状态
echo -e "${GREEN}===============================================${NC}"
if systemctl is-active --quiet gost; then
    echo -e "${GREEN}恭喜！Gost 服务已成功在后台运行，并已设置为开机自启。${NC}"
    echo -e "${GREEN}如果连接中断，守护进程会在 5 秒内自动将其拉起重启。${NC}"
else
    echo -e "${RED}警告：Gost 服务未能成功启动，请运行以下命令查看错误日志：${NC}"
    echo -e "${YELLOW}  journalctl -u gost -n 50 --no-pager${NC}"
    echo -e "${YELLOW}  cat /etc/gost/config.json  (检查配置文件)${NC}"
fi
echo -e "${GREEN}===============================================${NC}"
