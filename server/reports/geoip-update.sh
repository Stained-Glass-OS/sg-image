#!/bin/sh
# The time zone lookup's data, refreshed (sg-geoip-update.timer, monthly):
# DB-IP's free city database (IP -> place; CC BY 4.0, "IP Geolocation by
# DB-IP", https://db-ip.com) and GeoNames' towns of 15,000 people with their
# zones (CC BY 4.0, https://www.geonames.org). Each is checked before it
# replaces the one in use; a failed download keeps the old.
set -eu
DIR=${SG_GEOIP_DIR:-/var/lib/sg-geoip}
mkdir -p "$DIR"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
got=
for m in "$(date -u +%Y-%m)" "$(date -u -d '-1 month' +%Y-%m)"; do
    if curl -fsS -o "$T/db.mmdb.gz" "https://download.db-ip.com/free/dbip-city-lite-$m.mmdb.gz"; then got=$m; break; fi
done
if [ -n "$got" ] && gunzip -f "$T/db.mmdb.gz" && \
   python3 -c 'import maxminddb,sys; r=maxminddb.open_database(sys.argv[1]); assert r.get("8.8.8.8")' "$T/db.mmdb"; then
    install -m 0644 "$T/db.mmdb" "$DIR/dbip-city-lite.mmdb.new" && mv -f "$DIR/dbip-city-lite.mmdb.new" "$DIR/dbip-city-lite.mmdb"
    echo "DB-IP city lite $got"
fi
if curl -fsS -o "$T/c.zip" https://download.geonames.org/export/dump/cities15000.zip && \
   python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); d=z.read("cities15000.txt"); assert d.count(b"\n") > 20000; open(sys.argv[2],"wb").write(d)' "$T/c.zip" "$T/cities.txt"; then
    install -m 0644 "$T/cities.txt" "$DIR/cities15000.txt.new" && mv -f "$DIR/cities15000.txt.new" "$DIR/cities15000.txt"
    echo "GeoNames cities15000"
fi
