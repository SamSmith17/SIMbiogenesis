#!/usr/bin/env python3
"""Stage selected diff hunks for one file (non-interactive git add -p substitute)."""
from __future__ import annotations

import subprocess
import sys
from collections import defaultdict


def get_hunks(path: str) -> tuple[list[str], list[str]]:
	diff = subprocess.check_output(["git", "diff", path]).decode("utf-8", errors="replace")
	lines = diff.splitlines()
	header: list[str] = []
	hunks: list[str] = []
	i = 0
	while i < len(lines):
		line = lines[i]
		if line.startswith(("diff ", "index ", "---", "+++")):
			header.append(line)
			i += 1
		elif line.startswith("@@"):
			hunk = [line]
			i += 1
			while i < len(lines) and not lines[i].startswith("@@") and not lines[i].startswith("diff "):
				hunk.append(lines[i])
				i += 1
			hunks.append("\n".join(hunk))
		else:
			i += 1
	return header, hunks


def classify_main(hunk: str) -> str:
	if any(
		k in hunk
		for k in [
			"ToastUI",
			"HelpOverlay",
			"show_toast",
			"first_run",
			"help_overlay",
			"toast_ui",
			"_setup_toast",
			"_setup_help",
			"_maybe_show_first_run",
		]
	):
		return "toast_help"
	if any(
		k in hunk
		for k in [
			"analemma",
			"_step_analemma",
			"_analemma_",
			"ANALEMMA_",
			"mean_solar_time_to_clock_time",
			"SeasonModel",
			"_update_seasonal",
			"get_season_signals",
			"get_snow_amount",
		]
	):
		return "season_analemma"
	if any(
		k in hunk
		for k in [
			"save_matches",
			"MapContext",
			"location_prefs",
			"consume_save",
			"apply_location",
			"NwsZoneService",
			"pending_resume",
			"GENERATED_SCENE",
			"_set_map_context",
		]
	):
		return "save_location"
	if any(
		k in hunk
		for k in [
			"cirrus",
			"sun_glow",
			"aureole",
			"fov",
			"ssil",
			"god_ray",
			"cloud_shadow",
			"msaa",
			"tonemap",
			"ACES",
			"volumetric_fog",
			"ssao_user",
			"advanced_rendering",
			"sun_aureole",
		]
	):
		return "render"
	return "other"


def classify_solar_ui(hunk: str) -> str:
	if "graph_controller_destroyed" in hunk or "set_graph_controller_destroyed" in hunk:
		return "graph"
	if "cirrus" in hunk:
		return "render"
	return "other"


def classify_project(hunk: str) -> str:
	if "toggle_help" in hunk:
		return "help"
	if "gl_compatibility" in hunk and "renderer/rendering_method=" in hunk:
		return "render"
	if "window/size/mode" in hunk:
		return "window"
	return "other"


CLASSIFIERS = {
	"scenes/maps/main.gd": classify_main,
	"scenes/ui/solar_ui.gd": classify_solar_ui,
	"project.godot": classify_project,
}


def stage(path: str, groups: set[str]) -> int:
	classifier = CLASSIFIERS.get(path)
	if classifier is None:
		raise SystemExit(f"No classifier for {path}; stage whole file with git add")
	header, hunks = get_hunks(path)
	selected = [h for h in hunks if classifier(h) in groups]
	if not selected:
		print(f"No hunks matched {groups} in {path}", file=sys.stderr)
		return 0
	applied = 0
	for hunk in selected:
		patch = "\n".join(header + [hunk]) + "\n"
		patch_bytes = patch.encode("utf-8").replace(b"\r\n", b"\n")
		subprocess.run(
			["git", "apply", "--cached", "--recount"],
			input=patch_bytes,
			check=True,
		)
		applied += 1
	print(f"Staged {applied} hunk(s) from {path} [{', '.join(sorted(groups))}]")
	return applied


def main() -> None:
	if len(sys.argv) < 3:
		print("Usage: stage_hunks.py <path> <group> [group...]", file=sys.stderr)
		sys.exit(2)
	path = sys.argv[1]
	groups = set(sys.argv[2:])
	stage(path, groups)


if __name__ == "__main__":
	main()
