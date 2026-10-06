class_name FestivalVibe
extends RefCounted

## The festival's "Overall Vibe" — one number for the whole event, from
## "Fuck Yes" to "Fuck This", with the reasons attached (festival plan Phase 7).
##
## `compute(summaries)` is PURE over the per-camp summaries both population
## tiers already expose (`NpcPopulationEngine.summary()` / `CrowdCohort.summary()`
## share the keys read here): the headcount-weighted mean morale → a band via
## NpcMorale.BANDS, the band histogram, the share of people with a BLOCKED
## critical need, how many are queueing, and departures — plus a `components`
## list naming which need is dragging the number down, so the meter is a
## diagnostic and not just a mood ring.
##
## An instance keeps a 24 h ring of samples (`sample`) for the trend arrow.

const TREND_WINDOW_H := 24.0
const TREND_SAMPLE_H := 1.0 / 6.0      # 10 sim-minutes
const TREND_EPS := 0.02

var _ring: Array = []     # of [abs_h, score]


## {score, band, label, color, people, histogram[6], blocked_share, blocked,
##  queueing, departures, collapse_risk, components: [{need, share, people}…]}
static func compute(summaries: Array, queueing: int = 0) -> Dictionary:
	var people := 0
	var morale_sum := 0.0
	var hist: Array = []
	hist.resize(NpcMorale.BANDS.size())
	hist.fill(0)
	var blocked: Dictionary = {}
	var departures := 0
	var risk := 0.0
	var blocked_people := 0
	for s_v in summaries:
		if not (s_v is Dictionary):
			continue
		var s: Dictionary = s_v
		var n := int(s.get("count", 0))
		if n <= 0:
			continue
		people += n
		morale_sum += float(s.get("mean_morale", 0.0)) * float(n)
		var bands: Array = s.get("morale_bands", [])
		for i in mini(bands.size(), hist.size()):
			hist[i] = int(hist[i]) + int(bands[i])
		var b: Dictionary = s.get("blocked", {})
		var camp_blocked := 0
		for need in b:
			if NpcMorale.CRITICAL_NEEDS.has(str(need)):
				blocked[str(need)] = int(blocked.get(str(need), 0)) + int(b[need])
				camp_blocked = maxi(camp_blocked, int(b[need]))
		blocked_people += camp_blocked
		departures += int(s.get("departures", 0))
		risk = maxf(risk, float(s.get("collapse_risk", 0.0)))
	var score := (morale_sum / float(people)) if people > 0 else 0.0
	var components: Array = []
	for need in blocked:
		components.append({"need": str(need), "people": int(blocked[need]),
			"share": float(blocked[need]) / float(maxi(people, 1))})
	components.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["people"]) > int(b["people"]) if int(a["people"]) != int(b["people"]) \
			else str(a["need"]) < str(b["need"]))
	return {
		"score": score, "band": NpcMorale.band(score), "label": NpcMorale.label(score),
		"color": NpcMorale.color(score), "people": people, "histogram": hist,
		"blocked_share": (float(blocked_people) / float(people)) if people > 0 else 0.0,
		"blocked": blocked, "queueing": queueing, "departures": departures,
		"collapse_risk": risk, "components": components,
	}


## One line for a chip: "VIBE ● Pretty Good 0.74 ▲ — 38 queueing at restrooms".
static func headline(v: Dictionary, trend: float = 0.0) -> String:
	var arrow := "▲" if trend > TREND_EPS else ("▼" if trend < -TREND_EPS else "")
	var txt := "VIBE ● %s %.2f %s" % [str(v.get("label", "")), float(v.get("score", 0.0)), arrow]
	var reasons: Array = []
	var comps: Array = v.get("components", [])
	if not comps.is_empty():
		var c: Dictionary = comps[0]
		reasons.append("%d blocked on %s" % [int(c["people"]), str(c["need"])])
	if int(v.get("queueing", 0)) > 0:
		reasons.append("%d queueing" % int(v["queueing"]))
	if int(v.get("departures", 0)) > 0:
		reasons.append("%d left" % int(v["departures"]))
	if not reasons.is_empty():
		txt += " — " + ", ".join(reasons)
	return txt.strip_edges()


## Record a score at abs_h; samples closer than TREND_SAMPLE_H are merged and
## anything older than the window is dropped. Returns the trend.
func sample(abs_h: float, score: float) -> float:
	if not _ring.is_empty():
		var last: Array = _ring[_ring.size() - 1]
		if abs_h < float(last[0]):
			_ring.clear()   # scrub-back: the past is being rewritten
		elif abs_h - float(last[0]) < TREND_SAMPLE_H:
			last[1] = score
			return trend(abs_h)
	_ring.append([abs_h, score])
	while _ring.size() > 1 and abs_h - float((_ring[0] as Array)[0]) > TREND_WINDOW_H:
		_ring.pop_front()
	return trend(abs_h)


## Score now minus the oldest score inside the window (0 with one sample).
func trend(_abs_h: float = NAN) -> float:
	if _ring.size() < 2:
		return 0.0
	return float((_ring[_ring.size() - 1] as Array)[1]) - float((_ring[0] as Array)[1])


func clear() -> void:
	_ring.clear()
