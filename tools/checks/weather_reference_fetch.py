"""Fetch independent UTC reference series for the weather fidelity check.

    python tools/checks/weather_reference_fetch.py

Writes core/weather/testdata/weather_events_ref.json: for each known extreme
weather event, the Open-Meteo historical archive (the reanalysis the game
itself loads) over a 48 h window, requested in UTC (timezone=GMT) so nothing
about time zones is shared with the game's own fetch. The in-game check
(tools/checks/weather_fidelity_check.gd) parks the clock on every hour of each
window and compares what the game reads with these values.

Standard library only. Network: archive-api.open-meteo.com (no key).
"""
import json
import os
import sys
import time
import urllib.request

VARS = ["temperature_2m", "precipitation", "wind_speed_10m", "cloud_cover",
        "shortwave_radiation"]

# id, site, lat, lon, first UTC day, last UTC day, what happened
EVENTS = [
    ("mtv_heat_dome", "Mount Vernon WA", 48.3252, -122.2469, "2021-06-27", "2021-06-28",
     "Pacific Northwest heat dome"),
    ("mtv_atmos_river", "Mount Vernon WA", 48.3252, -122.2469, "2021-11-14", "2021-11-15",
     "Skagit atmospheric river and flood"),
    ("mtv_arctic", "Mount Vernon WA", 48.3252, -122.2469, "2022-12-21", "2022-12-22",
     "December 2022 arctic outbreak"),
    ("walton_ice", "Walton OR", 44.0113, -123.5911, "2024-01-13", "2024-01-14",
     "January 2024 Willamette Valley ice storm"),
    ("walton_heat", "Walton OR", 44.0113, -123.5911, "2021-06-27", "2021-06-28",
     "Pacific Northwest heat dome"),
    ("bb_hilary", "Bombay Beach CA", 33.3560, -115.7266, "2023-08-20", "2023-08-21",
     "Tropical Storm Hilary rain"),
    ("bb_wind", "Bombay Beach CA", 33.3560, -115.7266, "2024-04-14", "2024-04-15",
     "Spring wind event (the dust storm hours)"),
    ("bb_winter", "Bombay Beach CA", 33.3560, -115.7266, "2024-01-15", "2024-01-16",
     "Winter day (standard time vs the archive offset)"),
    ("bb_leap", "Bombay Beach CA", 33.3560, -115.7266, "2024-02-28", "2024-03-01",
     "Across Feb 29 2024"),
    ("brc_rain", "Black Rock City NV", 40.7871, -119.2025, "2023-09-01", "2023-09-02",
     "Burning Man 2023 rain"),
    ("eden_ciaran", "Eden Project UK", 50.3613, -4.7444, "2023-11-01", "2023-11-02",
     "Storm Ciaran"),
    ("madrid_filomena", "Madrid ES", 40.4168, -3.7038, "2021-01-08", "2021-01-09",
     "Storm Filomena snow"),
    ("houston_harvey", "Houston TX", 29.7604, -95.3698, "2017-08-26", "2017-08-27",
     "Hurricane Harvey rain"),
    ("houston_freeze", "Houston TX", 29.7604, -95.3698, "2021-02-15", "2021-02-16",
     "February 2021 Texas freeze"),
    ("sydney_flood", "Sydney AU", -33.8688, 151.2093, "2022-03-07", "2022-03-08",
     "March 2022 east-coast floods"),
]

URL = ("https://archive-api.open-meteo.com/v1/archive?latitude=%.4f&longitude=%.4f"
       "&start_date=%s&end_date=%s&hourly=%s&timezone=GMT")


def main() -> int:
    out = {"source": "Open-Meteo historical archive (timezone=GMT)",
           "fetched_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "vars": VARS, "events": []}
    for ev in EVENTS:
        eid, site, lat, lon, d0, d1, what = ev
        url = URL % (lat, lon, d0, d1, ",".join(VARS))
        with urllib.request.urlopen(url, timeout=60) as r:
            data = json.load(r)
        hourly = data["hourly"]
        out["events"].append({
            "id": eid, "site": site, "lat": lat, "lon": lon, "what": what,
            "time_utc": hourly["time"],
            "values": {v: hourly[v] for v in VARS},
        })
        print("%-16s %-20s %s..%s  %d hours" % (eid, site, d0, d1, len(hourly["time"])))
        time.sleep(0.4)
    here = os.path.dirname(os.path.abspath(__file__))
    dst = os.path.normpath(os.path.join(here, "..", "..", "core", "weather", "testdata",
                                        "weather_events_ref.json"))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, indent=1)
    print("wrote", dst)
    return 0


if __name__ == "__main__":
    sys.exit(main())
