# Config templates (safe to commit)

These files are **examples only**. They are **not** loaded automatically by the game.

1. Configure secrets in the running app (recommended — Timeline gear → **Settings**), **or**
2. Copy a template into your Godot **user data** folder and rename it to match the real filename (see [`LOCAL_CONFIG.md`](../LOCAL_CONFIG.md)).

| Template | Becomes (`user://`) | Used by |
|----------|---------------------|---------|
| [`ha_connection.example.cfg`](ha_connection.example.cfg) | `ha_connection.cfg` | Home Assistant WebSocket — Settings → Home Assistant tab |
| [`uisp_settings.example.cfg`](uisp_settings.example.cfg) | `uisp_settings.cfg` | UISP API client |
| [`terrain_config.example.cfg`](terrain_config.example.cfg) | `terrain_config.cfg` | OpenTopography DEM key — Settings → Keys |
| [`keys_config.example.cfg`](keys_config.example.cfg) | `keys_config.cfg` | Copernicus CDS key — Settings → Keys |
| [`weather_gen_engine.example.cfg`](weather_gen_engine.example.cfg) | `weather_gen_engine.cfg` | Weather generation prefs |

Open-Meteo archive/forecast and ESRI imagery need **no API key**.
