#!/bin/sh
#
# Script for automatic setup of an IPsec VPN server on Ubuntu and Debian.
# Works on any dedicated server or virtual private server (VPS) except OpenVZ.
#
# DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC!
#
# The latest version of this script is available at:
# https://github.com/hwdsl2/setup-ipsec-vpn
#
# Copyright (C) 2014-2020 Lin Song <linsongui@gmail.com>
# Based on the work of Thomas Sarlandie (Copyright 2012)
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it!

# =====================================================

# Define your own values for these variables
# - IPsec pre-shared key, VPN username and password
# - All values MUST be placed inside 'single quotes'
# - DO NOT use these special characters within values: \ " '

YOUR_USERNAME='123'
YOUR_PASSWORD='123'

# Important notes:   https://git.io/vpnnotes
# Setup VPN clients: https://git.io/vpnclients
# IKEv2 guide:       https://git.io/ikev2

# =====================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SYS_DT=$(date +%F-%T | tr ':' '_')


# fhq he wget
distro=$(cat /etc/os-release | grep -oP '^NAME="\K[^"]+')
if [[ $distro =~ "Ubuntu" || $distro =~ "Debian" ]]; then
  ufw disable
  apt install wget -y
  echo "UFW firewall disabled"
elif [[ $distro =~ "CentOS" || $distro =~ "Fedora" ]]; then
  systemctl stop firewalld
  systemctl disable firewalld
  yum install wget -y
  echo "Firewalld firewall stopped and disabled"
elif [[ $distro =~ "RHEL" ]]; then
  service iptables stop
  chkconfig iptables off
  echo "iptables firewall stopped and disabled"
else
  echo "Unsupported distribution: $distro"
  exit 1
fi






exiterr()  { echo "Error: $1" >&2; exit 1; }
exiterr2() { exiterr "'apt-get install' failed."; }
conf_bk() { /bin/cp -f "$1" "$1.old-$SYS_DT" 2>/dev/null; }
bigecho() { echo; echo "## $1"; echo; }





check_ip() {
  IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

vpnsetup() {

os_type=$(lsb_release -si 2>/dev/null)
if [ -z "$os_type" ]; then
  [ -f /etc/os-release  ] && os_type=$(. /etc/os-release  && printf '%s' "$ID")
  [ -f /etc/lsb-release ] && os_type=$(. /etc/lsb-release && printf '%s' "$DISTRIB_ID")
fi
if ! printf '%s' "$os_type" | head -n 1 | grep -qiF -e ubuntu -e debian -e raspbian; then
  echo "Error: This script only supports Ubuntu and Debian." >&2
  echo "For CentOS/RHEL, use https://git.io/vpnsetup-centos" >&2
  exit 1
fi

if [ "$(sed 's/\..*//' /etc/debian_version)" = "10" ] && [ ! -e /dev/ppp ]; then
  exiterr "/dev/ppp is missing. Debian 10 users, see: https://git.io/vpndebian10"
fi

if [ -f /proc/user_beancounters ]; then
  exiterr "OpenVZ VPS is not supported. Try OpenVPN: github.com/Nyr/openvpn-install"
fi

if [ "$(id -u)" != 0 ]; then
  exiterr "Script must be run as root. Try 'sudo sh $0'"
fi

def_iface=$(route 2>/dev/null | grep -m 1 '^default' | grep -o '[^ ]*$')
[ -z "$def_iface" ] && def_iface=$(ip -4 route list 0/0 2>/dev/null | grep -m 1 -Po '(?<=dev )(\S+)')
def_state=$(cat "/sys/class/net/$def_iface/operstate" 2>/dev/null)
if [ -n "$def_state" ] && [ "$def_state" != "down" ]; then
  if ! uname -m | grep -qi '^arm'; then
    case "$def_iface" in
      wl*)
        exiterr "Wireless interface '$def_iface' detected. DO NOT run this script on your PC or Mac!"
        ;;
    esac
  fi
  NET_IFACE="$def_iface"
else
  eth0_state=$(cat "/sys/class/net/eth0/operstate" 2>/dev/null)
  if [ -z "$eth0_state" ] || [ "$eth0_state" = "down" ]; then
    exiterr "Could not detect the default network interface."
  fi
  NET_IFACE=eth0
fi

[ -n "$YOUR_USERNAME" ] && VPN_USER="$YOUR_USERNAME"
[ -n "$YOUR_PASSWORD" ] && VPN_PASSWORD="$YOUR_PASSWORD"

if [ -z "$VPN_USER" ] && [ -z "$VPN_PASSWORD" ]; then
  bigecho "VPN credentials not set by user. Generating random PSK and password..."
  VPN_USER=vpnuser
  VPN_PASSWORD=$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 16)
