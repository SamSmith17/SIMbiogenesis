class_name PrintMoves
extends RefCounted

## A move list packed into arrays: what a firmware runs, one row per move
## (p0 → p1 in work mm, feed mm/s, E mm, rapid flag, source line).
##
## Why it exists: a move used to be a Dictionary, measured at ~810 bytes
## each. A large gyroid cube at a 0.45 mm line is ~3 million moves — 2.5 GB
## as dictionaries, so the slicer stopped at a cap and the print ended a
## tenth of the way up. Packed, a move is 37 bytes (3 M ≈ 110 MB).
##
## Every reader takes either form through `from_any` (G-code parses and the
## gantry designer still hand over Arrays of {p0, p1, feed_mm_s, e_mm, rapid,
## line}); `move(i)` gives one back as a Dictionary for the few callers that
## want one.

var p0 := PackedVector3Array()
var p1 := PackedVector3Array()
var feed := PackedFloat32Array()
var e := PackedFloat32Array()
var rapid := PackedByteArray()
var line := PackedInt32Array()


func size() -> int:
	return p0.size()


func is_empty() -> bool:
	return p0.is_empty()


func append(a: Vector3, b: Vector3, feed_mm_s: float, e_mm: float, is_rapid: bool, line_no: int) -> void:
	p0.append(a)
	p1.append(b)
	feed.append(feed_mm_s)
	e.append(e_mm)
	rapid.append(1 if is_rapid else 0)
	line.append(line_no)


func extrudes(i: int) -> bool:
	return e[i] > 0.0


## One move as the old Dictionary form.
func move(i: int) -> Dictionary:
	return {"p0": p0[i], "p1": p1[i], "feed_mm_s": float(feed[i]), "e_mm": float(e[i]),
		"rapid": rapid[i] != 0, "line": int(line[i])}


## The whole list as Dictionaries (small lists only: tests, old readers).
func to_array() -> Array:
	var out: Array = []
	out.resize(size())
	for i in size():
		out[i] = move(i)
	return out


## A PrintMoves from either form (returned as is when it already is one).
static func from_any(v: Variant) -> PrintMoves:
	if v is PrintMoves:
		return v
	var pm := PrintMoves.new()
	if not (v is Array):
		return pm
	var arr: Array = v
	var n := arr.size()
	pm.p0.resize(n)
	pm.p1.resize(n)
	pm.feed.resize(n)
	pm.e.resize(n)
	pm.rapid.resize(n)
	pm.line.resize(n)
	for i in n:
		var m: Dictionary = arr[i]
		pm.p0[i] = m["p0"]
		pm.p1[i] = m["p1"]
		pm.feed[i] = float(m.get("feed_mm_s", 30.0))
		pm.e[i] = float(m.get("e_mm", 0.0))
		pm.rapid[i] = 1 if bool(m.get("rapid", false)) else 0
		pm.line[i] = int(m.get("line", i + 1))
	return pm


## How many moves a value holds, in either form.
static func count(v: Variant) -> int:
	if v is PrintMoves:
		return (v as PrintMoves).size()
	if v is Array:
		return (v as Array).size()
	return 0
