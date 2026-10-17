extends TourStop

## TEMPLATE — copy to NN_<id>.gd (the number sets the order; keep chapters
## together), fill the metadata, write a short demo. The tour finds it by
## itself. Iterate on it alone with:
##   tools\tour.ps1 -Mode stills -Stops <id>
## then refresh the docs with `python tools/tour_docs.py`.
##
## Rules of thumb:
##   * 8–15 s of demo. The title card is shown for you.
##   * Exactly one `await ctx.hero()` — the docs image. Take it when the
##     feature is plainly on screen.
##   * Game classes via ctx.klass("Name"), autoloads via ctx.autoload("Name").
##   * `teardown` closes whatever `run` opened.
##   * `ctx.require(ok, "what")` for the things that must be true; a stop that
##     cannot show its feature should say so, not pass with an empty shot.


func _init() -> void:
	id = "my_feature"
	title = "My feature"
	chapter = "World"            # World / Build / Systems / People / Labs
	summary = "One line on what it does."
	how = PackedStringArray(["Press X", "Then do Y"])
	action = ""                  # InputMap action, e.g. "system_graph_toggle"
	button = ""                  # or the on-screen button label
	world = "mtvernon"           # or "walton"
	budget_s = 40.0
	hour = 11.0
	blurb = "Two to four sentences for docs/FEATURES.md."


func run(ctx: TourContext) -> void:
	ctx.caption("What you are looking at")
	await ctx.wait(3.0)
	await ctx.hero()


func teardown(_ctx: TourContext) -> void:
	pass
