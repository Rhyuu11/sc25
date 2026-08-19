#!/bin/bash
biji=`date +"%Y-%m-%d" -d "$dateFromServer"`
colornow=$(cat /etc/rmbl/theme/color.conf)
NC="\e[0m"
RED="\033[0;31m"
COLOR1="$(cat /etc/rmbl/theme/$colornow | grep -w "TEXT" | cut -d: -f2|sed 's/ //g')"
COLBG1="$(cat /etc/rmbl/theme/$colornow | grep -w "BG" | cut -d: -f2|sed 's/ //g')"
WH='\033[1;37m'
# Network/license-check values
# Do not stop nginx when a public-IP or license-server request temporarily fails.
ipsaya=$(curl -4 -fsS --max-time 10 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')
data_ip="https://raw.githubusercontent.com/Rhyuu11/izinsc/main/ip"

checking_sc() {
    # Validate public IPv4 response before using it in grep.
    if [[ ! "$ipsaya" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "${COLOR1}[ WARNING ] ${WH}Gagal mendapatkan IPv4 publik."
        echo -e "${COLOR1}[ WARNING ] ${WH}Nginx tidak dihentikan. Coba lagi nanti."
        return 1
    fi

    # Use the local system date instead of parsing Google's Date header.
    date_list=$(date +"%Y-%m-%d")
    if [[ ! "$date_list" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo -e "${COLOR1}[ WARNING ] ${WH}Tanggal sistem tidak valid."
        echo -e "${COLOR1}[ WARNING ] ${WH}Nginx tidak dihentikan."
        return 1
    fi

    # Fetch the authorization list safely. A network failure must not
    # be treated as a banned/expired VPS.
    license_data=$(curl -4 -fsS --max-time 15 "$data_ip" 2>/dev/null)
    if [[ $? -ne 0 || -z "$license_data" ]]; then
        echo -e "${COLOR1}[ WARNING ] ${WH}Server izin tidak dapat dihubungi."
        echo -e "${COLOR1}[ WARNING ] ${WH}Nginx tidak dihentikan. Coba lagi nanti."
        return 1
    fi

    useexp=$(printf '%s\n' "$license_data" | awk -v ip="$ipsaya" '$0 ~ ip {print $3; exit}')

    # Missing/invalid expiry is a failed lookup, not proof of a ban.
    if [[ -z "$useexp" || ! "$useexp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo -e "${COLOR1}[ WARNING ] ${WH}IP VPS tidak ditemukan pada server izin."
        echo -e "${COLOR1}[ WARNING ] ${WH}Nginx tidak dihentikan."
        return 1
    fi

    if [[ "$date_list" < "$useexp" || "$date_list" == "$useexp" ]]; then
        return 0
    fi

    # Only a confirmed expired authorization reaches this branch.
    systemctl stop nginx
    echo -e "$COLOR1┌─────────────────────────────────────────────────┐${NC}"
    echo -e "$COLOR1│${NC}${COLBG1}          ${WH}• AUTOSCRIPT PREMIUM •                 ${NC}$COLOR1│ $NC"
    echo -e "$COLOR1└─────────────────────────────────────────────────┘${NC}"
    echo -e "$COLOR1┌─────────────────────────────────────────────────┐${NC}"
    echo -e "$COLOR1│            ${RED}PERMISSION DENIED !${NC}                  $COLOR1│"
    echo -e "$COLOR1│   ${yl}Your VPS${NC} $ipsaya \033[0;36mHas been Banned${NC}      $COLOR1│"
    echo -e "$COLOR1│     ${yl}Buy access permissions for scripts${NC}          $COLOR1│"
    echo -e "$COLOR1│             \033[0;32mContact Your Admin ${NC}                 $COLOR1│"
    echo -e "$COLOR1└─────────────────────────────────────────────────┘${NC}"
    exit
}
checking_sc
IP=$(curl -sS ipv4.icanhazip.com);
date=$(date +"%Y-%m-%d")
time=$(date +'%H:%M:%S')
domain=$(cat /etc/xray/domain)
token=$(cat /usr/bin/token)
id_chat=$(cat /usr/bin/idchat)
clear
sleep 1
echo -e "${COLOR1}[ INFO ] ${WH}Processing... "
mkdir -p /root/backup
echo -e "${COLOR1}[ INFO ] ${WH}Mohon Ditunggu... "
wget -O /root/backup/ipmini https://raw.githubusercontent.com/Rhyuu11/izinsc/main/ip &> /dev/null
cp -r /etc/passwd /root/backup/ &> /dev/null
cp -r /etc/group /root/backup/ &> /dev/null
cp -r /etc/shadow /root/backup/ &> /dev/null
cp -r /etc/gshadow /root/backup/ &> /dev/null
cp -r /usr/bin/idchat /root/backup/ &> /dev/null
cp -r /usr/bin/token /root/backup/ &> /dev/null
cp -r /etc/per/id /root/backup/ &> /dev/null
cp -r /etc/per/token /root/backup/token2 &> /dev/null
cp -r /etc/perlogin/id /root/backup/loginid &> /dev/null
cp -r /etc/perlogin/token /root/backup/logintoken &> /dev/null
cp -r /etc/xray/config.json /root/backup/xray &> /dev/null
cp -r /etc/xray/ssh /root/backup/ssh &> /dev/null
cp -r /home/vps/public_html /root/backup/public_html &> /dev/null
cp -r /etc/xray/sshx /root/backup/sshx &> /dev/null
cp -r /etc/vmess /root/backup/vmess &> /dev/null
cp -r /etc/vless /root/backup/vless &> /dev/null
cp -r /etc/trojan /root/backup/trojan &> /dev/null
cp -r /etc/issue.net /root/backup/issue &> /dev/null
cd /root
zip -r $IP.zip backup > /dev/null 2>&1
zip -r $IP-$date.zip backup > /dev/null 2>&1
rclone copy /root/$IP-$date.zip dr:backup/
url=$(rclone link dr:backup/$IP-$date.zip)
id=(`echo $url | grep '^https' | cut -d'=' -f2`)
link="https://drive.google.com/u/4/uc?id=${id}&export=download"
curl -F chat_id="$id_chat" -F document=@"$IP.zip" -F caption="Thank You For Using this Script
Domain : $domain
IP VPS : $IP
Date   : $date
Time   : $time WIB
Link Google : $link" https://api.telegram.org/bot$token/sendDocument &> /dev/null
rm -fr /root/backup &> /dev/null
rm -fr /root/user-backup &> /dev/null
rm -f /root/$NameUser.zip &> /dev/null
rm -r /root/$IP-$date.zip &> /dev/null
rm -f /root/$IP.zip &> /dev/null
echo " Please Check Your BOT"
echo -e ""
read -n 1 -s -r -p "Press any key to back on menu"
menu
