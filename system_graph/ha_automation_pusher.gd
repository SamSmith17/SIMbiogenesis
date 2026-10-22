class_name HAAutomationPusher
extends RefCounted

## Tries to notify Home Assistant via WebSocket; always writes YAML to user:// as fallback.

func push(automation: Automation, tree: SceneTree) -> Dictionary:
	var out := {"ok": false, "message": ""}
	if automation == null or tree == null:
		out.message = "Invalid automation or tree"
		return out
	var yaml := automation.to_ha_yaml()
	var safe_id := automation.automation_id.replace("/", "_").replace(":", "_")
	var file_path := "user://ha_automation_%s.yaml" % safe_id
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f != null:
		f.store_string(yaml)
		f.close()
		out.ok = true
		out.message = "Saved YAML: %s" % file_path
	else:
		out.message = "Could not write YAML file"

	# The connection is the HomeAssistant autoload (it used to look for a
	# /root/HAClient that never existed, so this always stopped here).
	var ha: Node = tree.root.get_node_or_null("HomeAssistant")
	if ha == null:
		out.message += " | Home Assistant service missing (YAML only)."
		return out
	if not bool(ha.call("is_authed")):
		out.message += " | HA not connected (YAML only)."
		return out
	if ha.has_method("call_service_no_target"):
		ha.call_service_no_target("persistent_notification", "create", {
			"title": "Godot automation: %s" % automation.alias,
			"message": "YAML saved in simulator user folder. First lines:\n%s" % yaml.substr(0, min(400, yaml.length())),
			"notification_id": "godot_autom_%s" % safe_id,
		})
		out.message += " | HA notification sent (check HA Notifications)."
	return out
