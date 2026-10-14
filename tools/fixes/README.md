# World fixes (`--run-script`)

A fix is a small script the agent writes to change something IN the player's
saved world (a prop record, a graph item, a pond level, a broken binding) and
leave it fixed for the next load.

```gdscript
extends RefCounted

## What it fixes and why, in one paragraph.
func run(main: Node, harness: Node) -> Dictionary:
	# main = the running Main scene, the world fully loaded from its snapshot.
	# Use the game's own services (PlacedPropService, ServiceLocator.graph(),
	# the TerrainLoader API); may `await`.
	return {"ok": true, "changed": 1}
```

1. **Dry run in the sandbox** (nothing real changes):
   `tools\harness.ps1 -World mtvernon -RunScript res://tools/fixes/<fix>.gd`
   To see the fixed world, chain a look after the fix in the SAME run
   (separate runs get separate sandboxes, so a later `look` would show the
   unfixed world):
   `tools\harness.ps1 -World mtvernon -Capture script,look -RunScript res://tools/fixes/<fix>.gd`
2. **Persist** once it is right:
   `tools\harness.ps1 -World mtvernon -RunScript res://tools/fixes/<fix>.gd -Persist`.
   - The launcher backs up the world-state files first.
   - It prints `tools\harness.ps1 -RestoreBackup <dir>` to undo the fix.
   - After `run()` the world is saved through `WorldSession.save_now`, the same
     path as the in-game Save now.

`noop_check.gd` changes nothing. Use it to test the pipeline.
