class_name TourStop
extends RefCounted

## One stop of the feature tour: a short visual demo of ONE mode or feature,
## plus the words the docs print about it. Every stop is its own file under
## core/tour/stops/ (NN_<id>.gd, the number sets the order) and is found by
## scanning that folder, so adding a feature to the tour never touches another
## file. Copy stops/_template.gd to start one.
##
## Metadata is set in `_init()`. The three hooks may `await`; they get a
## TourContext with everything a demo needs (handles, captions, camera, clock,
## input, screenshots). Reach game classes through `ctx.klass("Name")` and
## autoloads through `ctx.autoload("Name")`, never by bare identifier: the tour
## selftest loads every stop under `--script`, where an autoload name does not
## compile and a class_name drags in its whole dependency chain.
##
## A stop must leave the game as it found it — `teardown` closes what `run`
## opened. The director also resets to first person / no overlays between
## stops, but that net is not a substitute.

## Chapters, in the order the tour and the docs present them.
const CHAPTERS := ["World", "Build", "Systems", "People", "Labs"]

## Stable id (file name without the number): the screenshot and doc anchor.
var id := ""
var title := ""
var chapter := "World"
## One line, shown on the title card.
var summary := ""
## How a player gets there, as short steps ("Press G", "Click the Site Plan chip").
var how: PackedStringArray = PackedStringArray()
## InputMap action that opens it; the key shown is read from the InputMap at
## run time, never typed here.
var action := ""
## Or (also) the on-screen button that opens it, as the player sees it.
var button := ""
## The world the demo runs on: "mtvernon" (terrain, water, vegetation, hydro),
## "walton" (people and the festival) or "burningman" (the open playa: every
## other feature, where nothing stands between the camera and the subject).
var world := "mtvernon"
## Seconds of tour time the stop may take (title card included) before the
## director gives up on it and moves on.
var budget_s := 45.0
## Skipped unless the run asks for optional stops (e.g. Window Wall).
var optional := false
## Clock hour the stop starts at (NAN = leave the clock alone). 14:00 by
## default: Mount Vernon's autumn valley fog sits in the morning.
var hour := 14.0
## Two to four sentences for docs/FEATURES.md.
var blurb := ""


func setup(_ctx: TourContext) -> void:
	pass


func run(_ctx: TourContext) -> void:
	pass


func teardown(_ctx: TourContext) -> void:
	pass


func meta() -> Dictionary:
	return {
		"id": id, "title": title, "chapter": chapter, "summary": summary,
		"how": Array(how), "action": action, "button": button, "world": world,
		"budget_s": budget_s, "optional": optional, "blurb": blurb,
	}
