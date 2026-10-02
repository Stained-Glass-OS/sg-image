#!/bin/sh
# The problem reports on freesoft.page.
#   reports.sh list [DAYS]     the newest reports (default: the last 2 days)
#   reports.sh show ID         one report
#   reports.sh fetch DIR       copy them all into DIR (rsync)
# Published too, without the sender's address: https://freesoft.page/reports/
# (index.json for agents).
set -eu
KEY=${SG_SERVER_KEY:-$HOME/.ssh/sg}
SERVER=${SG_SERVER:-root@freesoft.page}
DIR=/var/lib/sg-reports
case "${1:-list}" in
list) ssh -i "$KEY" -o BatchMode=yes "$SERVER" "find $DIR -name '*.txt' -mtime -${2:-2} -printf '%TY-%Tm-%Td %TH:%TM  %f  %s bytes\n' | sort -r | sed 's/\.txt  / /'" ;;
show) ssh -i "$KEY" -o BatchMode=yes "$SERVER" "cat $DIR/*/$2.txt" ;;
fetch) mkdir -p "$2"; rsync -a -e "ssh -i $KEY" "$SERVER:$DIR/" "$2/" ;;
*) echo "usage: reports.sh list [DAYS] | show ID | fetch DIR" >&2; exit 2 ;;
esac
