#!/bin/bash
set -e

INSTALL_DIR="/opt/wg-captive"
BIN="/usr/local/bin/wg-captive"
DNSMASQ_CONF="/etc/dnsmasq.d/wg-captive.conf"

CONTAINER="${CONTAINER:-wg-easy}"
DNS_IP="${DNS_IP:-}"
PORTAL_IP="${PORTAL_IP:-}"

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

if [ -z "$DNS_IP" ]; then
  echo "ERROR: DNS_IP is required"
  echo "Example:"
  echo "CONTAINER=wg-easy DNS_IP=172.17.0.1 PORTAL_IP=2.26.96.22 bash <(curl -Ls ...)"
  exit 1
fi

if [ -z "$PORTAL_IP" ]; then
  echo "ERROR: PORTAL_IP is required"
  echo "Example:"
  echo "CONTAINER=wg-easy DNS_IP=172.17.0.1 PORTAL_IP=2.26.96.22 bash <(curl -Ls ...)"
  exit 1
fi

apt update
apt install -y curl dnsmasq dnsutils

mkdir -p "$INSTALL_DIR"
mkdir -p /etc/dnsmasq.d

cat > "$DNSMASQ_CONF" <<EOF
listen-address=$DNS_IP
bind-interfaces

server=1.1.1.1
server=8.8.8.8

address=/connectivitycheck.gstatic.com/$PORTAL_IP
address=/clients3.google.com/$PORTAL_IP

address=/captive.apple.com/$PORTAL_IP
address=/www.apple.com/$PORTAL_IP

address=/msftconnecttest.com/$PORTAL_IP
address=/www.msftconnecttest.com/$PORTAL_IP

address=/detectportal.firefox.com/$PORTAL_IP
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

cat > "$INSTALL_DIR/config" <<EOF
CONTAINER="$CONTAINER"
DNS_IP="$DNS_IP"
PORTAL_IP="$PORTAL_IP"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
DNSMASQ_CONF="$DNSMASQ_CONF"
EOF

cat > "$BIN" <<'EOF'
#!/bin/bash
set -e

INSTALL_DIR="/opt/wg-captive"
BLOCKED_FILE="$INSTALL_DIR/blocked-ips.txt"
BACKUP_DIR="$INSTALL_DIR/backups"

[ -f "$INSTALL_DIR/config" ] && source "$INSTALL_DIR/config"

CONTAINER="${CONTAINER:-wg-easy}"
DNS_IP="${DNS_IP:-}"
PORTAL_IP="${PORTAL_IP:-}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.d/wg-captive.conf}"

WALLED_DOMAINS="wa.me api.whatsapp.com whatsapp.com whatsapp.net zalo.me zaloapp.com zaloapp.com.vn"

mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"
touch "$BLOCKED_FILE"

run_ct() {
  docker exec "$CONTAINER" sh -c "$1"
}

resolve_walled_ips() {
  for D in $WALLED_DOMAINS; do
    dig +short A "$D" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
  done | sort -u
}

init_chain() {
  run_ct "iptables -N WG_EXPIRED 2>/dev/null || true"
  run_ct "iptables -C FORWARD -j WG_EXPIRED 2>/dev/null || iptables -I FORWARD -j WG_EXPIRED"
}

clear_rules() {
  run_ct "while iptables -D FORWARD -j WG_EXPIRED 2>/dev/null; do :; done"
  run_ct "iptables -F WG_EXPIRED 2>/dev/null || true"
  run_ct "iptables -X WG_EXPIRED 2>/dev/null || true"

  run_ct "
while iptables -t nat -S PREROUTING | grep -q 'WG_CAPTIVE'; do
  RULE=\$(iptables -t nat -S PREROUTING | grep 'WG_CAPTIVE' | head -n1 | sed 's/^-A PREROUTING/-D PREROUTING/')
  iptables -t nat \$RULE
done
"
}

