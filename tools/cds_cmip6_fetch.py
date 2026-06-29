#!/usr/bin/env python3
"""Fetch CMIP6 monthly projections from Copernicus CDS for one map location.

Reads the CDS personal access token from keys_config.cfg (or ~/.cdsapirc),
retrieves near-surface temperature + precipitation for historical + SSP,
extracts the nearest grid point, and writes a JSON cache for Godot.

Requires: pip install "cdsapi>=0.7.7" xarray netCDF4

Usage:
  python tools/cds_cmip6_fetch.py --lat 33.76 --lon -115.74 --scenario 1 \\
      --out "%APPDATA%/Godot/app_userdata/Sky/weather_cache/climate_proj_cds_1_33.76_-115.74.json" \\
      --keys-cfg "%APPDATA%/Godot/app_userdata/Sky/keys_config.cfg"
"""
from __future__ import annotations

import argparse
import calendar
import json
import os
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any

BASELINE_START = 1991
BASELINE_END = 2020
PROJ_END = 2050

SCENARIO_EXPERIMENTS = ["ssp126", "ssp245", "ssp370", "ssp585"]
# Primary CDS model per UI scenario; fall back to mpi_esm1_2_lr if retrieve fails.
SCENARIO_MODELS = [
    ("cmcc_cm2_vhr4", "mpi_esm1_2_lr"),
    ("mpi_esm1_2_hr", "mpi_esm1_2_lr"),
    ("mri_esm2_0", "mpi_esm1_2_lr"),
    ("ec_earth3p_hr", "mpi_esm1_2_lr"),
]

VARIABLES = ["near_surface_air_temperature", "precipitation"]


