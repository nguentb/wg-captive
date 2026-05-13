#!/bin/bash
set -e

INSTALL_DIR="/opt/wg-captive"
BIN="/usr/local/bin/wg-captive"

CONTAINER="${CONTAINER:-wg-easy}"
DNS_IP="${DNS_IP:-172.17.0.1}"
PORTAL_IP="${PORTAL_IP:-2.26.96.22}"

mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/config" <<EOF
CONTAINER="$CONTAINER"
DNS_IP="$DNS_IP"
PORTAL_IP="$PORTAL_IP"
EOF

cat > "$BIN" <<'EOF'
#!/bin/bash
set -e

INSTALL_DIR="/opt/wg-captive"
BLOCKED_FILE="$INSTALL_DIR/blocked-ips.txt"

[ -f "$INSTALL_DIR/config" ] && source "$INSTALL_DIR/config"

CONTAINER="${CONTAINER:-wg-easy}"
DNS_IP="${DNS_IP:-172.17.0.1}"
PORTAL_IP="${PORTAL_IP:-2.26.96.22}"

mkdir -p "$INSTALL_DIR"
touch "$BLOCKED_FILE"

run_ct() {
  docker exec "$CONTAINER" sh -c "$1"
}

init_chain() {
  run_ct "iptables -N WG_EXPIRED 2>/dev/null || true"
  run_ct "iptables -C FORWARD -j WG_EXPIRED 2>/dev/null || iptables -I FORWARD -j WG_EXPIRED"
}

clear_rules() {
  run_ct "while iptables -D FORWARD -j WG_EXPIRED 2>/dev/null; do :; done"
  run_ct "iptables -F WG_EXPIRED 2>/dev/null || true"
  run_ct "iptables -X WG_EXPIRED 2>/dev/null || true"

  run_ct "iptables -t nat -S PREROUTING | grep 'WG_CAPTIVE' | sed 's/^-A/iptables -t nat -D/' | sh 2>/dev/null || true"
}

apply_one() {
  IP="$1"

  run_ct "
iptables -A WG_EXPIRED -s $IP -d $DNS_IP -p udp --dport 53 -j ACCEPT
iptables -A WG_EXPIRED -s $IP -d $DNS_IP -p tcp --dport 53 -j ACCEPT
iptables -A WG_EXPIRED -s $IP -d $PORTAL_IP -j ACCEPT
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
  echo "=== WG_EXPIRED ==="
  docker exec "$CONTAINER" iptables -S WG_EXPIRED 2>/dev/null || true

  echo
  echo "=== NAT PREROUTING WG_CAPTIVE ==="
  docker exec "$CONTAINER" iptables -t nat -S PREROUTING | grep WG_CAPTIVE || true
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
  *)
    echo "Usage:"
    echo "  wg-captive block <ip>"
    echo "  wg-captive unblock <ip>"
    echo "  wg-captive list"
    echo "  wg-captive apply"
    echo "  wg-captive clear"
    echo "  wg-captive status"
    exit 1
    ;;
esac
EOF

chmod +x "$BIN"
touch "$INSTALL_DIR/blocked-ips.txt"

cat > /etc/systemd/system/wg-captive.service <<EOF
[Unit]
Description=Restore WG Captive Portal Rules
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$BIN apply

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wg-captive.service

echo "Installed wg-captive"
echo
echo "Config:"
echo "  CONTAINER=$CONTAINER"
echo "  DNS_IP=$DNS_IP"
echo "  PORTAL_IP=$PORTAL_IP"
echo
echo "Commands:"
echo "  wg-captive block 10.8.0.2"
echo "  wg-captive unblock 10.8.0.2"
echo "  wg-captive list"
echo "  wg-captive status"
echo "  wg-captive apply"
