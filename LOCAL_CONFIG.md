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
| `terrain_config.cfg` | OpenTopography API key — `[opentopography] api_key=` (or the `OPENTOPOGRAPHY_API_KEY` env var) — for 30 m global DEM, 10 m USGS DEM in the US, and (academic-tier OpenTopography accounts only — see [`core/terrain/elevation_service.gd`](core/terrain/elevation_service.gd)) 1 m USGS lidar; same key, no separate one needed. Set it from **Settings → Keys** rather than hand-editing this file. Mapillary access token ([`core/terrain/mapillary_service.gd`](core/terrain/mapillary_service.gd)); Gemini image API key for the AI spawn-area "hero patch" — `[gemini] api_key=` / `ai_hero_enabled` / `ai_hero_half_extent_m` / `ai_image_size` (or the `GEMINI_API_KEY` env var), see [`core/terrain/ai_imagery_service.gd`](core/terrain/ai_imagery_service.gd) |
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
| `mp_prefs.cfg` | Multiplayer display name + Discord invite URL ([`core/multiplayer/multiplayer_session.gd`](core/multiplayer/multiplayer_session.gd)) |
| `mp_telemetry.log` | Local multiplayer event log. Secrets are stripped by `MpHardening.redact` before anything is written — **never bypass `log_event` to write a raw payload** |
| `discord_auth.cfg` | **Real Discord OAuth refresh token** ([`core/discord/discord_identity.gd`](core/discord/discord_identity.gd)). Delete it to sign out |
| `discord_config.cfg` | Optional dev override: `[discord] client_id=` ([`core/discord/discord_config.gd`](core/discord/discord_config.gd)) |
| `communities/<guild_id>.json` | Imported community files. **These carry Discord webhook URLs, which are write credentials for that channel — treat one like a server invite** |

## Discord integration — one-time setup

The game talks to Discord with **OAuth2 authorization-code + PKCE and no client
secret**, so nothing confidential ships in the binary. That only works if the
application is configured for it. Two of these steps fail with opaque errors if
missed, so do them in order:

1. <https://discord.com/developers/applications> → **New Application**.
2. **OAuth2** tab → turn **Public Client** ON. *Without this every token
   exchange returns HTTP 401 and Discord's own error text does not mention it.*
   (The game appends a hint to that error for exactly this reason.)
3. Still on **OAuth2**, add all three redirect URIs **verbatim** — the loopback
   port cannot be dynamic because Discord requires an exact registered match,
   and the game binds the first of the three that is free:
   `http://127.0.0.1:34199/cb`, `http://127.0.0.1:34200/cb`, `http://127.0.0.1:34201/cb`
4. Copy the **Application ID** (this is the `client_id`; it is *not* a secret —
   it appears in every authorize URL). Never copy the Client Secret; the game
   has no use for one.
5. In your Discord server, with **Developer Mode** on (User Settings →
   Advanced), right-click to copy the **server id**, the **voice channel id**,
   and any **role ids** you want to gate on.
6. Create a channel for session status and give it a **webhook**
   (Channel → Integrations → Webhooks). That webhook URL is how the game
   publishes and reads "who is hosting right now" with no server of ours — see
   `core/discord/directory_record.gd`.

7. In game: **Multiplayer → Security → Create a community file**, paste the ids
   and webhook URLs, press **Create & copy code**. That produces a `SMBC1:…`
   string — post it in your server. Members paste it into
   **Multiplayer → Play → Community → Import**, and from then on **Play
   together** finds whoever is hosting.

Scopes requested are deliberately minimal: `identify` and
`guilds.members.read`. The broad `guilds` scope (which would expose a member's
entire server list to whoever holds their token) is opt-in only.

⚠ **The community file contains webhook URLs, which are write credentials for
those channels.** Anyone holding it can post there and can overwrite the session
status message. Treat it like a server invite, give the status message its own
low-stakes channel, and use a *different* webhook for the chat relay so either
can be revoked without killing the other. Access control is the Discord
membership check, never the webhook.

**In-game entry point:** Timeline bottom bar → **⚙ Settings** (Keys, Home Assistant, Solar, etc.). Token fields use secret `LineEdit` with Show/Hide toggles.

To see the absolute path on your machine, run the project once and use **Project > Open User Data Folder** in the editor, or call `print(OS.get_user_data_dir())` from a temporary script.

## Code defaults

- [`ha_websocket_client.gd`](ha_websocket_client.gd) uses placeholder `YOUR_LONG_LIVED_TOKEN` — safe for public repo.
- [`uisp/uisp_api_client.gd`](uisp/uisp_api_client.gd) uses placeholder `YOUR_API_TOKEN` for `@export var api_token`. The in-game UI saves real values to `user://uisp_settings.cfg`. Before pushing to GitHub, confirm no scene or resource overrides embed a real token.

## `.gitignore`

Accidental copies of the above `*.cfg` files anywhere under the repo are ignored. Bespoke SOAK/Mars map scenes, local MapDefinition `.tres`, HA CSV exports, and the `build/` folder are also ignored. See [`.gitignore`](.gitignore).