def _read_cds_key(keys_cfg: str | None) -> tuple[str, str]:
    if keys_cfg and os.path.isfile(keys_cfg):
        import configparser

        cfg = configparser.ConfigParser()
        cfg.read(keys_cfg)
        if cfg.has_option("copernicus", "api_key"):
            key = cfg.get("copernicus", "api_key").strip()
            if key:
                return "https://cds.climate.copernicus.eu/api", key
    rc = os.path.expanduser("~/.cdsapirc")
    if os.path.isfile(rc):
        url = "https://cds.climate.copernicus.eu/api"
        key = ""
        with open(rc, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.lower().startswith("url:"):
                    url = line.split(":", 1)[1].strip()
                elif line.lower().startswith("key:"):
                    key = line.split(":", 1)[1].strip()
        if key:
            return url, key
    raise RuntimeError("No CDS API key in keys_config.cfg or ~/.cdsapirc")


def _area_box(lat: float, lon: float, pad: float = 1.0) -> list[float]:
    lat = max(-90.0, min(90.0, lat))
    lon = ((lon + 180.0) % 360.0) - 180.0
    return [lat + pad, lon - pad, lat - pad, lon + pad]


def _retrieve(client, model: str, experiment: str, date: str, area: list[float], target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    client.retrieve(
        "projections-cmip6",
        {
            "download_format": "zip",
            "data_format": "netcdf_legacy",
            "temporal_resolution": "monthly",
            "experiment": experiment,
            "level": "single_levels",
            "variable": VARIABLES,
            "model": model,
            "date": date,
            "area": area,
        },
        str(target),
    )


def _open_nc_from_zip(zip_path: Path):
    import xarray as xr

    with zipfile.ZipFile(zip_path) as zf:
        nc_names = [n for n in zf.namelist() if n.lower().endswith(".nc")]
        if not nc_names:
            raise RuntimeError(f"No .nc in {zip_path}")
        with zf.open(nc_names[0]) as src:
            with tempfile.NamedTemporaryFile(suffix=".nc", delete=False) as tmp:
                tmp.write(src.read())
                tmp_path = tmp.name
    try:
        return xr.open_dataset(tmp_path)
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _coord_names(ds) -> tuple[str, str]:
    for lat_n, lon_n in (
        ("lat", "lon"),
        ("latitude", "longitude"),
        ("y", "x"),
    ):
        if lat_n in ds.coords and lon_n in ds.coords:
            return lat_n, lon_n
    raise RuntimeError("Could not find lat/lon coordinates in NetCDF")


def _var_name(ds, candidates: list[str]) -> str:
    for name in candidates:
        if name in ds:
            return name
    raise RuntimeError(f"None of {candidates} found in dataset ({list(ds.data_vars)})")


def _extract_monthly(ds, lat: float, lon: float) -> dict[int, dict[int, dict[str, float]]]:
    import numpy as np
    import pandas as pd

    lat_n, lon_n = _coord_names(ds)
    tas_name = _var_name(ds, ["tas", "near_surface_air_temperature"])
    pr_name = _var_name(ds, ["pr", "precipitation"])

    point = ds.sel({lat_n: lat, lon_n: lon}, method="nearest")
    time_coord = point["time"]
    monthly: dict[int, dict[int, dict[str, float]]] = {}

    for i in range(int(point.sizes.get("time", 0))):
        ts = pd.Timestamp(time_coord.values[i])
        year = int(ts.year)
        month = int(ts.month)
        if year < BASELINE_START or year > PROJ_END:
            continue

        tas_k = float(point[tas_name].values[i])
        if np.isnan(tas_k):
            continue
        temp_c = tas_k - 273.15

        pr_flux = float(point[pr_name].values[i])
        if np.isnan(pr_flux):
            pr_day = 0.0
        else:
            days = calendar.monthrange(year, month)[1]
            pr_day = (pr_flux * days * 86400.0) / days  # mm/day equivalent

        monthly.setdefault(year, {})[month] = {
            "temp_max": temp_c,
            "temp_min": temp_c,
            "precip": pr_day,
        }
    ds.close()
    return monthly


def _merge_monthly(dst: dict, src: dict) -> None:
    for year, months in src.items():
        dst.setdefault(year, {}).update(months)


def _compute_baseline(monthly: dict) -> dict[int, dict[str, float]]:
    sums: dict[int, dict[str, float]] = {}
    counts: dict[int, int] = {}
    for year in range(BASELINE_START, BASELINE_END + 1):
        if year not in monthly:
            continue
        for month, cell in monthly[year].items():
            sums.setdefault(month, {"temp_max": 0.0, "temp_min": 0.0, "precip": 0.0})
            counts[month] = counts.get(month, 0) + 1
            for k in ("temp_max", "temp_min", "precip"):
                sums[month][k] += float(cell[k])
    baseline: dict[int, dict[str, float]] = {}
    for month, s in sums.items():
        n = counts.get(month, 0)
        if n <= 0:
            continue
        baseline[month] = {k: s[k] / n for k in s}
    return baseline


def _try_models(client, models: tuple[str, str], experiment: str, date: str, area: list[float], tag: str) -> Path:
    last_err: Exception | None = None
    for model in models:
        target = Path(tempfile.gettempdir()) / f"sky_cmip6_{tag}_{model}_{experiment}.zip"
        try:
            print(f"CDS retrieve: model={model} experiment={experiment} date={date}", flush=True)
            _retrieve(client, model, experiment, date, area, target)
            return target
        except Exception as exc:  # noqa: BLE001
            print(f"WARN model {model} failed: {exc}", flush=True)
            last_err = exc
            if target.exists():
                target.unlink(missing_ok=True)
    raise RuntimeError(f"All models failed for {experiment}: {last_err}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch CMIP6 point projections from CDS")
    parser.add_argument("--lat", type=float, required=True)
    parser.add_argument("--lon", type=float, required=True)
    parser.add_argument("--scenario", type=int, required=True, choices=range(4))
    parser.add_argument("--out", type=str, required=True)
    parser.add_argument("--keys-cfg", type=str, default="")
    args = parser.parse_args()

    try:
        import cdsapi
    except ImportError:
        print("FAIL: pip install cdsapi xarray netCDF4", file=sys.stderr)
        return 2

    url, key = _read_cds_key(args.keys_cfg or None)
    client = cdsapi.Client(url=url, key=key, quiet=False, progress=False)

    scenario = int(args.scenario)
    experiment = SCENARIO_EXPERIMENTS[scenario]
    models = SCENARIO_MODELS[scenario]
    area = _area_box(args.lat, args.lon)

    monthly: dict[int, dict[int, dict[str, float]]] = {}
    zips: list[Path] = []
    try:
        hist_zip = _try_models(
            client,
            models,
            "historical",
            f"{BASELINE_START}-01-01/2014-12-31",
            area,
            "hist",
        )
        zips.append(hist_zip)
        _merge_monthly(monthly, _extract_monthly(_open_nc_from_zip(hist_zip), args.lat, args.lon))

        fut_zip = _try_models(
            client,
            models,
            experiment,
            "2015-01-01/2050-12-31",
            area,
            "fut",
        )
        zips.append(fut_zip)
        _merge_monthly(monthly, _extract_monthly(_open_nc_from_zip(fut_zip), args.lat, args.lon))
    finally:
        for zp in zips:
            zp.unlink(missing_ok=True)

    baseline = _compute_baseline(monthly)
    if not monthly or not baseline:
        print("FAIL: empty monthly/baseline after extract", file=sys.stderr)
        return 3

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "source": "cds",
        "fetch_year": __import__("datetime").date.today().year,
        "scenario": scenario,
        "monthly": monthly,
        "baseline": baseline,
    }
    out_path.write_text(json.dumps(payload), encoding="utf-8")
    print(f"OK: wrote {out_path}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
