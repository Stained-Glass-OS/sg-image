# What the project server keeps

freesoft.page serves the website, the apt repository, the ISOs, the time zone lookup and the problem report receiver. Stained Glass doesn't track the people who use it, and this is everything the server records about them. The configuration it describes is `server/Caddyfile`, `server/reports/report-receiver.py` and `server/stats/sg-iso-count`.

## ISO downloads: a count, and nothing else

Caddy writes one line for each request for an ISO file (`/iso/*.iso`) to `/var/log/caddy/iso.log`. A line holds the time, the file name, the HTTP status and the number of bytes sent. Caddy deletes the address, port, host and headers before the line is written (the `format filter` in the Caddyfile). Requests for anything else, the website and the apt repository included, are not logged at all (`skip_log`).

Every hour, `sg-iso-count` (sg-iso-count.timer) adds those lines into a daily total and empties the log, so no line is kept longer than an hour. What's left is `/var/lib/sg-stats/iso-downloads.tsv`, one line per UTC day:

    date  requests  bytes  downloads

`downloads` is the bytes sent divided by the newest ISO's size. One download can take several requests (download managers, resumed downloads), and an abandoned one sends only part of the file, so whole ISOs' worth of bytes is the honest count. It's an estimate. `sg-iso-count --show` prints the table with a total.

## Time zone lookups

"Set time zone automatically" (sg-timezone-auto) asks `/api/timezone` which zone the computer is in. The receiver looks up the caller's address in DB-IP's city database and answers. The address is held in memory only, for the limit of 60 lookups a day, and is never written to a file or a log. Since 2026-11-14 the receiver writes no access log at all. Before that, its system log kept the address and request line of each lookup; that log was purged on 2026-11-14.

## Problem reports

A report someone sends with Report a problem is kept with the sender's address, for the per-address limits and for blocking abuse (see the top of `report-receiver.py`). It's published on the website without the address. This is the one place an address is kept, and only when someone chooses to send a report.

## Not kept

- No access logs for the website, the apt repository, the ISO listings or the API.
- No cookies, analytics or third-party scripts on the website.
- Installed systems send nothing on their own except the time zone lookup above, and only while "Set time zone automatically" is on or the zone is still UTC. Apt fetches updates like any Debian system, and those requests aren't logged.

Deployed by `server/reports/deploy.sh`.
