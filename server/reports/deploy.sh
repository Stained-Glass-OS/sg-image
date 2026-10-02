#!/bin/sh
# Install (or update) the problem report receiver on freesoft.page and the
# Caddyfile that puts it at /api/report. Validates Caddy's configuration
# before reloading it; the old one is kept as Caddyfile.bak.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SSH="ssh -i ${SG_SERVER_KEY:-$HOME/.ssh/sg} -o BatchMode=yes ${SG_SERVER:-root@freesoft.page}"
$SSH 'mkdir -p /usr/local/lib/sg-report-receiver
id sgreports >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin sgreports
mkdir -p /srv/www/reports && chown sgreports:sgreports /srv/www/reports && chmod 755 /srv/www/reports'
$SSH 'cat > /usr/local/lib/sg-report-receiver/report-receiver.py' < "$HERE/report-receiver.py"
$SSH 'cat > /etc/systemd/system/sg-report-receiver.service' < "$HERE/sg-report-receiver.service"
$SSH 'cat > /usr/local/lib/sg-report-receiver/geoip-update.sh' < "$HERE/geoip-update.sh"
$SSH 'cat > /etc/systemd/system/sg-geoip-update.service' < "$HERE/sg-geoip-update.service"
$SSH 'cat > /etc/systemd/system/sg-geoip-update.timer' < "$HERE/sg-geoip-update.timer"
$SSH 'cat > /etc/caddy/Caddyfile.new' < "$HERE/../Caddyfile"
$SSH 'set -e
dpkg -s python3-maxminddb >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-maxminddb >/dev/null
systemctl daemon-reload
[ -s /var/lib/sg-geoip/dbip-city-lite.mmdb ] || systemctl start sg-geoip-update.service
systemctl enable --now sg-geoip-update.timer
systemctl enable --now sg-report-receiver.service
systemctl restart sg-report-receiver.service
caddy validate --config /etc/caddy/Caddyfile.new --adapter caddyfile >/dev/null
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile
systemctl reload caddy
systemctl is-active sg-report-receiver caddy'
