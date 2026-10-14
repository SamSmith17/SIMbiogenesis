extends RefCounted

## Pipeline check for --run-script: changes nothing, reports what it sees.
func run(main: Node, _harness: Node) -> Dictionary:
	await main.get_tree().process_frame
	var summary := WorldSession.summary(main)
	return {"ok": true, "world": WorldSession.active_id(), "summary": summary}
