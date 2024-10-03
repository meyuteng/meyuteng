#!/bin/bash
# 检查参数
if [ "$#" -ne 2 ]; then
    echo "Usage: \$0 <username> <password>"
    exit 1
fi

USERNAME=\$2
PASSWORD=\$4

# 获取公网 IP 地址
PUBLIC_IP=$(curl -s ifconfig.me)

# 更新系统包
sudo apt-get update
sudo apt-get upgrade -y

# 安装必要的依赖
sudo apt-get install -y ppp openssl pptpd

# 安装 SSTP 服务端
sudo apt-get install -y sstp-client

# 配置 SSTP 服务端
sudo tee /etc/ppp/chap-secrets > /dev/null <<EOF
# Secrets for authentication using CHAP
# client    server  secret          IP addresses
$USERNAME    sstp    $PASSWORD        *
EOF

# 配置 SSTP 服务
sudo tee /etc/ppp/peers/sstp-client > /dev/null <<EOF
pty "sstp-client --ipparam sstp --nolaunchpppd --remote-host $PUBLIC_IP --username $USERNAME --password $PASSWORD"
name $USERNAME
remotename sstp
ipparam sstp
usepeerdns
defaultroute
replacedefaultroute
persist
maxfail 0
holdoff 5
plugin sstp-pppd-plugin.so
sstp-sock /var/run/sstp-client/sstp-client.sock
EOF

# 启动并启用 pptpd 服务
sudo systemctl enable pptpd
sudo systemctl start pptpd

# 启动并启用 sstp-client 服务
sudo systemctl enable sstp-client
sudo systemctl start sstp-client

# 输出配置信息
echo "SSTP 服务已配置完成。"
echo "用户名: $USERNAME"
echo "密码: $PASSWORD"
echo "公网 IP: $PUBLIC_IP"
echo "请确保防火墙允许 SSTP 端口 (443) 的流量。"
