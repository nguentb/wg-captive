# WG Captive

Captive portal system for WireGuard / WG Easy.

Block selected WireGuard client IPs and redirect them to a captive portal page for:
- expired subscriptions
- payment reminders
- restricted access

Designed for:
- WG Easy
- Docker WireGuard
- VPN Wi-Fi routers
- Captive portal style VPN networks

---

# Features

- Block specific WireGuard client IPs
- Redirect HTTP traffic to captive portal
- DNS hijack for captive detection
- Android / iPhone captive popup support
- Telegram automatic backup
- Restore blocked IP list after reboot
- Restore blocked IPs from backup
- Fully removable
- Works with WG Easy in Docker

---

# Requirements

- Ubuntu / Debian VPS
- Docker installed
- WG Easy running
- dnsmasq configured separately
- Captive portal web server

---

# Installation

## Basic install

```bash
CONTAINER=wg-easy \
DNS_IP=172.17.0.1 \
PORTAL_IP=2.26.96.22 \
bash <(curl -Ls https://raw.githubusercontent.com/nguentb/wg-captive/refs/heads/main/install.sh)
```
Install with Telegram backup
```
CONTAINER=wg-easy \
DNS_IP=x.x.x.x \
PORTAL_IP=x.x.x.x \
TG_BOT_TOKEN="YOUR_BOT_TOKEN" \
TG_CHAT_ID="YOUR_CHAT_ID" \
bash <(curl -Ls https://raw.githubusercontent.com/nguentb/wg-captive/refs/heads/main/install.sh)
```
Commands
Block IP
```
wg-captive block 10.8.0.2
```
Unblock IP
```
wg-captive unblock 10.8.0.2
```
List blocked IPs
```
wg-captive list
```
Show iptables status
```
wg-captive status
```
Re-apply all rules
```wg-captive apply```

Useful after:

container restart
docker restart
reboot

Clear all captive rules
```
wg-captive clear
```
Backup
Manual backup
```
wg-captive backup
```
Backups are stored in: /opt/wg-captive/backups

Automatic Telegram backup (If Telegram is configured):

backup runs daily at 03:00
blocked IP list is sent automatically to Telegram

Check timer:

systemctl status wg-captive-backup.timer
Restore

Restore blocked IP list from backup:
```wg-captive restore /opt/wg-captive/backups/blocked-ips-2026-05-14_03-00-00.txt```
Uninstall

Remove everything completely:

```wg-captive uninstall```

This removes:

iptables rules
systemd services
timers
backups
blocked IP lists
wg-captive binary
