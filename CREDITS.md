# Credits & Attribution

SIMbiogenesis is an **open-source project built on open tools, open data, and
open hardware**. This document is the running ledger of everything we depend on,
port, bundle, or redistribute — who made it, under what license, and what that
license asks of us in return.

**Why this exists:** giving proper credit is the whole social contract of open
source. As we pull in more open hardware (OpenSCAD parts, GLBs, PBR sets), more
open data (weather, imagery, elevation), and more open code, the attribution
obligations pile up quietly. This ledger keeps them in one place so that (a) we
never ship something without crediting its author, and (b) we can later render a
real in-game **Credits** screen straight from this data.

> **Two artifacts, one system.** This file (`CREDITS.md`) is the human-readable
> ledger you edit as you add things. [`credits/credits.json`](credits/credits.json)
> is the machine-readable mirror that a future in-game credits screen and license
> checks read from. **When you add an entry here, add the matching JSON object**
> (or ask Claude to keep them in sync). Full license texts live in
> [`credits/licenses/`](credits/licenses/).

---

## How to add an entry

When you bring in anything third-party — a `.scad` part, a model, a texture, a
data source, a code snippet, a font, a tool — add a row to the right section
below **and** a matching object in `credits/credits.json`. Copy this template:

```markdown
- **<Name>** — <what it is / how we use it>
  - Author: <name or handle>
  - Source: <URL>
  - License: <SPDX id, e.g. CC-BY-4.0>  ·  Added: <YYYY-MM-DD>
  - Attribution required: <yes/no>  ·  Share-alike: <yes/no>  ·  Commercial OK: <yes/no>
  - Notes: <required attribution string, modifications made, local path, etc.>
  - Status: verified | pending-verification
```

**Rules of thumb**
- **Never invent an author or license.** If you don't know it yet, set
  `Status: pending-verification` and record where to look (e.g. the Thingiverse
  thing URL). An honest "unknown, need to check" beats a wrong credit.
- **Record modifications.** Most copyleft/attribution licenses require noting if
  you changed the work. If we tweak a `.scad` file or retexture a model, say so.
- **Keep the license text.** For anything with real obligations (GPL, CC-BY-SA,
  MPL…), drop the full license file into `credits/licenses/<SPDX-ID>.txt` and
  reference it. Verbatim license text is meant to be redistributed.
- **Attribution strings are provider-specific.** Data providers (imagery,
  elevation, maps) often mandate an exact credit line — capture it verbatim in
  Notes, don't paraphrase.

### License quick reference

| SPDX ID | Attribution? | Share-alike? | Commercial? | Gotcha |
|---|---|---|---|---|
| `MIT` / `BSD` / `Apache-2.0` | yes (keep notice) | no | yes | Keep the copyright + license notice |
| `CC0-1.0` / Public Domain | no (nice to) | no | yes | No obligations, credit is courtesy |
| `CC-BY-4.0` | **yes** | no | yes | Must credit author + indicate changes |
| `CC-BY-SA-4.0` | **yes** | **yes** | yes | Derivatives must share alike |
| `CC-BY-NC-*` | **yes** | varies | **NO** | Non-commercial only — flag for review |
| `CC-BY-ND-*` | **yes** | n/a | yes | **No derivatives** — can't modify/parametrize |
| `GPL-2.0` / `GPL-3.0` | yes | **yes (strong)** | yes | Linking pulls code under GPL; bundling a separate binary = mere aggregation |
| `ODbL-1.0` | **yes** | **yes** | yes | Data (OSM); credit "© OpenStreetMap contributors" |

> ⚠️ **`-NC` (non-commercial) and `-ND` (no-derivatives) are red flags for this
> project.** NC conflicts with anyone selling a fork; ND forbids parametrizing or
> modifying — which is exactly what the OpenSCAD hardware store does. Route those
> through a licensing review before bundling. Record them here regardless so we
> know what to exclude.

---

## Tools & bundled binaries

External executables we ship with or shell out to.

