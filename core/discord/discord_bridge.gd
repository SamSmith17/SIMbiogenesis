class_name DiscordBridge
extends RefCounted

## The seam for an optional, community-run Discord bot. **Nothing implements
## this in v1** — it exists so the later bot is purely additive rather than a
## rewrite of the admission path.
##
## Why a bot is the only way to get the two things v1 cannot do:
##
##  * **Discord → game chat.** A webhook can only read back messages it wrote
##    itself; reading a channel needs a gateway connection, which needs a bot
##    token. Nobody should lose a day rediscovering this — the outbound half
##    (game → Discord) works fine over a webhook and is implemented.
##  * **Verification without token presentation.** Today a joiner hands the host
##    a live bearer token and the host asks Discord about it (see
##    `DiscordGateRules`). A bot removes that trade-off entirely: the guest
##    presents a short-lived nonce and the bot answers the host yes/no, so no
##    token ever changes hands.
##
## `DiscordGate` consults `bridge` first and falls back to the token path only
## when it is null. That single `if` is the whole integration point.

## Poll for inbound activity. Called from the gate's _process; a real
## implementation would drain a WebSocketPeer here.
func poll() -> void:
	pass


## Answer "is this Discord user in `guild_id` with one of `role_ids`?" without
## the host ever seeing a token.
## `on_done` receives {ok, user_id, username, roles} / {ok:false, error}.
func verify_member(_user_id: String, _guild_id: String, _role_ids: Array,
		on_done: Callable) -> void:
	if on_done.is_valid():
		on_done.call_deferred({"ok": false, "error": "No Discord bridge configured"})


## True when this bridge can actually answer. The null case is "no bridge".
func is_ready() -> bool:
	return false
