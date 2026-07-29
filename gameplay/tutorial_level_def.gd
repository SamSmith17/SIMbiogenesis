class_name TutorialLevelDef
extends RefCounted

## One Solar Bootcamp level, dictionary-backed (mirrors ChallengeDef's style).
## Deliberately a SIBLING of ChallengeDef, not an extension: levels 1–7 are
## build-state puzzles with no time window, and the run-levels (8+) embed a
## `run` sub-dict that maps onto the shared bake engine instead.

var id: String = ""
var index: int = 0
var title: String = ""
var brief_bbcode: String = ""
var debrief_bbcode: String = ""
## Seed items: [{preset_label, x, y}] — resolved via TutorialCatalog.find_preset.
var seed: Array = []
## Pre-wired seed connections: [{from: seed_idx, from_handle, to: seed_idx,
## to_handle}] so later levels don't make the player rebuild the whole bank.
var seed_wires: Array = []
## Preset labels available in the Library while this level is active
## (overrides global unlocks; empty = library empty for this level).
var allowed_presets: Array = []
## Goal spec evaluated by TutorialGoals.evaluate.
var goal: Dictionary = {}
## ProgressStore grant entries ("cat:*" / "preset:*") awarded on completion.
var unlocks: Array = []
## Non-empty for run-levels (phase E): {span, duration_hours, ...}.
var run: Dictionary = {}


static func from_dict(d: Dictionary) -> TutorialLevelDef:
	var def := TutorialLevelDef.new()
	def.id = str(d.get("id", ""))
	def.index = int(d.get("index", 0))
	def.title = str(d.get("title", ""))
	def.brief_bbcode = str(d.get("brief_bbcode", ""))
	def.debrief_bbcode = str(d.get("debrief_bbcode", ""))
	def.seed = (d.get("seed", []) as Array).duplicate(true)
	def.seed_wires = (d.get("seed_wires", []) as Array).duplicate(true)
	def.allowed_presets = (d.get("allowed_presets", []) as Array).duplicate()
	def.goal = (d.get("goal", {}) as Dictionary).duplicate(true)
	def.unlocks = (d.get("unlocks", []) as Array).duplicate()
	def.run = (d.get("run", {}) as Dictionary).duplicate(true)
	return def


func to_dict() -> Dictionary:
	return {
		"id": id, "index": index, "title": title,
		"brief_bbcode": brief_bbcode, "debrief_bbcode": debrief_bbcode,
		"seed": seed.duplicate(true), "seed_wires": seed_wires.duplicate(true),
		"allowed_presets": allowed_presets.duplicate(),
		"goal": goal.duplicate(true), "unlocks": unlocks.duplicate(),
		"run": run.duplicate(true),
	}


func is_run_level() -> bool:
	return not run.is_empty()