- **OpenSCAD** — headless CAD kernel; we shell out to it to render parametric
  `.scad` parts into STL in-game (see [`PARAMETRIC_STORE_PLAN.md`](PARAMETRIC_STORE_PLAN.md)).
  - Author: The OpenSCAD developers / Marius Kintel et al.
  - Source: https://openscad.org · https://github.com/openscad/openscad
  - License: `GPL-2.0-or-later` · Added: _pending (not yet bundled)_
  - Attribution required: yes · Share-alike: yes (on OpenSCAD's own code) · Commercial OK: yes
  - Notes: We invoke an **unmodified, separately-distributed binary** via CLI
    (`openscad -o out.stl in.scad -D var=val`). This is "mere aggregation," not
    linking, so it does not pull our MIT code under GPL — but we must ship
    OpenSCAD's license text and offer/point to its source. Put the license in
    `credits/licenses/GPL-2.0.txt` when bundled.
  - Status: pending-verification (confirm exact bundled version + license file)

- **FFmpeg** — used for Climelapse MP4 export (invoked from PATH, not bundled).
  - Author: The FFmpeg developers
  - Source: https://ffmpeg.org
  - License: `LGPL-2.1-or-later` / `GPL` depending on build · Added: (already used)
  - Attribution required: yes · Share-alike: on FFmpeg's code · Commercial OK: yes
  - Notes: Currently expected on the user's PATH (not redistributed by us), so no
    bundling obligation today. Revisit if we ever ship an FFmpeg binary.
  - Status: pending-verification

## Engine & addons

- **Godot Engine** (4.6, Forward+) — the game engine.
  - Author: Juan Linietsky, Ariel Manzur, and the Godot community
  - Source: https://godotengine.org
  - License: `MIT` · Added: (project foundation)
  - Attribution required: yes (keep notice) · Share-alike: no · Commercial OK: yes
  - Status: verified

- **CameraServerExtension** (`addons/CameraServerExtension/`) — OBS virtual camera.
  - Author: Jason Kuo (`Copyright (c) 2024-present`)
  - Source: (addon README) · License: `MIT` · Added: (in-tree)
  - Attribution required: yes · Share-alike: no · Commercial OK: yes
  - Status: verified (license file present in addon)

- **SpaceMouse editor addon** (`addons/spacemouse_editor/`) — 3D mouse editor nav.
  - Author: **project author (first-party — own repo)**
  - Source: (own repo) · License: `MIT` · Added: (in-tree)
  - Attribution required: n/a (our own work) · Share-alike: no · Commercial OK: yes
  - Notes: Our own addon; no third-party attribution owed. The `Copyright (c) 2026`
    LICENSE has no holder name — worth adding one for cleanliness, but nothing is
    owed to anyone else.
  - Status: verified

## Ported / adapted code

Code translated or adapted from another project. When the source is third-party,
attribution follows the *source's* license even though the reimplementation is
our own. When the source is our own work, nothing external is owed — recorded here
only for provenance/completeness.

- **LinkageLab** — the scissor-linkage designer (`core/linkage/`) is a native
  Godot port of the LinkageLab three.js web app; solver math is pinned 1:1 to its
  reference.
  - Author: **project author (first-party — both the web app and this port are
    our own repos)**
  - Source: (own repo) · License: same as this project (`MIT`) · Added: (in-tree)
  - Attribution required: n/a (our own work) · Share-alike: no · Commercial OK: yes
  - Notes: The upstream three.js app is also ours, so there is no external
    attribution debt for the port. Kept here for provenance. The part library
    under `core/linkage/hardware/` is the web app's own `hardware/*.json`
    copied verbatim (first-party data).
  - Status: verified

- **`linkage-unistrut-trolley-bracket`** — the U-bracket mesh used by the
  Linkage Lab hardware detail editor (`assets/linkage/unistrut_trolley_bracket.glb`).
  - Author: **project author (first-party)** · Source: (LinkageLab repo root,
    `Unistrut Trolley Bracket.glb`)
  - License: same as this project (`MIT`) · Added: 2026-08-04 · Modifications:
    none (merged/re-oriented at load time only)
  - Attribution required: n/a (our own work) · Share-alike: no · Commercial OK: yes
  - Notes: Modelled first-party by the project author (confirmed 2026-08-04) —
    it depicts a commercial Unistrut trolley, but the mesh itself is original
    work, so no external license attaches. Still optional at runtime:
    `LinkageHwParts.bracket_mesh()` falls back to a parametric U-channel when
    the file is absent.
  - Status: verified

## Parametric parts — OpenSCAD hardware store

Every `.scad` generator we bundle. Most come from Thingiverse/Printables and
carry a Creative Commons license chosen by the original designer — **that license
travels with the file** and must be honored per-part. This section will grow as
the store fills.

- **Twisted / perforated Vase generator** (`vase_20160822.scad`) — parametric
  vase/cup/bowl generator; candidate first part for the in-game store.
  - Author: _pending — Thingiverse designer (not in file header)_
  - Source: _pending — original Thingiverse "thing" URL_
  - License: _pending — most Thingiverse things are CC-BY / CC-BY-SA / CC-BY-NC_
  - Attribution required: assume yes until confirmed · Share-alike: TBD · Commercial OK: TBD
  - Notes: Filename date suggests a 2016-08-22 upload. **Do not bundle until the
    thing URL + license are confirmed** — if it's `-NC` or `-ND`, it can't ship
    in a parametrized store without review.
  - Status: pending-verification

> **Bulk-ingest reminder:** when the ingestion tool (Phase 2 of the OpenSCAD plan)
> runs over the library, it should emit one `pending-verification` stub per file
> here so nothing gets bundled uncredited. A `.scad` with no discoverable license
> is **quarantined**, not shipped.

## Data sources & APIs

Live/remote data the running game pulls in. Several mandate an exact on-screen
credit — captured verbatim in Notes. These are **recorded from current project
usage; confirm each provider's live attribution string before release.**

- **OpenStreetMap / Overpass** — buildings, water, vegetation, solar footprints.
  - Source: https://www.openstreetmap.org · https://overpass-api.de
  - License: `ODbL-1.0` (data) · Attribution: **"© OpenStreetMap contributors"**
  - Attribution required: yes · Share-alike: yes · Commercial OK: yes
  - Status: pending-verification

- **Esri World Imagery** — aerial drape / ortho roofs / hyper patch.
  - Source: Esri World Imagery XYZ tiles
  - License: proprietary-but-usable-with-credit · Attribution: use the string from
    `ImageryService.attribution()` (Esri + its data partners) verbatim on screen.
  - Attribution required: **yes (mandatory credit)** · Commercial OK: check ToS
  - Notes: CLAUDE.md already states `attribution()` "must be credited." Verify the
    exact wording + Esri terms before a public release.
  - Status: pending-verification

- **Open-Meteo** — weather archive/forecast **and** no-key elevation (Copernicus DEM).
  - Source: https://open-meteo.com
  - License: data `CC-BY-4.0`; API `Apache-2.0` · Attribution: credit Open-Meteo;
    elevation is Copernicus DEM (credit © Copernicus).
  - Attribution required: yes · Share-alike: no · Commercial OK: yes (free tier limits)
  - Status: pending-verification

- **CAMS air quality (via Open-Meteo)** — hourly aerosols driving the wildfire-smoke
  and dust-storm hazards (`core/weather/air_quality_service.gd`).
  - Source: https://open-meteo.com/en/docs/air-quality-api · License: `CC-BY-4.0`
  - Attribution required: **yes, and stricter than the weather endpoint** — Open-Meteo
    requires credit to the **CAMS ENSEMBLE data provider** *as well as* a reference to
    Open-Meteo, which is why this is a separate entry rather than folded into the
    Open-Meteo one above. Surfaced in-game at the foot of Settings → Extreme Weather.
  - Fields used: `pm2_5`, `pm10`, `dust`, `aerosol_optical_depth`, `us_aqi`,
    `carbon_monoxide`. Coverage: `past_days` ≤ 92, `forecast_days` ≤ 7; the global
    archive begins Aug 2022, so older sim years fall back to alert history and
    climatology rather than measured aerosol.
  - Commercial OK: yes (free tier limits) · Status: pending-verification

- **NWS alerts + IEM VTEC archive** — extreme-weather triggers and the per-site risk
  profile ("which hazards has this location actually experienced since 1986").
  - Source: https://mesonet.agron.iastate.edu/ · License: public domain (US federal
    government work), re-served by Iowa State University's Environmental Mesonet.
  - Attribution required: not legally, but credited as a courtesy · Commercial OK: yes
  - Notes: US-only. Sites with no UGC zone fall back to climatology derived from
    WeatherService, labelled as an estimate in the UI.
  - Status: pending-verification

