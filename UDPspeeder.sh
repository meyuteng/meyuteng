#!/bin/bash
# UDPspeeder 一键安装脚本 — UDP 加速隧道 (FEC 多倍发包)
# 使用 systemd 守护进程运行，断线自动重启、开机自启
# 项目: https://github.com/wangyu-/UDPspeeder

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}   UDPspeeder 一键安装 — UDP 加速隧道           ${NC}"
echo -e "${GREEN}===============================================${NC}"

# ============================================================
# 1. 检查 Root 权限
# ============================================================
[ "$EUID" -ne 0 ] && echo -e "${RED}错误：必须使用 root 权限运行此脚本！${NC}" && exit 1

# ============================================================
# 2. 检查必要工具
# ============================================================
if command -v wget &>/dev/null; then
    DL_CMD="wget"
elif command -v curl &>/dev/null; then
    DL_CMD="curl"
else
    echo -e "${RED}错误：未找到 wget 或 curl，请先安装其中之一！${NC}" && exit 1
fi

# ============================================================
# 3. 检测系统架构
# ============================================================
ARCH=$(uname -m)
echo -e "${YELLOW}系统架构: ${ARCH}${NC}"

case "$ARCH" in
    i386|i686)   BIN_NAME="speederv2_x86" ;;
    x86_64|amd64) BIN_NAME="speederv2_amd64" ;;
    *)
        echo -e "${RED}不支持的系统架构: ${ARCH}！仅支持 i386 / i686 / x86_64。${NC}"
        exit 1
        ;;
esac

# ============================================================
# 4. 获取最新版本号
# ============================================================
echo -e "${YELLOW}正在获取最新版本...${NC}"
LATEST_VER=$(curl -s https://api.github.com/repos/wangyu-/UDPspeeder/releases/latest | grep '"tag_name"' | cut -d'"' -f4)

[ -z "$LATEST_VER" ] && echo -e "${RED}无法获取最新版本号，请检查网络连通性！${NC}" && exit 1

echo -e "${GREEN}最新版本: ${LATEST_VER}${NC}"

# ============================================================
# 5. 下载与安装
# ============================================================
URL="https://github.com/wangyu-/UDPspeeder/releases/download/${LATEST_VER}/speederv2_binaries.tar.gz"
echo -e "${YELLOW}下载: ${URL}${NC}"

mkdir -p /etc/udpspeeder

if [ "$DL_CMD" = "wget" ]; then
    wget --no-check-certificate -O /tmp/udpspeeder.tar.gz "$URL"
else
    curl -L -o /tmp/udpspeeder.tar.gz "$URL"
fi

[ $? -ne 0 ] && echo -e "${RED}下载失败！${NC}" && rm -f /tmp/udpspeeder.tar.gz && exit 1

mkdir -p /tmp/udpspeeder
tar zxf /tmp/udpspeeder.tar.gz -C /tmp/udpspeeder
cp -f "/tmp/udpspeeder/${BIN_NAME}" /usr/local/bin/speederv2
chmod +x /usr/local/bin/speederv2
rm -rf /tmp/udpspeeder /tmp/udpspeeder.tar.gz

[ -x /usr/local/bin/speederv2 ] && echo -e "${GREEN}UDPspeeder 安装成功: /usr/local/bin/speederv2${NC}" || { echo -e "${RED}安装失败！${NC}"; exit 1; }

# ============================================================
# 6. 选择角色 + 加密密码
# ============================================================
echo ""
echo -e "${GREEN}-----------------------------------------------${NC}"
echo -e "${YELLOW}请选择角色：${NC}"
echo -e "  ${CYAN}[1]${NC} 服务端 — 运行在目标服务器上 (${GREEN}-s${NC})"
echo -e "  ${CYAN}[2]${NC} 客户端 — 运行在本地/中转机器上 (${GREEN}-c${NC})"
read -p "请输入 [1 或 2]: " ROLE

# ============================================================
# 默认参数 (全部硬编码，不询问)
# ============================================================
PASSWORD="udpspeeder"
BIND_IP="0.0.0.0"
SVR_LISTEN_PORT="7776"
SVR_TARGET="127.0.0.1:1701"
FEC_PARAM="2:4"
WORK_MODE="0"
TIMEOUT="0"

# ============================================================
# 角色 1 — 服务端
# ============================================================
if [ "$ROLE" = "1" ]; then
    SPEEDER_ARGS="-s -l ${BIND_IP}:${SVR_LISTEN_PORT} -r ${SVR_TARGET} -k ${PASSWORD} --mode ${WORK_MODE} -f${FEC_PARAM} --timeout ${TIMEOUT}"

    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}  服务端配置:${NC}"
    echo -e "${YELLOW}    监听: ${BIND_IP}:${SVR_LISTEN_PORT} → 转发: ${SVR_TARGET}${NC}"
    echo -e "${YELLOW}    密码: ${PASSWORD}   FEC: -f${FEC_PARAM}${NC}"
    echo -e "${YELLOW}============================================================${NC}"

    cat << EOF > /etc/udpspeeder/config
# UDPspeeder 服务端配置 ($(date '+%Y-%m-%d %H:%M'))
ROLE="server"
BIND_IP="${BIND_IP}"
LISTEN_PORT="${SVR_LISTEN_PORT}"
TARGET="${SVR_TARGET}"
PASSWORD="${PASSWORD}"
MODE="${WORK_MODE}"
FEC="${FEC_PARAM}"
TIMEOUT="${TIMEOUT}"
SPEEDER_ARGS="-s -l ${BIND_IP}:${SVR_LISTEN_PORT} -r ${SVR_TARGET} -k ${PASSWORD} --mode ${WORK_MODE} -f${FEC_PARAM} --timeout ${TIMEOUT}"
EOF

    echo -e "${GREEN}配置已保存: /etc/udpspeeder/config${NC}"
    echo -e "${YELLOW}请确保防火墙已开放 UDP 端口: ${SVR_LISTEN_PORT}${NC}"

