#!/usr/bin/python3
# The time zone lookup (report-receiver.py's timezone_of) with a stand-in
# for the IP database: places to their zones, by the nearest of the country's.
import importlib.machinery, importlib.util, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
l = importlib.machinery.SourceFileLoader("r", os.path.join(HERE, "report-receiver.py"))
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("r", l)); l.exec_module(m)
PLACES = {  # address -> (country, lat, lon, want)
    "1.0.0.1": ("US", 43.4, -123.3, "America/Los_Angeles"),   # Sutherlin, Oregon
    "1.0.0.2": ("US", 39.7, -105.0, "America/Denver"),
    "1.0.0.3": ("US", 33.4, -112.1, "America/Phoenix"),
    "1.0.0.4": ("US", 40.7, -74.0, "America/New_York"),
    "1.0.0.5": ("DE", 48.1, 11.6, "Europe/Berlin"),
    "1.0.0.6": ("AU", -33.9, 151.2, "Australia/Sydney"),
    "1.0.0.7": ("GB", None, None, "Europe/London"),
}
class Reader:
    def get(self, a):
        p = PLACES.get(a)
        if not p: return None
        r = {"country": {"iso_code": p[0]}}
        if p[1] is not None: r["location"] = {"latitude": p[1], "longitude": p[2]}
        return r
m.geo_reader = lambda: Reader()
bad = 0
for a, (cc, la, lo, want) in PLACES.items():
    got = m.timezone_of(a)
    ok = got and got[0] == want
    print("%s  %s -> %s" % ("PASS" if ok else "FAIL", want, got))
    bad += not ok
print("RESULT: %s" % ("PASS" if not bad else "FAIL"))
sys.exit(1 if bad else 0)
