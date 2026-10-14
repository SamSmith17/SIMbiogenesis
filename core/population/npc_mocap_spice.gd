class_name NpcMocapSpice
extends RefCounted

## MO-CAP AS SPICE — when a stick figure breaks into a real motion-captured
## clip, pure static.
##
## The stick figure (NpcSimpleFigure) is posed procedurally all the time; that
## is the base, and the fallback for anything without a clip. Now and then —
## the punchline — a Mixamo clip takes over the same capsules (NpcStickMocap)
## and the simple body suddenly moves like a real person, then eases back.
## This file decides WHEN and WHICH, from what the figure is already doing:
##
##   moment_for(clip, flavor) -> one of MOMENTS (or "" = never: walking,
##   lying, transitions — the sim owns those positions)
##
## Two kinds of moment:
##   * EVENTS fire once on entry (hitting FUCK YES, a shared cheer, waking
##     up): roll `chance` the moment it begins.
##   * PERIODIC ones are rolled once per `period_s` window while they last
##     (dancing, talking, standing about, sitting, working, the DJ): a dance
##     BREAK now and then, not a different body.
## The roll is a hash of (person, moment, window), so it is deterministic per
## person and never synchronised across a crowd. `level` (NpcDisplayPrefs
## .mocap_spice, 0..1, default 0.5) scales every chance: 0 = never (pure
## procedural), 0.5 = the table below, 1 = twice as often (capped at always).
##
## Clips per moment come from NpcRig.moment_clips(moment): every FBX in
## `Imported Models/NPC/mocap/<moment>/`, plus defaults from the base pack.
## No clip -> no spice -> the procedural pose simply carries on.

## moment -> {chance, period_s (0 = event), loop, max_s (longest a clip
## holds the body, real seconds)}.
const MOMENTS := {
	"peak":  {"chance": 0.85, "period_s": 0.0,  "loop": true,  "max_s": 10.0},
	"cheer": {"chance": 0.6,  "period_s": 0.0,  "loop": false, "max_s": 6.0},
	"wake":  {"chance": 0.5,  "period_s": 0.0,  "loop": false, "max_s": 6.0},
	"dance": {"chance": 0.3,  "period_s": 40.0, "loop": true,  "max_s": 12.0},
	"dj":    {"chance": 0.35, "period_s": 45.0, "loop": true,  "max_s": 12.0},
	"talk":  {"chance": 0.2,  "period_s": 35.0, "loop": false, "max_s": 8.0},
	"idle":  {"chance": 0.15, "period_s": 30.0, "loop": false, "max_s": 8.0},
	"sit":   {"chance": 0.15, "period_s": 40.0, "loop": false, "max_s": 8.0},
	"work":  {"chance": 0.25, "period_s": 60.0, "loop": true,  "max_s": 10.0},
	"gaze":  {"chance": 0.2,  "period_s": 30.0, "loop": false, "max_s": 8.0},
	"fireflow": {"chance": 0.5, "period_s": 30.0, "loop": true, "max_s": 12.0},
}
## Folder names, in a stable order (the loader and the docs list them).
const MOMENT_NAMES: Array = ["peak", "cheer", "wake", "dance", "dj", "talk", "idle", "sit", "work",
	"gaze", "fireflow"]
## Cross-fade between the procedural pose and the clip, real seconds.
const FADE_S := 0.35
## Mo-cap plays at the procedural playback rate, capped: a captured dance
## at 12x is a blur; at 3x it is still a dance, just an excited one.
const MAX_RATE := 3.0


## Which moment a figure is in. `clip` is the pose machine's logical clip,
## `flavor` the avatar's rendering hint (see NpcSimpleFigure.pose).
static func moment_for(clip: String, flavor: String) -> String:
	if clip == NpcRig.CLIP_PEAK_DANCE:
		return "peak"
	match flavor:
		"cheer":
			return "cheer"
		"dj":
			return "dj"
		"talk":
			return "talk"
	if NpcWorkPose.is_work_clip(clip):
		return "work"
	match clip:
		NpcRig.CLIP_DANCE:
			return "dance"
		NpcRig.CLIP_IDLE:
			return "idle"
		NpcRig.CLIP_SIT, NpcRig.CLIP_CLAP_SIT, NpcRig.CLIP_SIT_CROSS, NpcRig.CLIP_LOUNGE:
			return "sit"
		NpcRig.CLIP_GAZE:
			return "gaze"
		NpcRig.CLIP_FIREFLOW:
			return "fireflow"
		NpcRig.CLIP_SLEEP_EXIT:
			return "wake"
	return ""


## 0..1 chance a moment fires at spice `level` (0.5 = the table's value).
static func chance_at(moment: String, level: float) -> float:
	var m: Dictionary = MOMENTS.get(moment, {})
	if m.is_empty() or level <= 0.0:
		return 0.0
	return clampf(float(m["chance"]) * level * 2.0, 0.0, 1.0)


## The roll for a moment window: which clip (from `candidates`) plays, or ""
## for none. `window` is 0 for an event's entry, else the periodic window
## index; `seed_key` the person.
static func pick(seed_key: String, moment: String, window: int, level: float,
		candidates: Array) -> String:
	if candidates.is_empty():
		return ""
	var u := NpcHash.unit01(seed_key, "mc_%s_%d" % [moment, window])
	if u >= chance_at(moment, level):
		return ""
	var k := NpcHash.pick(seed_key, "mcc_%s_%d" % [moment, window], candidates.size())
	return str(candidates[k])


## How long (real seconds) a clip of `clip_len` (clip seconds) holds the body
## at playback `rate`.
static func hold_s(moment: String, clip_len: float, rate: float) -> float:
	var m: Dictionary = MOMENTS.get(moment, {})
	var max_s := float(m.get("max_s", 8.0))
	if bool(m.get("loop", false)):
		return max_s
	return minf(clip_len / maxf(rate, 0.05), max_s)
