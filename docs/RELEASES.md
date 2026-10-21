# Releases and first-run setup

Two ways to get the game onto someone else's computer:

| | Who it is for | What they download |
|---|---|---|
| **A release** | Players | One zip per OS from the GitHub release page, plus the optional art add-on |
| **A clone** | Anyone who wants the source (or to change it) | `git clone`, Godot 4.7.1, then your `.simpack.zip` |

Either way, your **worlds** travel as a `.simpack.zip` from **Share…**
(see [ASSETS.md](ASSETS.md)). It carries each world with the map data it was
built on, so it opens exactly as you left it.

## What a release contains

`python tools/release/build_release.py` writes `release/<version>/`
(gitignored, and Godot never scans it):

| File | What it is |
|---|---|
| `SIMbiogenesis-<v>-windows.zip` | `SIMbiogenesis.exe` (game data embedded) and the DLLs of its native addons |
| `SIMbiogenesis-<v>-macos.zip` | `SIMbiogenesis.app`, universal (Intel + Apple Silicon), ad-hoc signed |
| `SIMbiogenesis-<v>-linux.zip` | `SIMbiogenesis.x86_64` (game data embedded) and its `.so` files |
| `simbiogenesis-art-mars.pck` | Art add-on: the Mars aerial map and its scenes |
| `simbiogenesis-art-soak.pck` | Art add-on: the SOAK festival map and its scenes |
| `simbiogenesis-art-starshade.pck` | Art add-on: the Starshade models |
| `simbiogenesis-art-models.pck` | Art add-on: every other imported model, the player and NPC rigs |
| `SHA256SUMS.txt`, `RELEASE_NOTES.md` | Checksums, and the install steps to paste on the release page |

The game builds carry exactly what the repository carries. The gitignored
art ships separately as the **art add-on**, because it is about 5 GB once
imported and GitHub caps each release file at 2 GB. The add-on's `.pck`
files are the same on every OS. At start-up the game mounts every
`simbiogenesis-art-*.pck` it finds (`core/art_packs.gd`, the first autoload).
It looks in:

- the game's folder and its `art/` subfolder;
- on macOS, `SIMbiogenesis.app/Contents/Resources/`, the folder holding the
  `.app`, and that folder's `art/`;
- `user://art/`;
- `--art-dir=<folder>` given after `--` on the command line.

Packs mount with `replace_files = false`, so code always comes from the
game build, never from an older art pack. A world that uses a missing model
still opens, with the model's stand-in.

The build script checks every output against the 2 GB limit. If an art pack
grows past 1.95 GiB, split its group in `ART_PACKS` at the top of the script.
The sizes measured on 2026-10-20 were Mars ~1.9 GB, SOAK ~1.1 GB,
Starshade ~1.2 GB and models ~1.0 GB.

What the game builds leave out: the art (as above), `tools/`, `parked/`,
`plans/`, `scad_library/`, selftest fixtures (`*/testdata/`) and the
editor-only addons (`spacemouse_*`, `sketchup_import_fix`). The macOS
build also leaves out the ffmpeg video addon, which has no macOS
libraries. Video playback in the projection canvas then falls back to
Theora. The list is `GAME_EXCLUDE` in the script.

## Making a release

1. Install the export templates once. They must match the editor exactly
   (4.7.1-stable):
   ```bash
   python tools/release/install_export_templates.py
   ```
   It downloads them from the official Godot release (~1.2 GB). The editor's
   **Editor → Manage Export Templates** does the same.
2. Set the version in `project.godot` (`application/config/version`), or pass
   `--version`. Windows needs a numeric form, which the script derives (`0.2.0` →
   `0.2.0.0`).
3. Build:
   ```bash
   python tools/release/build_release.py
   ```
   It runs about 5 minutes with the art (measured 2026-10-20; game zips
   128–152 MB, art packs 348–555 MB). Useful flags:
   - `--platforms windows`
   - `--no-art`
   - `--art-only`
   - `--art-groups mars,soak`
   - `--debug`, which builds with a console and asserts
4. Smoke-test the Windows build. Unzip it, put the art packs beside the exe,
   start it, and play a world you installed from a pack.
5. Upload. The script ends by printing the matching `gh release create …`
   command. It never uploads anything itself.

The committed presets carry the same filters as the script (`GAME_EXCLUDE`,
`GAME_INCLUDE`), so **Project → Export** in the editor makes the same game
build, writing into `build/`. For the length of a build the script also
stamps the version numbers and adds one generated preset per art group to
`export_presets.cfg`. It writes the version into `project.godot` too. Both
files are put back byte for byte, even when the build fails. If you change a
filter, change it in the script and run it once; the script rewrites the
committed presets to match.

### Known difference from running in the editor

Godot's BC texture compressors are editor-only, so a release cannot compress
the downloaded terrain imagery the way a source run does
(`ImageryService.can_compress_bc`). The drapes are uploaded as RGBA8, which
takes about 4× the VRAM. The highest quality tier's 8192 px site patch is the
largest of them. On a GPU with little memory, a lower terrain quality is
safer in a release. A world shared at a high quality can be switched to this
computer's in the world panel (**Terrain imagery → My quality**); the GPU
figures shown there are for the build that is running. See
[ASSETS.md](ASSETS.md#terrain-imagery-quality).

### macOS signing

The preset signs ad-hoc (built-in codesign), which works from Windows. It
does not notarize, so players see Gatekeeper's warning once: **right-click →
Open**, or `xattr -cr SIMbiogenesis.app`. Proper notarization needs an Apple
Developer account. Put its team ID and identity in the macOS preset's
`codesign/*` and `notarization/*` options, then build on a Mac. Before a
public release, also replace the placeholder bundle ID
`com.simbio.genesis.beta`.

## A friend who clones the repository

1. Install **Godot 4.7.1**, the standard (not .NET) build. A different
   version can fail to open the project, so check the version.
2. `git clone https://github.com/SamSmith17/SIMbiogenesis.git`, then
   **Import** `project.godot` in the Project Manager. The first open imports
   everything, which takes a minute or two.
3. Press **F5**. The launch hub opens.
4. Drop your `.simpack.zip` onto the window, or use **Share… → Install a
   pack**, then press **Install**.
5. If the pack has game art, the Share window imports it in the background
   (a few minutes) and then shows **Restart now**. Play stays disabled until
   then. Closing the window does not cancel it: the window comes back when
   the import is done.
6. After the restart, the worlds are in the hub's list. They open where you
   left them, with your builds, people, weather and clock.

This exact path is rehearsed on a clean clone by:

```powershell
<clone>\tools\harness.ps1 -EmptyUser -Capture assetpack-import -UserArgs @("--import=<pack.simpack.zip>")
```

It runs on an empty user folder. It installs the pack through the real Share
window, waits for the art import, then plays the first world.

### Why a fresh clone failed before 2026-10-20

`.gitignore` had an unanchored `build/` rule, meant for export output. It
also matched `core/linkage/build/`, so those nine scripts never reached
GitHub. Every script that names `LinkageBuildSteps` / `LinkageBuildTimeline`
then failed to compile on a fresh clone, and the chain reached the autoloads.
The rule is now `/build/`. `python tools/checks/ignored_source_audit.py`
fails if any `.gd` / `.tscn` / `.gdshader` / … is ever hidden by
`.gitignore` again. Run it before pushing.
