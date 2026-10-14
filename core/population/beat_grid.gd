class_name BeatGrid
extends RefCounted

## The BEAT of a stage with a set on but no track of its own — a pure function
## of how long the music has been playing, so the dancers, the DJ and the
## sound-reactive lights all hit the same beat and a drop lands for all of
## them at once.
##
## A real track is analysed instead (BeatTracker, via StageMusic); this is the
## stand-in with the same output keys, shaped like a dance-music set: 32-bar
## PHRASES of 4/4, each one groove → BREAKDOWN (the kick drops out, energy
## falls) → BUILD (the last 4 bars, the riser) → DROP at the next phrase
## start. A set opens mid-groove (START_BEAT) so the first drop arrives about
## half a minute in. The tempo is chosen per venue by hash from BPMS (four
## house tempos, one 140, one 174).
##
## Output (state()): {bpm, beat (beats since the music started, continuous),
## energy 0..1, breakdown, build 0..1 (rising through the last bars before a
## drop), drop_pulse 1 → 0 over DROP_DECAY_S after a drop, until_drop and
## since_drop in seconds (INF when unknown), synced: true}.

const BPMS: Array = [122.0, 124.0, 126.0, 128.0, 140.0, 174.0]
const PHRASE_BEATS := 128.0
const BREAK_AT := 96.0
const BUILD_AT := 112.0
const START_BEAT := 64.0
const DROP_DECAY_S := 1.6
const BREAK_ENERGY := 0.3
## Before the first drop the groove is a little held back.
const INTRO_ENERGY := 0.8


static func bpm_for(seed01: float) -> float:
	return float(BPMS[clampi(int(floor(seed01 * BPMS.size())), 0, BPMS.size() - 1)])


## The music `t_s` seconds after it started (paused time excluded — the
## caller's clock stops with the sim).
static func state(t_s: float, seed01: float) -> Dictionary:
	var bpm := bpm_for(seed01)
	var spb := 60.0 / bpm
	var beat := START_BEAT + maxf(t_s, 0.0) / spb
	var phrase := floorf(beat / PHRASE_BEATS)
	var b := beat - phrase * PHRASE_BEATS
	var since := b * spb if phrase >= 1.0 else INF
	var until := (PHRASE_BEATS - b) * spb
	var breakdown := b >= BREAK_AT
	var build := clampf((b - BUILD_AT) / (PHRASE_BEATS - BUILD_AT), 0.0, 1.0) if b >= BUILD_AT else 0.0
	var energy := 1.0 if phrase >= 1.0 else INTRO_ENERGY
	if breakdown:
		energy = lerpf(BREAK_ENERGY, 0.75, build)
	return {
		"bpm": bpm, "beat": beat, "energy": energy, "breakdown": breakdown, "build": build,
		"drop_pulse": exp(-since / DROP_DECAY_S) if since < INF else 0.0,
		"until_drop": until, "since_drop": since, "synced": true,
	}
