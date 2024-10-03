#!/bin/bash

# ������
if [ "$#" -ne 2 ]; then
    echo "Usage: \$0 <username> <password>"
    exit 1
fi

USERNAME=\$1
PASSWORD=\$2

# ��ȡ���� IP ��ַ
PUBLIC_IP=$(curl -s ifconfig.me)

# ����ϵͳ��
sudo apt-get update
sudo apt-get upgrade -y

# ��װ��Ҫ������
sudo apt-get install -y ppp openssl pptpd

# ��װ SSTP �����
sudo apt-get install -y sstp-client

# ���� SSTP �����
sudo tee /etc/ppp/chap-secrets > /dev/null <<EOF
# Secrets for authentication using CHAP
# client    server  secret          IP addresses
$USERNAME    sstp    $PASSWORD        *
EOF

# ���� SSTP ����
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

# ���������� pptpd ����
sudo systemctl enable pptpd
sudo systemctl start pptpd

# ���������� sstp-client ����
sudo systemctl enable sstp-client
sudo systemctl start sstp-client

# ���������Ϣ
echo "SSTP ������������ɡ�"
echo "�û���: $USERNAME"
echo "����: $PASSWORD"
echo "���� IP: $PUBLIC_IP"
echo "��ȷ������ǽ���� SSTP �˿� (443) ��������"
