#!/bin/bash 
apt install wget curl gzip -y ||yum install wget curl gunzip -y
wget https://github.com/meyuteng/meyuteng/raw/main/gost-linux-amd64-2.11.1.gz
gunzip gost-linux-amd64-2.11.1.gz || gzip gost-linux-amd64-2.11.1.gz
mv gost-linux-amd64-2.11.1 /usr/local/bin/gost || mv gost-linux-amd64-2.11.1.gz /usr/local/bin/gost
chmod +x /usr/local/bin/gost
cat > /etc/systemd/system/gost.service << EOF
[Unit]
Description=Gost Proxy
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L 123:123@:1080 socks5://:1080
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

systemctl start gost.service

systemctl enable gost.service

echo "The installation is complete"
