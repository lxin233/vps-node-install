#!/usr/bin/env bash
#
# 一键安装脚本：VLESS + Reality (443) + Shadowsocks (8443) + Hysteria2 (443 UDP)
# 适用系统：Ubuntu 22.04 / 24.04，全新服务器，root 运行
# 用法：bash install.sh
# 跑完会打印三个节点的链接（vless / ss / hysteria2），导入小火箭即可使用
# 注意：UUID 和密码每次运行都是新随机生成的，链接不要公开
#
set -euo pipefail

# ---------- 0. 必须是 root ----------
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行：sudo bash install.sh"
  exit 1
fi

echo "==> [1/8] 更新系统并安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget unzip openssl ufw fail2ban unattended-upgrades

echo "==> [2/8] 生成随机密钥（UUID / 密码）..."
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
SS_PASS=$(openssl rand -base64 16)
HY_PASS=""
while [ -z "$HY_PASS" ] || [[ "$HY_PASS" == *"/"* ]]; do
  HY_PASS=$(openssl rand -base64 16)
done
SHORT_ID=$(openssl rand -hex 1)
SERVER_IP=$(curl -fsSL -4 ifconfig.me || curl -fsSL -4 icanhazip.com || hostname -I | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
  echo "获取公网 IP 失败，请检查网络后重试"
  exit 1
fi
echo "    服务器 IP：$SERVER_IP"

echo "==> [3/8] 安装 Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "==> [4/8] 生成 Reality 密钥对..."
KEY_OUTPUT=$(/usr/local/bin/xray x25519)
REALITY_PRIV=$(echo "$KEY_OUTPUT" | awk -F': ' '/Private key/{print $2}')
REALITY_PUB=$(echo "$KEY_OUTPUT" | awk -F': ' '/Public key/{print $2}')
if [ -z "$REALITY_PRIV" ] || [ -z "$REALITY_PUB" ]; then
  echo "生成 Reality 密钥失败"
  exit 1
fi

echo "==> [5/8] 写 Xray 配置（VLESS 443 + SS 8443）..."
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$VLESS_UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "www.microsoft.com:443",
          "serverNames": [ "www.microsoft.com" ],
          "privateKey": "$REALITY_PRIV",
          "shortIds": [ "$SHORT_ID" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls" ] }
    },
    {
      "port": 8443,
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "$SS_PASS",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
systemctl restart xray
systemctl enable xray

echo "==> [6/8] 安装 Hysteria2（443 UDP）..."
bash <(curl -fsSL https://get.hy2.sh/)
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /etc/hysteria/cert.key -out /etc/hysteria/cert.crt \
  -days 365 -subj "/CN=www.microsoft.com" 2>/dev/null
cat > /etc/hysteria/config.yaml <<EOF
listen: :443

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/cert.key

auth:
  type: password
  password: $HY_PASS

bandwidth:
  up: 100 mbps
  down: 500 mbps
EOF
# 修复权限：hysteria 用户需要能读配置和证书，否则启动报 permission denied
chgrp hysteria /etc/hysteria
chmod 750 /etc/hysteria
chgrp hysteria /etc/hysteria/cert.crt /etc/hysteria/cert.key /etc/hysteria/config.yaml
chmod 640 /etc/hysteria/cert.crt /etc/hysteria/cert.key
chmod 644 /etc/hysteria/config.yaml
systemctl daemon-reload
systemctl enable --now hysteria-server
systemctl restart hysteria-server

echo "==> [7/8] 加固：防火墙 + fail2ban + 自动更新..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 8443/tcp
ufw allow 8443/udp
ufw --force enable

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 5

[sshd]
enabled = true
bantime = 86400
findtime = 600
maxretry = 5
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# 自动更新：装好并设到半夜跑，避免白天占满单核 CPU 拖慢节点
dpkg-reconfigure -f noninteractive unattended-upgrades || true
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<EOF
[Timer]
OnCalendar=
OnCalendar=03:30
RandomizedDelaySec=15min
EOF
systemctl daemon-reload

echo "==> [8/8] 检查服务状态..."
systemctl is-active xray hysteria-server fail2ban || echo "警告：有服务未启动，请检查 systemctl status"
ss -tlnp | grep -E ':(443|8443)' || true
ss -ulnp | grep -E ':443' || true

# ---------- 生成三个节点链接 ----------
VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp#VLESS-443"
SS_USERINFO=$(printf '2022-blake3-aes-128-gcm:%s' "$SS_PASS" | base64 -w0 | tr '+/' '-_' | tr -d '=')
SS_LINK="ss://${SS_USERINFO}@${SERVER_IP}:8443#SS-8443"
HY_LINK="hysteria2://${HY_PASS}@${SERVER_IP}:443/?insecure=1&sni=www.microsoft.com#Hysteria2-443"

{
  echo "VLESS: $VLESS_LINK"
  echo "SS: $SS_LINK"
  echo "Hysteria2: $HY_LINK"
} | tee /root/node-links.txt

echo ""
echo "================ 安装完成 ================"
echo "服务器 IP：$SERVER_IP"
echo ""
echo "VLESS 链接："
echo "$VLESS_LINK"
echo ""
echo "SS 链接："
echo "$SS_LINK"
echo ""
echo "Hysteria2 链接："
echo "$HY_LINK"
echo ""
echo "链接也保存在 /root/node-links.txt，导入小火箭即可使用。"
echo "注意：链接含密码和 UUID，不要公开分享。"
if [ -f /var/run/reboot-required ]; then
  echo "提示：系统有内核更新待重启，节点不受影响，空闲时重启一次即可。"
fi
echo "==========================================="
