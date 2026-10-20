# Local asset pack (not in Git)

## Share with a friend (in game, no folder copying)

**Share…** in the launch hub's header (or on a world's row, or **Share…** in
the in-game 💾 world panel) exports a single `.simpack.zip`:

- **Worlds.** Each world comes with its map data: elevation, aerial imagery,
  OSM and weather. That way it looks identical and loads offline.
- **Your content.** Imported models, stage music, presets and looks,
  animations, designs, G-code jobs.
- **Settings.** Off unless you tick them.
- **Game art.** The gitignored folders below. These can only be shared when
  you run the game from its project folder.

Untick anything you don't want to send. A pack over 3.5 GB is saved as
numbered parts (`x.simpack.002.zip`, …); send all of them.

API keys, Home Assistant, Discord and multiplayer sign-ins, your home
location, downloaded tools, caches and logs are **never** included.

Your friend clones the repo, opens it in Godot, and runs it. Then they do one
of these:
- press **Share… → Install a pack**;
- drop the zip onto the game window.

They see who made the pack and what is in it. Every world arrives as a **new**
world, and nothing of theirs is overwritten:
- a library file that differs is saved beside theirs;
- settings are opt-in and backed up first.

If the pack has game art, Godot imports it in the background and then offers
to restart the game.

Code: `core/sharing/` (format, catalog, writer, reader, installer) and
`scenes/ui/asset_pack_modal.gd`.

The manual way below still works.

This repo tracks **code, UI, and small shared data**. Bespoke map art (SOAK Festival, Mars aerial, player mesh, Starshade FBX trees) lives in a **local asset pack** beside `project.godot`. Git ignores those paths so clones stay small.

## Quick start (full maps on your machine)

If you already have the folders below in this directory, open the project in **Godot 4.6** and play — no extra steps.

Required for SOAK / Mars / player:

| Path | Role |
|------|------|
| `Imported Models/` | Props, terrain GLBs, trees, Mars aerial art |
| `StarShade FBX/` | Starshade rig / export hierarchy |
| `Starshade Pretty Version/` | Alternate Starshade FBX set |
| `Player Character/` | Player FBX mesh + animations |
| Root `10m_*.obj` | Mars terrain tiles (see `scenes/gameplay/Terrain.tscn`) |
| Root `Mars *.glb`, `Mars*.jpg` | Mars aerial scene dependencies |

Optional PBR sets: `Wood034_1K-JPG/`, `Metal051C_1K-JPG/`.

> **Not** part of this pack: `assets/linkage/unistrut_trolley_bracket.glb` is
> **committed** to the repo (72 KB, first-party — see `CREDITS.md`) and needs
> no local download. It is still optional at runtime —
> `LinkageHwParts.bracket_mesh()` falls back to a parametric U-channel if it
> is missing.

## Without the asset pack

The simulator still runs:

- **Launch hub** boots by default (`project.godot` → unified energy-zone map + saved worlds list).
- **Create map here** builds any site via `generated_location.tscn` + terrain fetch.
- SOAK / Mars entries appear in **Your maps** only when you add the local scene files and MapDefinition resources (see below).
- **NPC population** simulates and renders normally; people just show as the
  simple primitive figures instead of the rigged Mixamo silhouettes (see below).
- **Ambient sound** on foot (wind, rain, the nearest stream, birdsong) is
  procedural — the repo ships no audio. Drop your own loops into
  `user://ambient/` as `wind`, `rain`, `stream` and `birds` `.mp3`, `.ogg` or
  `.wav` and the bed plays those instead (volume: Settings → NPCs → Ambient
  sound volume). Venue tracks go in `user://stage_audio/` as before.

## NPC character pack (`Imported Models/NPC/`)

Optional. Without it `NpcRig.available()` is false and `NpcAvatar` falls back to
its head/torso/legs figure — the sim itself never depends on these files.

