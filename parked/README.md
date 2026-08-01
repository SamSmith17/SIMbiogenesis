# parked/

Code that is **built but not wired into the game**. It is kept because it works
and represents real effort, not because anything calls it.

Each subdirectory carries a `.gdignore`, so Godot skips it entirely: the scripts
are not parsed, their `class_name`s are not registered, and their scenes are not
imported. Parked code therefore costs nothing at runtime and cannot break a
build — but it also **will not compile-check**, so treat it as unverified against
the current engine and APIs until it is un-parked.

## To un-park a subsystem

1. Delete its `.gdignore`.
2. `git mv parked/<name> <name>` **from inside the Godot editor** so `res://`
   paths, `.uid` files, and `.tscn`/`.tres` references are rewritten
   (see `ARCHITECTURE.md` debt #3 — do not `git mv` code blindly from a shell).
3. Run `--headless --path . --import`, then boot both maps and diff the error
   output against the known pre-existing set in `CLAUDE.md`.
4. Wire it to an actual entry point, and add it to `ARCHITECTURE.md`'s layer
   table so the next audit does not find it orphaned again.

## Currently parked

### `uisp/` — Ubiquiti UISP network integration

REST client, 3D network visualizer, per-device node, and a connection UI, plus
`UISP_SETUP.md`. Parked 2026-08-01.

Fully built and documented, and referenced by **nothing**: no scene instantiates
`uisp_network_visualizer.tscn`, `uisp_connection_ui.tscn`, or `uisp_device.tscn`;
no script loads them; no input action opens them; and no `.gd` file in the
project mentions "uisp" at all. Each `.gd` was referenced only by its own
`.tscn`.

It is parked rather than deleted because it is a complete, working subsystem with
a setup guide — the missing piece is an entry point, not the feature. Un-parking
means giving it one (a Timeline chip or a settings-panel section, the way
`HAConnectionUI` is reached).

Note: the "UISP button node-path misses" entry in `CLAUDE.md`'s known-errors list
predates this and was already stale — nothing outside this directory referenced
UISP even before it was parked.