- **OpenTopography / SRTM** — optional 30 m elevation upgrade (with API key).
  - Source: https://opentopography.org · License: data varies (SRTM public domain,
    others CC-BY) · Attribution: credit OpenTopography + dataset.
  - Attribution required: yes · Status: pending-verification

- **NASA POWER** — GHI solar-resource grid (`data/ghi-grid.json`, GhiService).
  - Source: https://power.larc.nasa.gov · License: free/open, credit requested.
  - Attribution required: courtesy yes · Status: pending-verification

- **Mapillary** — street-level reference photos for facade texturing.
  - Source: https://www.mapillary.com · License: imagery `CC-BY-SA-4.0`
  - Attribution required: **yes** · Share-alike: **yes** · Commercial OK: yes
  - Notes: CLAUDE.md notes CC-BY-SA attribution is shown; Google Street View is
    ToS-forbidden for texturing and is intentionally not used.
  - Status: pending-verification

- **Google Gemini (`gemini-2.5-flash-image`)** — opt-in AI "hero patch" ground
  enhancement (image in/out).
  - Source: Google Gemini API · This is a **paid service**, not a redistributed
    asset — no bundling/attribution obligation, but outputs carry an invisible
    **SynthID** watermark and usage is governed by Google's API terms.
  - Status: informational (not an attribution asset)

