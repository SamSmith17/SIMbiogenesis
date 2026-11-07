extends SceneTree

## TC Process Lab bench (headless): for every built-in design, the network
## size (CVs, links), the cost of a step and of each section, and the time a
## whole batch takes to pre-run at the lab's 5 s step — the number the
## "Run the whole batch" button spends (in 12 ms frame slices) before the
## player can scrub. Also a 1 s step on the reactor (what the stepper would
## cost at the finer step) and a snapshot / restore round.
##   Godot --headless --path . --script tools/bench/tc_proc_bench.gd


func _initialize() -> void:
	print("tcbench design                         CVs links  ms/step  batch h  pre-run s  bed/pools/walls/phase/flow/drain µs")
	for b in TcPresets.builtins():
		var spec: Dictionary = b["spec"]
		var d := TcDesign.solve(spec)
		var proc := TcProcSpec.resolve(spec.get("process", {}))
		var sim := TcProcSim.create(d, proc)
		var hours := float(proc["duration_h"])
		for k in TcProcSim.prof.size():
			TcProcSim.prof[k] = 0
		var t0 := Time.get_ticks_usec()
		sim.run_for(hours * 3600.0)
		var us := float(Time.get_ticks_usec() - t0)
		var steps := maxf(hours * 3600.0 / TcProcSim.DT_DEFAULT, 1.0)
		var secs := PackedStringArray()
		for k in TcProcSim.prof.size():
			secs.append("%d" % int(float(TcProcSim.prof[k]) / steps))
		print("tcbench %-30s %4d %5d  %7.3f  %7.1f  %9.2f  %s" % [str(b["id"]), sim.n_cv, (sim.net["links"] as Array).size(),
			us / steps / 1000.0, hours, us / 1.0e6, "/".join(secs)])
	# The reactor at a 1 s step for an hour, and the scrub machinery.
	var spec2 := TcPresets.builtin("biochar_reactor")
	var d2 := TcDesign.solve(spec2)
	var s2 := TcProcSim.create(d2, spec2["process"])
	var t1 := Time.get_ticks_usec()
	s2.run_for(3600.0, 1.0)
	print("tcbench reactor at 1 s steps: %.3f ms/step" % (float(Time.get_ticks_usec() - t1) / 3600.0 / 1000.0))
	var t2 := Time.get_ticks_usec()
	for k in 20:
		var snap := s2.snapshot()
		s2.restore(snap)
	print("tcbench snapshot + restore: %.2f ms" % (float(Time.get_ticks_usec() - t2) / 20.0 / 1000.0))
	s2.run_for(3.0 * 3600.0)
	var t3 := Time.get_ticks_usec()
	s2.seek(1800.0)
	s2.seek(3.0 * 3600.0)
	print("tcbench seek back 3.5 h and forward: %.1f ms" % (float(Time.get_ticks_usec() - t3) / 1000.0))
	quit()
