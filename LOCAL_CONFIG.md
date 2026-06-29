# Local configuration and secrets

This project does **not** use `.env` files in the repository. Sensitive and user-specific values are stored at **runtime** under Godot’s `user://` path (per user, per install), which is **outside** this folder.

## Do not commit

- Real Home Assistant URLs, long-lived tokens, or entity lists.
- UISP base URLs or API tokens.
- OpenTopography, Copernicus CDS, or other API keys copied from your account.
- HA CSV data exports (entity history).
- Any file copied from your machine’s Godot user data folder into the repo.

If you need to share structure with collaborators, use the examples in [`config-templates/`](config-templates/README.md) only (placeholders, safe to commit).

## Where settings are stored (`user://`)

| File (under `user://`) | Purpose |
|------------------------|---------|
| `ha_connection.cfg` | Home Assistant WebSocket URL, token, subscribed entities (Settings → **Home Assistant** tab; legacy [`ha_connection_ui.gd`](scenes/ui/ha_connection_ui.gd)) |
| `uisp_settings.cfg` | UISP URL and API token ([`uisp/uisp_connection_ui.gd`](uisp/uisp_connection_ui.gd)) |
| `terrain_config.cfg` | OpenTopography API key for 30 m DEM ([`core/terrain/elevation_service.gd`](core/terrain/elevation_service.gd)) |
| `keys_config.cfg` | Copernicus CDS API key ([`core/climate_projection_service.gd`](core/climate_projection_service.gd)) |
| `weather_gen_engine.cfg` | Weather generation engine prefs ([`core/weather_service.gd`](core/weather_service.gd)) |
| `sim_settings.cfg` | Timeline settings panel persistence ([`scenes/ui/sim_settings_controller.gd`](scenes/ui/sim_settings_controller.gd)) |
| `ui_prefs.cfg` | Timeline UI units / track layout ([`scenes/ui/timeline_ui.gd`](scenes/ui/timeline_ui.gd)) |
| `solar_ui_ha_entities.cfg` | Solar UI HA entity bindings ([`scenes/ui/solar_ui.gd`](scenes/ui/solar_ui.gd)) |
| `solar_panel_config.cfg` | Solar panel / battery config ([`scenes/ui/solar_ui.gd`](scenes/ui/solar_ui.gd)) |
| `star_calibration.cfg` | Star calibration + starmap path ([`star_system.gd`](star_system.gd)) |
| `planet_prefs.cfg` | Planet visibility / colors ([`planets.gd`](planets.gd)) |
| `location_prefs.cfg` | Location prefs ([`main.gd`](main.gd)) |
| `climate_prefs.cfg` | Climate scenario prefs |
| `saves/` | Save index and slots ([`core/save_system.gd`](core/save_system.gd)) |

**In-game entry point:** Timeline bottom bar → **⚙ Settings** (Keys, Home Assistant, Solar, etc.). Token fields use secret `LineEdit` with Show/Hide toggles.

To see the absolute path on your machine, run the project once and use **Project > Open User Data Folder** in the editor, or call `print(OS.get_user_data_dir())` from a temporary script.

## Code defaults

- [`ha_websocket_client.gd`](ha_websocket_client.gd) uses placeholder `YOUR_LONG_LIVED_TOKEN` — safe for public repo.
- [`uisp/uisp_api_client.gd`](uisp/uisp_api_client.gd) uses placeholder `YOUR_API_TOKEN` for `@export var api_token`. The in-game UI saves real values to `user://uisp_settings.cfg`. Before pushing to GitHub, confirm no scene or resource overrides embed a real token.

## `.gitignore`

Accidental copies of the above `*.cfg` files anywhere under the repo are ignored. Bespoke SOAK/Mars map scenes, local MapDefinition `.tres`, HA CSV exports, and the `build/` folder are also ignored. See [`.gitignore`](.gitignore).
