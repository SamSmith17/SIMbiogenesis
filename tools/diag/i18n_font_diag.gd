extends SceneTree

## How each script renders through the game's font (Inter + its fallbacks).
## WINDOWED (run with APPDATA at a scratch folder):
##   Godot.exe --path . --windowed --resolution 1200x700 --script res://tools/diag/i18n_font_diag.gd -- --out=<png>
## One row per script at the HUD's sizes, plus Arabic in a right-to-left
## label. Prints, per row, whether every character has a glyph in the font
## chain (a missing glyph draws as a box).

const ROWS := [
	["latin", "Configuración de simulación · Silenciar efectos"],
	["han", "模拟设置 · 静音音效 · 电池电量低于 20%"],
	["arabic", "إعدادات المحاكاة · كتم المؤثرات الصوتية"],
	["devanagari", "सिमुलेशन सेटिंग्स · ध्वनि प्रभाव म्यूट करें"],
	["japanese", "シミュレーション設定 · 効果音をミュート"],
	["hangul", "시뮬레이션 설정 · 효과음 음소거"],
	["thai", "การตั้งค่าการจำลอง · ปิดเสียงเอฟเฟกต์"],
	["bengali", "সিমুলেশন সেটিংস"],
	["tamil", "உருவகப்படுத்துதல் அமைப்புகள்"],
	["ethiopic", "የማስመሰል ቅንብሮች"],
	["cyrillic", "Настройки симуляции"],
]

var _out := "user://i18n_font_diag.png"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.get_slice("=", 1)
	UITheme.install(root)
	var bg := ColorRect.new()
	bg.color = UITheme.C_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var box := VBoxContainer.new()
	box.position = Vector2(24, 16)
	box.add_theme_constant_override("separation", 6)
	root.add_child(box)
	var font := UITheme.font("regular")
	for r in ROWS:
		var l := Label.new()
		l.text = "%-11s %s" % [r[0], r[1]]
		l.add_theme_font_size_override("font_size", 18)
		l.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		if r[0] == "arabic":
			l.text_direction = Control.TEXT_DIRECTION_RTL
		box.add_child(l)
		var missing := 0
		for ch in String(r[1]):
			if ch == " " or ch == "·":
				continue
			if font != null and not font.has_char(ch.unicode_at(0)):
				missing += 1
		var sys_ok := font != null and (font as FontFile).allow_system_fallback if font is FontFile else false
		print("font-diag %-10s Inter lacks %d glyphs; system fallback %s" % [r[0], missing, "on" if sys_ok else "off"])
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(_out)
	print("font-diag wrote ", _out)
	quit()
