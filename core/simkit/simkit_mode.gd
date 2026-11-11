class_name SimkitMode
extends RefCounted

## Is this process the headless simulation kernel (core/simkit/sim_kernel.tscn,
## started with --simkit-job=)? Every service that can open a network
## connection asks `blocks(kind)` at its request call, so the kernel stays
## offline: no Home Assistant, no multiplayer, no Discord, no map or AI
## imagery, no alerts. The one exception is the weather archive
## (kind "weather"), and only when the job allows downloads.
##
## Static and autoload-free on purpose: the services are autoloads and must
## compile under --script, where an autoload name does not.

static var _active := -1
static var allow_weather := false


static func active() -> bool:
	if _active < 0:
		_active = 0
		for a in OS.get_cmdline_user_args():
			if str(a).begins_with("--simkit-job="):
				_active = 1
				break
	return _active == 1


## True when a request of this kind must not be made.
static func blocks(kind: String) -> bool:
	if not active():
		return false
	if kind == "weather" and allow_weather:
		return false
	return true