Download from [mixamo.com](https://www.mixamo.com/) (free Adobe account) into
`Imported Models/NPC/`, then run `--headless --path . --import`:

The character mesh, then every clip in `NpcRig.SOURCES` (this table is the
whole list — keep it in lockstep with that dict; a missing file is a
`push_warning` at load, not an error, so a partial pack degrades one clip at a
time rather than failing loudly):

| File | Mixamo item | Download settings |
|---|---|---|
| `Ch36_nonPBR.fbx` | character "Ch36" | **With** skin, FBX Binary, T-pose |
| `Walking.fbx` | Walking | Without Skin, FBX Binary, 30 fps, no keyframe reduction |
| `Walking (1).fbx` | Walking (variant) | as above |
| `Walking (2).fbx` | Walking (variant) | as above |
| `Sad Walk.fbx` | Sad Walk | as above |
| `Start Walking.fbx` | Start Walking | as above |
| `Stop Walking.fbx` | Stop Walking | as above |
| `Laying Sleeping.fbx` | Laying Sleeping | as above |
| `Idle To Situp.fbx` | Idle To Situp | as above |
| `Sleep To Idle.fbx` | Sleep To Idle | as above |
| `Sitting Idle.fbx` | Sitting Idle | as above |
| `Sit To Stand.fbx` | Sit To Stand | as above |
| `Sad Idle.fbx` | Sad Idle | as above |
| `Overhead Squat.fbx` | Overhead Squat | as above |
| `Back Squat.fbx` | Back Squat | as above |
| `Standing Clap.fbx` | Standing Clap | as above |
| `Sitting Clap.fbx` | Sitting Clap | as above |
| `Arms Hip Hop Dance.fbx` | Arms Hip Hop Dance | as above |

The three walk variants exist so a group walking together is not a chorus
line; they are authored at different speeds and the loader rate-matches each
one, so any Mixamo walk works as a substitute.

The standing idle is **not** in this list — it is retargeted at load from
`Player Character/Breathing Idle (no skin).fbx`.

**Mo-cap SPICE for the stick figure** (`Imported Models/NPC/mocap/<moment>/`).
The simplified (stick-figure) body is posed procedurally; now and then a
nearby figure breaks into a real motion-captured clip for a few seconds and
eases back (`NpcMocapSpice`, `NpcStickMocap`; Settings → NPCs → Mo-cap spice).
Every FBX in a moment's folder is a candidate for it — **file names are
free**, so drop in the closest clip you can find. A moment with no clip simply
stays procedural. Export every clip from mixamo.com with:

| Setting | Value |
|---|---|
| Format | FBX Binary (.fbx) |
| Skin | **Without Skin** (any character — the loader converts Y Bot's `mixamorig:` bones) |
| Frames per second | 30 |
| Keyframe reduction | none |
| In Place | tick it whenever the clip offers it |

then re-import (open the editor, or `--headless --path . --import`).

| Folder | When it plays | Suggested Mixamo clips (or the closest you can find) |
|---|---|---|
| `peak/` | hitting FUCK YES!!! — the punchline (loops, ~10 s) | Samba Dancing (copied in), Silly Dancing, Chicken Dance, Gangnam Style, Robot Hip Hop Dance, Twist Dance, Victory |
| `cheer/` | a set's closer, the effigy coming down (once) | Cheering, Fist Pump, Victory, Excited, Clapping |
| `dance/` | a dance break at a stage or a fire (loops, ~12 s) | Hip Hop Dancing (variants), Shuffling, Swing Dancing, Salsa Dancing, Thriller Part 2, Breakdance Uprock, Belly Dancing |
| `dj/` | the DJ at the decks (loops) | a head-bob / groove idle with the hands at waist height |
| `talk/` | a flourish in a conversation (once) | Talking, Laughing, Arguing, Agreeing, Shrugging, Thinking |
| `idle/` | standing about (once) | Looking Around, Weight Shift, Arm Stretching, Yawn, Bored, Texting While Standing |
| `sit/` | sitting round a cold pit / at a meal (once; set on the ground) | Sitting Laughing, Sitting Talking, Sitting Clap |
| `wake/` | just up (once) | Arm Stretching, a standing wake-up stretch |
| `work/` | doing a chore (loops) | Digging / Shoveling, Hammering, Lifting / Box Idle, Pick Up, Kneeling |
| `gaze/` | standing taking in the effigy or an art piece (once) | Looking Around, Looking Up, Pointing, Thinking |
| `fireflow/` | a Fire Flow performer circling the effigy (loops; the poi flames are drawn on top) | Spin In Place, Capoeira, Ginga, any slow arms-wide turning dance |

Until a folder has clips, `peak` uses the Samba below, `dance` Arms Hip Hop
Dance and `cheer` Standing Clap. Each folder carries a README with this list.

**The peak dance** (`NpcRig.RETARGET_SOURCES`, played at FUCK YES!!!):

| File | Mixamo item | Download settings |
|---|---|---|
| `Samba Dancing.fbx` | Samba Dancing | FBX Binary, 30 fps (any character — it is retargeted) |

This export comes off a different Mixamo rig (`mixamorig:` bones rather than
the pack's `mixamorig1:`), so it is retargeted by prefix like the idle, its
hip track rescaled to the pack's standing height. Without it the rigged body
plays the ordinary dance at a peak; the stick figure and the crowd draw their
own samba either way.

**Not yet sourced — the carry pair.** NPCs hauling crates (Site Projects)
currently play the ordinary walk/idle under a chest-height box, which reads
acceptably at silhouette distance. A real two-hand carry needs two clips that
nothing in the pack above can stand in for:

| File | Mixamo item | Notes |
|---|---|---|
| `Walking With Box.fbx` | any walking-with-load clip | starts and ends STANDING |
| `Idle With Box.fbx` | any standing-hold clip | the brigade station pose |

To enable, drop them in and uncomment the two rows at the bottom of
`NpcRig.SOURCES`. They carry a forced `ROLE_CARRY` on purpose: a lift dips to
grab the load, which the loader would otherwise measure as a genuine level
change and correct by sinking the figure into the ground mid-pickup.

"In Place" does **not** need to be ticked: `NpcRig` flattens horizontal root
motion at load, because the simulation owns each agent's position. Any Mixamo
character works as a substitute — the clips bind by bone name, and the loader
measures facing, walk-cycle length and per-clip ground offset from the files
themselves rather than assuming this pack's numbers.

## Local custom maps (SOAK / Mars)

The public GitHub tree ships **`generated_location.tscn`** only. Bespoke SOAK and Mars scenes stay **gitignored** on your machine at the same paths as always:

| Local file (gitignored) | MapDefinition (gitignored) |
|-------------------------|----------------------------|
| `scenes/maps/soak_festival_2026.tscn` | `maps/soak_camp_map.tres` |
| `scenes/maps/mars_aerial.tscn` | `maps/mars_aerial_map.tres` |

**After a fresh clone:** copy [`maps/examples/soak_camp_map.example.tres`](maps/examples/soak_camp_map.example.tres) → `maps/soak_camp_map.tres` (and the Mars example likewise), restore your scene files from backup, and ensure `ResourceLoader.exists()` succeeds for each `scene_path`. The launch hub lists only maps whose scene files are present.

Legacy root [`main.tscn`](main.tscn) is also gitignored (slim Mars fallback for local exports).

## Restore from backup / zip

1. Clone or copy this repo to a folder containing `project.godot`.
2. Extract (or copy) the asset pack **into the same folder** so `Imported Models/` sits next to `project.godot`.
3. Delete `.godot/` if you copied from another machine, then open in Godot 4.6 and let it reimport.

See also [PHASE3_ASSET_PACK.md](PHASE3_ASSET_PACK.md) for tier A/B/C breakdown and Patreon zip workflow.
