#!/bin/bash
# ==========================================
# Color
RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LIGHT='\033[0;37m'
# ==========================================
# Getting

echo -e "
"
date
echo ""
cd
# Ambil domain dari konfigurasi yang sudah disiapkan installer utama.
if [[ -s /etc/xray/domain ]]; then
    domain=$(tr -d '[:space:]' < /etc/xray/domain)
elif [[ -s /root/domain ]]; then
    domain=$(tr -d '[:space:]' < /root/domain)
else
    echo "[ERROR] File domain tidak ditemukan: /etc/xray/domain atau /root/domain"
    echo "Siapkan domain terlebih dahulu sebelum menjalankan installer ini."
    exit 1
fi

if [[ ! "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
    echo "[ERROR] Format domain tidak valid: $domain"
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
    echo "[ERROR] Nginx belum terpasang. Pasang/siapkan Nginx terlebih dahulu."
    exit 1
fi
sleep 0.5
mkdir -p /etc/xray
echo -e "[ ${GREEN}INFO${NC} ] Checking... "
apt install iptables iptables-persistent -y
sleep 0.5
echo -e "[ ${GREEN}INFO$NC ] Setting ntpdate"
ntpdate pool.ntp.org
timedatectl set-ntp true
sleep 0.5
echo -e "[ ${GREEN}INFO$NC ] Install and enable chrony"
apt-get update
apt-get install -y chrony
systemctl enable --now chrony
timedatectl set-timezone Asia/Jakarta
sleep 0.5
echo -e "[ ${GREEN}INFO$NC ] Setting chrony tracking"
chronyc sourcestats -v
chronyc tracking -v
echo -e "[ ${GREEN}INFO$NC ] Setting dll"
apt clean all && apt update
apt install curl socat xz-utils wget apt-transport-https gnupg gnupg2 gnupg1 dnsutils lsb-release -y
apt install socat cron bash-completion ntpdate -y
ntpdate pool.ntp.org
apt -y install chrony
apt install zip -y
apt install curl pwgen openssl netcat cron -y


# ==============================
# INSTALL XRAY CORE
# ==============================

sleep 0.5
echo -e "[ ${GREEN}INFO$NC ] Downloading & Installing Xray Core"

# Runtime directory
mkdir -p /run/xray
chown www-data:www-data /run/xray
chmod 755 /run/xray

# Xray configuration directory
mkdir -p /etc/xray
chmod 755 /etc/xray

# Xray log directory
mkdir -p /var/log/xray
touch /var/log/xray/access.log
touch /var/log/xray/error.log
touch /var/log/xray/access2.log
touch /var/log/xray/error2.log

chown -R www-data:www-data /var/log/xray
chmod 755 /var/log/xray
chmod 644 /var/log/xray/*.log

# Install Xray Core
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u www-data

# Enable Xray at boot
systemctl daemon-reload
systemctl enable xray

# Check installation
systemctl status xray --no-pager -l

## Sertifikat TLS
# Nginx hanya dihentikan sementara untuk challenge standalone.
# Trap memastikan Nginx dinyalakan kembali jika penerbitan gagal/terinterupsi.
mkdir -p /root/.acme.sh /etc/xray

if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl -fsSL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh \
        -o /root/.acme.sh/acme.sh
    chmod 700 /root/.acme.sh/acme.sh
fi

/root/.acme.sh/acme.sh --upgrade --auto-upgrade
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

NGINX_WAS_ACTIVE=0
if systemctl is-active --quiet nginx; then
    NGINX_WAS_ACTIVE=1
    systemctl stop nginx
fi

restore_nginx_after_issue() {
    if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start nginx
    fi
}
trap restore_nginx_after_issue EXIT

if ! /root/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256; then
    echo "[ERROR] Gagal menerbitkan sertifikat untuk $domain"
    exit 1
fi

restore_nginx_after_issue
trap - EXIT

if ! /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
    --fullchain-file /etc/xray/xray.crt \
    --key-file /etc/xray/xray.key \
    --reloadcmd "systemctl restart xray"; then
    echo "[ERROR] Gagal memasang sertifikat ke /etc/xray/"
    exit 1
fi

chown root:www-data /etc/xray/xray.key /etc/xray/xray.crt
chmod 640 /etc/xray/xray.key
chmod 644 /etc/xray/xray.crt

# Renewal harian: Nginx hanya dihentikan oleh hook saat sertifikat memang perlu diperbarui.
cat > /usr/local/bin/ssl_renew.sh <<'RENEW_EOF'
#!/bin/bash
set -o pipefail

LOG=/root/renew_ssl.log
ACME=/root/.acme.sh/acme.sh
NGINX_WAS_ACTIVE=0

if systemctl is-active --quiet nginx; then
    NGINX_WAS_ACTIVE=1
fi

restore_nginx() {
    if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start nginx
    fi
}
trap restore_nginx EXIT

if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then
    "$ACME" --cron --home /root/.acme.sh \
        --pre-hook "systemctl stop nginx" \
        --post-hook "systemctl start nginx" \
        --renew-hook "systemctl restart xray" >> "$LOG" 2>&1
else
    "$ACME" --cron --home /root/.acme.sh \
        --renew-hook "systemctl restart xray" >> "$LOG" 2>&1
fi
RENEW_EOF

chmod 700 /usr/local/bin/ssl_renew.sh
if ! crontab -l 2>/dev/null | grep -qF '/usr/local/bin/ssl_renew.sh'; then
    (crontab -l 2>/dev/null; echo "15 03 * * * /usr/local/bin/ssl_renew.sh") | crontab -
fi

mkdir -p /home/vps/public_html

# set uuid
uuid=$(cat /proc/sys/kernel/random/uuid)
# xray config
cat > /etc/xray/config.json << END
{
  "log" : {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "info"
  },
  "inbounds": [
      {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    },
   {
     "listen": "127.0.0.1",
     "port": "14016",
     "protocol": "vless",
      "settings": {
          "decryption":"none",
            "clients": [
               {
                 "id": "${uuid}"
#vless
             }
          ]
       },
       "streamSettings":{
         "network": "ws",
            "wsSettings": {
                "path": "/vless"
          }
        }
     },
    {
     "listen": "127.0.0.1",
     "port": "23456",
     "protocol": "vmess",
      "settings": {
            "clients": [
               {
                 "id": "${uuid}",
                 "alterId": 0
#vmess
             }
          ]
       },
       "streamSettings":{
         "network": "ws",
            "wsSettings": {
                "path": "/vmess"
          }
        }
     },
    {
     "listen": "127.0.0.1",
     "port": "28406",
     "protocol": "vmess",
      "settings": {
            "clients": [
               {
                 "id": "${uuid}",
                 "alterId": 0
#vmess
             }
          ]
       },
       "streamSettings":{
         "network": "ws",
            "wsSettings": {
                "path": "/api/v1/token/hetoken"
          }
        }
     },
    {
      "listen": "127.0.0.1",
      "port": "25432",
      "protocol": "trojan",
      "settings": {
          "decryption":"none",
           "clients": [
              {
                 "password": "${uuid}"
#trojanws
              }
          ],
         "udp": true
       },
       "streamSettings":{
           "network": "ws",
           "wsSettings": {
               "path": "/trojan-ws"
            }
         }
     },
    {
        "listen": "127.0.0.1",
        "port": "30300",
        "protocol": "shadowsocks",
        "settings": {
           "clients": [
           {
           "method": "aes-128-gcm",
          "password": "${uuid}"
#ssws
           }
          ],
          "network": "tcp,udp"
       },
       "streamSettings":{
          "network": "ws",
             "wsSettings": {
               "path": "/ss-ws"
           }
        }
     },
      {
        "listen": "127.0.0.1",
     "port": "24456",
        "protocol": "vless",
        "settings": {
         "decryption":"none",
           "clients": [
             {
               "id": "${uuid}"
#vlessgrpc
             }
          ]
       },
          "streamSettings":{
             "network": "grpc",
             "grpcSettings": {
                "serviceName": "vless-grpc"
           }
        }
     },
     {
      "listen": "127.0.0.1",
     "port": "31234",
     "protocol": "vmess",
      "settings": {
            "clients": [
               {
                 "id": "${uuid}",
                 "alterId": 0
#vmessgrpc
             }
          ]
       },
       "streamSettings":{
         "network": "grpc",
            "grpcSettings": {
                "serviceName": "vmess-grpc"
          }
        }
     },
     {
        "listen": "127.0.0.1",
     "port": "33456",
        "protocol": "trojan",
        "settings": {
          "decryption":"none",
             "clients": [
               {
                 "password": "${uuid}"
#trojangrpc
               }
           ]
        },
         "streamSettings":{
         "network": "grpc",
           "grpcSettings": {
               "serviceName": "trojan-grpc"
         }
      }
   },
   {
    "listen": "127.0.0.1",
    "port": "30310",
    "protocol": "shadowsocks",
    "settings": {
        "clients": [
          {
             "method": "aes-128-gcm",
             "password": "${uuid}"
#ssgrpc
           }
         ],
           "network": "tcp,udp"
      },
    "streamSettings":{
     "network": "grpc",
        "grpcSettings": {
           "serviceName": "ss-grpc"
          }
       }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "blocked"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ]
      }
    ]
  },
  "stats": {},
  "api": {
    "services": [
      "StatsService"
    ],
    "tag": "api"
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink" : true,
      "statsOutboundDownlink" : true
    }
  }
}
END
rm -rf /etc/systemd/system/xray.service.d
rm -rf /etc/systemd/system/xray@.service
cat <<EOF> /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=www-data
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target

EOF
cat > /etc/systemd/system/runn.service <<EOF
[Unit]
Description=rmblvpn
After=network.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/mkdir -p /var/run/xray
ExecStart=/usr/bin/chown www-data:www-data /var/run/xray
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Nginx config: simpan konfigurasi lama agar bisa dipulihkan jika tes gagal.
if [[ -f /etc/nginx/conf.d/xray.conf ]]; then
    cp -a /etc/nginx/conf.d/xray.conf /etc/nginx/conf.d/xray.conf.bak
fi

#nginx config
cat >/etc/nginx/conf.d/xray.conf <<EOF
    server {
             listen 80;
             listen [::]:80;
             listen 7788;
             listen [::]:7788;
             listen 8181;
             listen [::]:8181;
             listen 8282;
             listen [::]:8282;
             listen 443 ssl http2 reuseport;
             listen [::]:443 ssl http2 reuseport;
             server_name $domain;
             ssl_certificate /etc/xray/xray.crt;
             ssl_certificate_key /etc/xray/xray.key;
             ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+ECDSA+AES128:EECDH+aRSA+AES128:RSA+AES128:EECDH+ECDSA+AES256:EECDH+aRSA+AES256:RSA+AES256:EECDH+ECDSA+3DES:EECDH+aRSA+3DES:RSA+3DES:!MD5;
             ssl_protocols TLSv1.2 TLSv1.3;
             root /home/vps/public_html;
        }
EOF
# Tambahkan location /vless
sed -i '$ ilocation ~ /vless {' /etc/nginx/conf.d/xray.conf
sed -i '$ iif ($http_upgrade != "Websocket") {' /etc/nginx/conf.d/xray.conf
sed -i '$ irewrite /(.*) /vless break;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_pass http://127.0.0.1:14016;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_http_version 1.1;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Upgrade \$http_upgrade;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Connection "upgrade";' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

# Tambahkan location /vmess
sed -i '$ ilocation ~ /vmess {' /etc/nginx/conf.d/xray.conf
sed -i '$ iif ($http_upgrade != "Websocket") {' /etc/nginx/conf.d/xray.conf
sed -i '$ irewrite /(.*) /vmess break;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_pass http://127.0.0.1:23456;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_http_version 1.1;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Upgrade \$http_upgrade;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Connection "upgrade";' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

# Tambahkan location /trojan-ntls
sed -i '$ ilocation ~ /trojan-ntls {' /etc/nginx/conf.d/xray.conf
sed -i '$ iif ($http_upgrade != "Websocket") {' /etc/nginx/conf.d/xray.conf
sed -i '$ irewrite /(.*) /trojan-ntls break;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_pass http://127.0.0.1:25431;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_http_version 1.1;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Upgrade \$http_upgrade;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Connection "upgrade";' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

# Tambahkan location /trojan-ws
sed -i '$ ilocation ~ /trojan-ws {' /etc/nginx/conf.d/xray.conf
sed -i '$ iif ($http_upgrade != "Websocket") {' /etc/nginx/conf.d/xray.conf
sed -i '$ irewrite /(.*) /trojan-ws break;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_pass http://127.0.0.1:25432;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_http_version 1.1;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Upgrade \$http_upgrade;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Connection "upgrade";' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

sed -i '$ ilocation = /ss-ws' /etc/nginx/conf.d/xray.conf
sed -i '$ i{' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_pass http://127.0.0.1:30300;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_http_version 1.1;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Upgrade \$http_upgrade;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Connection "upgrade";' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

sed -i '$ ilocation /' /etc/nginx/conf.d/xray.conf
sed -i '$ i{' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_pass http://127.0.0.1:700;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_http_version 1.1;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Upgrade \$http_upgrade;' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Connection "upgrade";' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

sed -i '$ ilocation ^~ /vless-grpc' /etc/nginx/conf.d/xray.conf
sed -i '$ i{' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_pass grpc://127.0.0.1:24456;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

sed -i '$ ilocation ^~ /vmess-grpc' /etc/nginx/conf.d/xray.conf
sed -i '$ i{' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_pass grpc://127.0.0.1:31234;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

sed -i '$ ilocation ^~ /trojan-grpc' /etc/nginx/conf.d/xray.conf
sed -i '$ i{' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_pass grpc://127.0.0.1:33456;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

sed -i '$ ilocation ^~ /ss-grpc' /etc/nginx/conf.d/xray.conf
sed -i '$ i{' /etc/nginx/conf.d/xray.conf
sed -i '$ iproxy_redirect off;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header X-Real-IP \$remote_addr;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_set_header Host \$http_host;' /etc/nginx/conf.d/xray.conf
sed -i '$ igrpc_pass grpc://127.0.0.1:30310;' /etc/nginx/conf.d/xray.conf
sed -i '$ i}' /etc/nginx/conf.d/xray.conf

echo -e "$ORANGE[SERVICE]$NC Restart All service"
systemctl daemon-reload
sleep 0.5
echo -e "[ ${GREEN}ok${NC} ] Enable & restart xray "
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

if nginx -t; then
    systemctl enable nginx
    systemctl restart nginx
else
    echo "[ERROR] Konfigurasi Nginx tidak valid. Memulihkan konfigurasi sebelumnya."
    if [[ -f /etc/nginx/conf.d/xray.conf.bak ]]; then
        cp -a /etc/nginx/conf.d/xray.conf.bak /etc/nginx/conf.d/xray.conf
    else
        rm -f /etc/nginx/conf.d/xray.conf
    fi
    nginx -t || true
    exit 1
fi

systemctl enable runn
systemctl restart runn

sleep 0.5
yellow() { echo -e "\\033[33;1m${*}\\033[0m"; }
yellow "xray/Vmess"
yellow "xray/Vless"

if [[ -f /root/domain ]]; then mv /root/domain /etc/xray/domain; fi
if [ -f /root/scdomain ];then
rm /root/scdomain > /dev/null 2>&1
fi
clear
rm -f ins-xray.sh