## 3D models, art & textures

Bespoke map art (SOAK, Mars, player mesh, Starshade) lives in a gitignored local
asset pack — see [`ASSETS.md`](ASSETS.md). Record each third-party model/texture's
origin + license here as it's added (PBR sets `Wood034_1K-JPG/`,
`Metal051C_1K-JPG/`, imported GLBs, StarShade FBX, etc.).

- **Mixamo character + animation clips** (Adobe) — `Imported Models/NPC/`
  (`Ch36_nonPBR.fbx` + Walking / Laying Sleeping / Overhead Squat / Sitting Idle /
  Arms Hip Hop Dance) and `Player Character/` (Remy + Breathing Idle / Walking /
  Jogging). Used as the NPC population's rigged silhouette figures and the player
  character. Royalty-free for use **within** a project under the Adobe/Mixamo
  general terms; requires a (free) Adobe account to download. **Gotcha:** the
  characters and clips may not be redistributed as standalone assets — shipping
  them inside a game is fine, re-publishing the FBX files as an asset pack is
  not. No attribution is contractually required; recorded here because the
  ledger tracks every third-party asset.
- **high-res tree textures** — photoreal conifer cutouts used as vegetation
  photocards (`assets/vegetation/photocards/spruce|fir|pine|cedar.png`,
  split/trimmed/downscaled from `trees_1K.zip` via
  `vegetation/tools/photocard_ingest.gd`).
  - Author: rubberduck
  - Source: https://opengameart.org/content/high-res-tree-textures
  - License: CC0-1.0  ·  Added: 2026-08-01
  - Attribution required: no  ·  Share-alike: no  ·  Commercial OK: yes
  - Notes: 4 of 7 trees kept (one crop from a touching triple); normal maps
    not used. Attribution voluntary (CC0) — credited anyway per ledger policy.
  - Status: verified
- **Oasis Palm Trees** — rendered palm cutouts used as vegetation photocards
  (`assets/vegetation/photocards/coconut_palm|date_palm|fan_palm.png`, first
  wind frame of each tree extracted from the sprite zip, trimmed/downscaled).
  - Author: City Building Game Art (CityBuildingKit.com)
  - Source: https://opengameart.org/content/oasis-palm-trees
  - License: CC0-1.0  ·  Added: 2026-08-01
  - Attribution required: no  ·  Share-alike: no  ·  Commercial OK: yes
  - Notes: Blender source + animation frames discarded; creator suggests
    (optional) credit to CityBuildingKit.com — given here.
  - Status: verified
- **All-sky star map (Stellarium render)** — the night-sky star field
  (`assets/sky/starmap_equirect_8k.png` + `.json` sidecar, plus the optional
  16384×8192 `starmap_equirect_16k.png` from the same pipeline), an 8192×4096
  plate-carrée render of the whole celestial sphere at J2000 made with
  `tools/stellarium_starmap_export.ssc` and black-floored/registered by
  `tools/starmap_prepare.py`.
  - Author: Stellarium contributors; star data Hipparcos/Tycho-2 (ESA); Milky
    Way background per the installed Stellarium's own credits
  - Source: https://stellarium.org
  - License: pending (Stellarium is GPL-2.0-or-later; a screenshot is program
    output, but the bundled Milky Way panorama has its own credit)  ·  Added: 2026-09-14
  - Attribution required: unknown  ·  Share-alike: unknown  ·  Commercial OK: unknown
  - Notes: GUI/ground/atmosphere/labels off; luminance floor applied;
    registration (RA at the left edge, RA direction, north-up) MEASURED from the
    bright stars and stored in the sidecar. Check Help > About > Credits in the
    installed Stellarium for the Milky Way texture author/licence before a
    public release.
  - Status: pending-verification

## Fonts

- _(none recorded yet — add each font's license here; many "free" fonts are still
  OFL or have embedding restrictions)_

---

## Maintenance

- Re-read this before any public release; resolve every `pending-verification`.
- Anything still `pending-verification` at release time is **not shipped**.
- Keep `credits/credits.json` in lockstep — it is the source for the future
  in-game credits screen and any automated license audit.