apply_one() {
  IP="$1"

  WG_IPS="$(resolve_walled_ips | tr '\n' ' ')"

  run_ct "
iptables -A WG_EXPIRED -s $IP -d $DNS_IP -p udp --dport 53 -j ACCEPT
iptables -A WG_EXPIRED -s $IP -d $DNS_IP -p tcp --dport 53 -j ACCEPT

iptables -A WG_EXPIRED -s $IP -d $PORTAL_IP -j ACCEPT

for DIP in $WG_IPS; do
  iptables -A WG_EXPIRED -s $IP -d \$DIP -j ACCEPT
done

iptables -A WG_EXPIRED -s $IP -p tcp --dport 853 -j REJECT
iptables -A WG_EXPIRED -s $IP -p udp --dport 853 -j REJECT

iptables -A WG_EXPIRED -s $IP -j REJECT

iptables -t nat -A PREROUTING -s $IP -p udp --dport 53 -m comment --comment WG_CAPTIVE -j DNAT --to-destination $DNS_IP:53
iptables -t nat -A PREROUTING -s $IP -p tcp --dport 53 -m comment --comment WG_CAPTIVE -j DNAT --to-destination $DNS_IP:53
iptables -t nat -A PREROUTING -s $IP -p tcp --dport 80 -m comment --comment WG_CAPTIVE -j DNAT --to-destination $PORTAL_IP:80
"
}

apply_all() {
  init_chain

  while read -r IP; do
    [ -z "$IP" ] && continue
    echo "$IP" | grep -q '^#' && continue
    apply_one "$IP"
  done < "$BLOCKED_FILE"
}

block_ip() {
  IP="$1"

  if [ -z "$IP" ]; then
    echo "Usage: wg-captive block <ip>"
    exit 1
  fi

  grep -qxF "$IP" "$BLOCKED_FILE" || echo "$IP" >> "$BLOCKED_FILE"

  clear_rules
  apply_all

  echo "Blocked: $IP"
}

unblock_ip() {
  IP="$1"

  if [ -z "$IP" ]; then
    echo "Usage: wg-captive unblock <ip>"
    exit 1
  fi

  sed -i "\|^$IP$|d" "$BLOCKED_FILE"

  clear_rules
  apply_all

  echo "Unblocked: $IP"
}

list_ips() {
  echo "Blocked IPs:"
  cat "$BLOCKED_FILE"
}

status_rules() {
  echo "=== Config ==="
  cat "$INSTALL_DIR/config" 2>/dev/null || true

  echo
  echo "=== Blocked IPs ==="
  cat "$BLOCKED_FILE"

  echo
  echo "=== WG_EXPIRED ==="
  docker exec "$CONTAINER" iptables -S WG_EXPIRED 2>/dev/null || true

  echo
  echo "=== NAT PREROUTING WG_CAPTIVE ==="
  docker exec "$CONTAINER" iptables -t nat -S PREROUTING | grep WG_CAPTIVE || true

  echo
  echo "=== Walled Garden Domains ==="
  echo "$WALLED_DOMAINS"

  echo
  echo "=== Resolved Walled Garden IPs ==="
  resolve_walled_ips || true
}

backup_ips() {
  DATE="$(date +%Y-%m-%d_%H-%M-%S)"
  HOSTNAME_NOW="$(hostname)"
  PUBLIC_IP="$(curl -4 -s https://api.ipify.org || echo unknown)"
  BACKUP_FILE="$BACKUP_DIR/blocked-ips-$DATE.txt"

  cp "$BLOCKED_FILE" "$BACKUP_FILE"

  find "$BACKUP_DIR" \
    -type f \
    -name "blocked-ips-*.txt" \
    -mtime +14 \
    -delete

  COUNT="$(grep -v '^#' "$BLOCKED_FILE" | grep -v '^$' | wc -l)"

  echo "Backup created: $BACKUP_FILE"
  echo "Blocked IPs: $COUNT"

  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo "Telegram not configured"
    exit 0
  fi

  curl -s -X POST \
    "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" \
    -F chat_id="$TG_CHAT_ID" \
    -F document=@"$BACKUP_FILE" \
    -F caption="WG Captive Backup

Host: $HOSTNAME_NOW
Server IP: $PUBLIC_IP
Time: $DATE
Blocked IPs: $COUNT" >/dev/null

  echo "Backup sent to Telegram: $BACKUP_FILE"
}

restore_ips() {
  RESTORE_FILE="$1"

  if [ -z "$RESTORE_FILE" ]; then
    echo "Usage: wg-captive restore <backup-file>"
    exit 1
  fi

  if [ ! -f "$RESTORE_FILE" ]; then
    echo "File not found: $RESTORE_FILE"
    exit 1
  fi

  cp "$RESTORE_FILE" "$BLOCKED_FILE"

  clear_rules
  apply_all

  echo "Restored from: $RESTORE_FILE"
}

