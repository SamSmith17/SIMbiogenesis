"""One-off CDS connectivity test. Requires ~/.cdsapirc with personal access token."""
import sys

try:
    import cdsapi
except ImportError:
    print("FAIL: cdsapi not installed. Run: pip install \"cdsapi>=0.7.7\"")
    sys.exit(1)

print("CDS test: submitting small ERA5 single-level retrieve...")
client = cdsapi.Client()
client.retrieve(
    "reanalysis-era5-single-levels",
    {
        "product_type": "reanalysis",
        "variable": "2m_temperature",
        "year": "2020",
        "month": "07",
        "day": "15",
        "time": ["12:00"],
        "data_format": "netcdf",
    },
    "cds_test.nc",
)
print("OK: wrote cds_test.nc")