# ============================================================
# 角色 2 — 客户端
# ============================================================
elif [ "$ROLE" = "2" ]; then
    read -p "请输入【服务端】公网 IP: " SERVER_IP
    while [ -z "$SERVER_IP" ]; do
        read -p "IP 不能为空，请重新输入: " SERVER_IP
    done

    SPEEDER_ARGS="-c -l ${BIND_IP}:1701 -r ${SERVER_IP}:${SVR_LISTEN_PORT} -k ${PASSWORD} --mode ${WORK_MODE} -f${FEC_PARAM} --timeout ${TIMEOUT}"

    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}  客户端配置:${NC}"
    echo -e "${YELLOW}    本地 ${BIND_IP}:1701 → 远程 ${SERVER_IP}:${SVR_LISTEN_PORT}${NC}"
    echo -e "${YELLOW}    密码: ${PASSWORD}   FEC: -f${FEC_PARAM}${NC}"
    echo -e "${YELLOW}============================================================${NC}"

    cat << EOF > /etc/udpspeeder/config
# UDPspeeder 客户端配置 ($(date '+%Y-%m-%d %H:%M'))
ROLE="client"
BIND_IP="${BIND_IP}"
LOCAL_PORT="1701"
SERVER_IP="${SERVER_IP}"
SERVER_PORT="${SVR_LISTEN_PORT}"
PASSWORD="${PASSWORD}"
MODE="${WORK_MODE}"
FEC="${FEC_PARAM}"
TIMEOUT="${TIMEOUT}"
SPEEDER_ARGS="-c -l ${BIND_IP}:1701 -r ${SERVER_IP}:${SVR_LISTEN_PORT} -k ${PASSWORD} --mode ${WORK_MODE} -f${FEC_PARAM} --timeout ${TIMEOUT}"
EOF

    echo -e "${GREEN}配置已保存: /etc/udpspeeder/config${NC}"

else
    echo -e "${RED}无效选择，安装中止。${NC}" && exit 1
fi

# ============================================================
# 7. 生成启动包装脚本
# ============================================================
cat << 'WRAPPER' > /usr/local/bin/speederv2-service.sh
#!/bin/bash
CONFIG_FILE="/etc/udpspeeder/config"
[ ! -f "$CONFIG_FILE" ] && echo "错误: 配置文件 $CONFIG_FILE 不存在！" && exit 1

# 从配置文件提取 SPEEDER_ARGS (兼容双引号/单引号/无引号三种格式)
SPEEDER_ARGS=$(grep "^SPEEDER_ARGS=" "$CONFIG_FILE" | head -1 | sed 's/^SPEEDER_ARGS=["'"'"']\(.*\)["'"'"']$/\1/')
[ -z "$SPEEDER_ARGS" ] && SPEEDER_ARGS=$(grep "^SPEEDER_ARGS=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-)
[ -z "$SPEEDER_ARGS" ] && echo "错误: 未能解析 SPEEDER_ARGS！" && exit 1

eval exec /usr/local/bin/speederv2 $SPEEDER_ARGS
WRAPPER

chmod +x /usr/local/bin/speederv2-service.sh

# ============================================================
# 8. 检查 systemd
# ============================================================
if ! command -v systemctl &>/dev/null; then
    echo -e "${RED}警告：未检测到 systemd，无法配置守护进程。${NC}"
    echo -e "${GREEN}手动运行: ${CYAN}/usr/local/bin/speederv2-service.sh${NC}"
    exit 0
fi

# ============================================================
# 9. 创建 systemd 服务并启动
# ============================================================
cat << 'SVC' > /etc/systemd/system/speederv2.service
[Unit]
Description=UDPspeeder - UDP Tunnel with FEC
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/speederv2-service.sh
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable speederv2
systemctl start speederv2
sleep 1

# ============================================================
# 10. 结果
# ============================================================
echo ""
if systemctl is-active --quiet speederv2; then
    echo -e "${GREEN}===============================================${NC}"
    echo -e "${GREEN}  ✓ UDPspeeder 服务已运行，开机自启已启用${NC}"
    echo -e "${GREEN}  ✓ 断线后 5 秒自动拉起${NC}"
    echo -e "${GREEN}===============================================${NC}"
    echo ""
    echo -e "${CYAN}管理命令:${NC}"
    echo -e "  systemctl status speederv2     ${YELLOW}# 状态${NC}"
    echo -e "  systemctl restart speederv2    ${YELLOW}# 重启${NC}"
    echo -e "  systemctl stop speederv2       ${YELLOW}# 停止${NC}"
    echo -e "  journalctl -u speederv2 -f     ${YELLOW}# 实时日志${NC}"
    echo ""
    echo -e "${CYAN}修改配置后重启:${NC}"
    echo -e "  vim /etc/udpspeeder/config && systemctl restart speederv2"
else
    echo -e "${RED}===============================================${NC}"
    echo -e "${RED}  ✗ 服务未能启动${NC}"
    echo -e "${RED}===============================================${NC}"
    echo -e "${YELLOW}排查: ${CYAN}journalctl -u speederv2 -n 50 --no-pager${NC}"
fi