fi

if [ -z "$VPN_USER" ] || [ -z "$VPN_PASSWORD" ]; then
  exiterr "All VPN credentials must be specified. Edit the script and re-enter them."
fi

if printf '%s' "$VPN_USER $VPN_PASSWORD" | LC_ALL=C grep -q '[^ -~]\+'; then
  exiterr "VPN credentials must not contain non-ASCII characters."
fi

case "$VPN_USER $VPN_PASSWORD" in
  *[\\\"\']*)
    exiterr "VPN credentials must not contain these special characters: \\ \" '"
    ;;
esac

if { [ -n "$VPN_DNS_SRV1" ] && ! check_ip "$VPN_DNS_SRV1"; } \
  || { [ -n "$VPN_DNS_SRV2" ] && ! check_ip "$VPN_DNS_SRV2"; } then
  exiterr "The DNS server specified is invalid."
fi

if [ -x /sbin/iptables ] && ! iptables -nL INPUT >/dev/null 2>&1; then
  exiterr "IPTables check failed. Reboot and re-run this script."
fi

bigecho "VPN setup in progress... Please be patient."

# Create and change to working dir
mkdir -p /opt/src
cd /opt/src || exit 1

count=0
APT_LK=/var/lib/apt/lists/lock
PKG_LK=/var/lib/dpkg/lock
while fuser "$APT_LK" "$PKG_LK" >/dev/null 2>&1 \
  || lsof "$APT_LK" >/dev/null 2>&1 || lsof "$PKG_LK" >/dev/null 2>&1; do
  [ "$count" = "0" ] && bigecho "Waiting for apt to be available..."
  [ "$count" -ge "60" ] && exiterr "Could not get apt/dpkg lock."
  count=$((count+1))
  printf '%s' '.'
  sleep 3
done

bigecho "Populating apt-get cache..."

export DEBIAN_FRONTEND=noninteractive

apt-get -yq update || exiterr "'apt-get update' failed."

bigecho "Installing packages required for setup..."

apt-get -yq install wget dnsutils openssl \
  iptables iproute2 gawk grep sed net-tools || exiterr2

bigecho "Trying to auto discover IP of this server..."

cat <<'EOF'
In case the script hangs here for more than a few minutes,
press Ctrl-C to abort. Then edit it and manually enter IP.
EOF

# In case auto IP discovery fails, enter server's public IP here.
PUBLIC_IP=${VPN_PUBLIC_IP:-''}

[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(dig @resolver1.opendns.com -t A -4 myip.opendns.com +short)

check_ip "$PUBLIC_IP" || PUBLIC_IP=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)
check_ip "$PUBLIC_IP" || exiterr "Cannot detect this server's public IP. Edit the script and manually enter it."

bigecho "Installing packages required for the VPN..."

apt-get -yq install libnss3-dev libnspr4-dev pkg-config \
  libpam0g-dev libcap-ng-dev libcap-ng-utils libselinux1-dev \
  libcurl4-nss-dev flex bison gcc make libnss3-tools \
  libevent-dev ppp xl2tpd || exiterr2

bigecho "Installing Fail2Ban to protect SSH..."

apt-get -yq install fail2ban || exiterr2


bigecho "Creating VPN configuration..."

L2TP_NET=${VPN_L2TP_NET:-'172.28.42.0/24'}
L2TP_LOCAL=${VPN_L2TP_LOCAL:-'172.28.42.1'}
L2TP_POOL=${VPN_L2TP_POOL:-'172.28.42.10-172.28.42.250'}
XAUTH_NET=${VPN_XAUTH_NET:-'172.28.43.0/24'}
XAUTH_POOL=${VPN_XAUTH_POOL:-'172.28.43.10-172.28.43.250'}
DNS_SRV1=${VPN_DNS_SRV1:-'8.8.8.8'}
DNS_SRV2=${VPN_DNS_SRV2:-'8.8.4.4'}
DNS_SRVS="\"$DNS_SRV1 $DNS_SRV2\""
[ -n "$VPN_DNS_SRV1" ] && [ -z "$VPN_DNS_SRV2" ] && DNS_SRVS="$DNS_SRV1"


# Create xl2tpd config
conf_bk "/etc/xl2tpd/xl2tpd.conf"
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = $L2TP_POOL
local ip = $L2TP_LOCAL
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# Set xl2tpd options
conf_bk "/etc/ppp/options.xl2tpd"
cat > /etc/ppp/options.xl2tpd <<EOF
+mschap-v2
ipcp-accept-local
ipcp-accept-remote
noccp
auth
mtu 1280
mru 1280
proxyarp
lcp-echo-failure 4
lcp-echo-interval 30
connect-delay 5000
ms-dns $DNS_SRV1
EOF

if [ -z "$VPN_DNS_SRV1" ] || [ -n "$VPN_DNS_SRV2" ]; then
cat >> /etc/ppp/options.xl2tpd <<EOF
ms-dns $DNS_SRV2
EOF
fi

# Create VPN credentials
conf_bk "/etc/ppp/chap-secrets"
cat > /etc/ppp/chap-secrets <<EOF
"$VPN_USER" l2tpd "$VPN_PASSWORD" *
EOF


bigecho "Updating sysctl settings..."

if ! grep -qs "hwdsl2 VPN script" /etc/sysctl.conf; then
  conf_bk "/etc/sysctl.conf"
  if [ "$(getconf LONG_BIT)" = "64" ]; then
    SHM_MAX=68719476736
    SHM_ALL=4294967296
  else
    SHM_MAX=4294967295
    SHM_ALL=268435456
  fi
cat >> /etc/sysctl.conf <<EOF

# Added by hwdsl2 VPN script
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.shmmax = $SHM_MAX
kernel.shmall = $SHM_ALL

net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.$NET_IFACE.send_redirects = 0
net.ipv4.conf.$NET_IFACE.rp_filter = 0

net.core.wmem_max = 12582912
net.core.rmem_max = 12582912
net.ipv4.tcp_rmem = 10240 87380 12582912
net.ipv4.tcp_wmem = 10240 87380 12582912
EOF
fi

bigecho "Updating IPTables rules..."

IPT_FILE=/etc/iptables.rules
IPT_FILE2=/etc/iptables/rules.v4
ipt_flag=0
if ! grep -qs "hwdsl2 VPN script" "$IPT_FILE"; then
  ipt_flag=1
fi

if [ "$ipt_flag" = "1" ]; then
  service fail2ban stop >/dev/null 2>&1
  iptables-save > "$IPT_FILE.old-$SYS_DT"
  # iptables -I INPUT 1 -p udp --dport 1701 -m policy --dir in --pol none -j DROP
  # iptables -I INPUT 2 -m conntrack --ctstate INVALID -j DROP
  # iptables -I INPUT 3 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  # iptables -I INPUT 4 -p udp -m multiport --dports 500,4500 -j ACCEPT
  # iptables -I INPUT 5 -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
  iptables -I INPUT 1 -p udp --dport 1701 -j ACCEPT
  # iptables -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
  iptables -I FORWARD 2 -i "$NET_IFACE" -o ppp+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -I FORWARD 3 -i ppp+ -o "$NET_IFACE" -j ACCEPT
  iptables -I FORWARD 4 -i ppp+ -o ppp+ -s "$L2TP_NET" -d "$L2TP_NET" -j ACCEPT
  # iptables -I FORWARD 5 -i "$NET_IFACE" -d "$XAUTH_NET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -I FORWARD 6 -s "$L2TP_NET" -o "$NET_IFACE" -j ACCEPT
  iptables -A FORWARD -s "$L2TP_NET" -j ACCEPT
  # Uncomment to disallow traffic between VPN clients
  # iptables -I FORWARD 2 -i ppp+ -o ppp+ -s "$L2TP_NET" -d "$L2TP_NET" -j DROP
  # iptables -I FORWARD 3 -s "$XAUTH_NET" -d "$XAUTH_NET" -j DROP
  # iptables -A FORWARD -j DROP
  # iptables -t nat -I POSTROUTING -s "$XAUTH_NET" -o "$NET_IFACE" -m policy --dir out --pol none -j MASQUERADE
  iptables -t nat -I POSTROUTING -s "$L2TP_NET" -o "$NET_IFACE" -j MASQUERADE
  echo "# Modified by hwdsl2 VPN script" > "$IPT_FILE"
  iptables-save >> "$IPT_FILE"

  if [ -f "$IPT_FILE2" ]; then
    conf_bk "$IPT_FILE2"
    /bin/cp -f "$IPT_FILE" "$IPT_FILE2"
  fi
fi

bigecho "Enabling services on boot..."

IPT_PST=/etc/init.d/iptables-persistent
IPT_PST2=/usr/share/netfilter-persistent/plugins.d/15-ip4tables
ipt_load=1
if [ -f "$IPT_FILE2" ] && { [ -f "$IPT_PST" ] || [ -f "$IPT_PST2" ]; }; then
  ipt_load=0
fi

if [ "$ipt_load" = "1" ]; then
  mkdir -p /etc/network/if-pre-up.d
cat > /etc/network/if-pre-up.d/iptablesload <<'EOF'
#!/bin/sh
iptables-restore < /etc/iptables.rules
exit 0
EOF
  chmod +x /etc/network/if-pre-up.d/iptablesload

  if [ -f /usr/sbin/netplan ]; then
    mkdir -p /etc/systemd/system
cat > /etc/systemd/system/load-iptables-rules.service <<'EOF'
[Unit]
Description = Load /etc/iptables.rules
DefaultDependencies=no

Before=network-pre.target
Wants=network-pre.target

Wants=systemd-modules-load.service local-fs.target
After=systemd-modules-load.service local-fs.target

[Service]
Type=oneshot
ExecStart=/etc/network/if-pre-up.d/iptablesload

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable load-iptables-rules 2>/dev/null
  fi
fi

for svc in fail2ban xl2tpd; do
  update-rc.d "$svc" enable >/dev/null 2>&1
  systemctl enable "$svc" 2>/dev/null
done

if ! grep -qs "hwdsl2 VPN script" /etc/rc.local; then
  if [ -f /etc/rc.local ]; then
    conf_bk "/etc/rc.local"
    sed --follow-symlinks -i '/^exit 0/d' /etc/rc.local
  else
    echo '#!/bin/sh' > /etc/rc.local
  fi
cat >> /etc/rc.local <<'EOF'

# Added by hwdsl2 VPN script
(sleep 15
service xl2tpd restart
echo 1 > /proc/sys/net/ipv4/ip_forward)&
exit 0
EOF
fi

bigecho "Starting services..."

sysctl -e -q -p

chmod +x /etc/rc.local
chmod 600 /etc/ppp/chap-secrets*

mkdir -p /run/pluto
service fail2ban restart 2>/dev/null
service xl2tpd restart 2>/dev/null

cat <<EOF

================================================

IPsec VPN server is now ready for use!

Connect to your new VPN with these details:

Server IP: $PUBLIC_IP
Username: $VPN_USER
Password: $VPN_PASSWORD

Write these down. You'll need them to connect!

Important notes:   https://git.io/vpnnotes
Setup VPN clients: https://git.io/vpnclients
IKEv2 guide:       https://git.io/ikev2

================================================

EOF

}

## Defer setup until we have the complete script
vpnsetup "$@"

exit 0