refresh_walled() {
  clear_rules
  apply_all
  echo "Walled garden IPs refreshed"
  resolve_walled_ips
}

uninstall_self() {
  echo "Removing wg-captive..."

  clear_rules || true

  systemctl disable --now wg-captive.service 2>/dev/null || true
  systemctl disable --now wg-captive-backup.timer 2>/dev/null || true
  systemctl disable --now wg-captive-walled.timer 2>/dev/null || true
  systemctl stop wg-captive-backup.service 2>/dev/null || true
  systemctl stop wg-captive-walled.service 2>/dev/null || true

  rm -f /etc/systemd/system/wg-captive.service
  rm -f /etc/systemd/system/wg-captive-backup.service
  rm -f /etc/systemd/system/wg-captive-backup.timer
  rm -f /etc/systemd/system/wg-captive-walled.service
  rm -f /etc/systemd/system/wg-captive-walled.timer

  systemctl daemon-reload

  rm -f "$DNSMASQ_CONF"
  systemctl restart dnsmasq 2>/dev/null || true

  rm -f /usr/local/bin/wg-captive
  rm -rf /opt/wg-captive

  echo "wg-captive removed completely"
}

case "$1" in
  block)
    block_ip "$2"
    ;;

  unblock)
    unblock_ip "$2"
    ;;

  list)
    list_ips
    ;;

  apply)
    clear_rules
    apply_all
    echo "Rules applied"
    ;;

  clear)
    clear_rules
    echo "Rules cleared"
    ;;

  status)
    status_rules
    ;;

  backup)
    backup_ips
    ;;

  restore)
    restore_ips "$2"
    ;;

  refresh-walled)
    refresh_walled
    ;;

  uninstall)
    uninstall_self
    ;;

  *)
    echo "Usage:"
    echo "  wg-captive block <ip>"
    echo "  wg-captive unblock <ip>"
    echo "  wg-captive list"
    echo "  wg-captive apply"
    echo "  wg-captive clear"
    echo "  wg-captive status"
    echo "  wg-captive backup"
    echo "  wg-captive restore <file>"
    echo "  wg-captive refresh-walled"
    echo "  wg-captive uninstall"
    exit 1
    ;;
esac
EOF

chmod +x "$BIN"
touch "$INSTALL_DIR/blocked-ips.txt"

cat > /etc/systemd/system/wg-captive.service <<EOF
[Unit]
Description=Restore WG Captive Rules
After=docker.service dnsmasq.service
Requires=docker.service dnsmasq.service

[Service]
Type=oneshot
ExecStart=$BIN apply

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/wg-captive-backup.service <<EOF
[Unit]
Description=Backup WG Captive blocked IPs

[Service]
Type=oneshot
ExecStart=$BIN backup
EOF

cat > /etc/systemd/system/wg-captive-backup.timer <<EOF
[Unit]
Description=Daily WG Captive Backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/wg-captive-walled.service <<EOF
[Unit]
Description=Refresh WG Captive Walled Garden IP Rules
After=docker.service dnsmasq.service
Requires=docker.service dnsmasq.service

[Service]
Type=oneshot
ExecStart=$BIN refresh-walled

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/wg-captive-walled.timer <<EOF
[Unit]
Description=Refresh WG Captive Walled Garden IP Rules

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

systemctl enable wg-captive.service
systemctl enable wg-captive-backup.timer
systemctl enable wg-captive-walled.timer

systemctl start wg-captive-backup.timer
systemctl start wg-captive-walled.timer

wg-captive refresh-walled || true

echo
echo "Installed wg-captive"
echo
echo "Config:"
echo "  CONTAINER=$CONTAINER"
echo "  DNS_IP=$DNS_IP"
echo "  PORTAL_IP=$PORTAL_IP"
echo "  DNSMASQ_CONF=$DNSMASQ_CONF"
echo
echo "Commands:"
echo "  wg-captive block 10.8.0.2"
echo "  wg-captive unblock 10.8.0.2"
echo "  wg-captive list"
echo "  wg-captive status"
echo "  wg-captive apply"
echo "  wg-captive clear"
echo "  wg-captive backup"
echo "  wg-captive restore <file>"
echo "  wg-captive refresh-walled"
echo "  wg-captive uninstall"
