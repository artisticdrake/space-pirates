extends Node3D

const DEBUG_HITBOXES := false   # set false to hide green hitbox spheres

const PLAYER_COLORS := [
	"#00f5ff", "#ff3f3f", "#39ff14", "#ff9f00", "#cc44ff", "#c0c0c0",  # slots 0-5
	"#ff2020", "#ff5010", "#ff0030", "#cc0010", "#aa0020", "#dd1010",  # slots 6-11 (escape bots)
]
const BOT_SLOT      := 5

# ── Race track definition ──────────────────────────────────────────────────────
const TRACK_HALF_WIDTH   := 36.0
const CHECKPOINT_RADIUS  := 48.0
const TRACK_WAYPOINTS    := [
	# Sector 1 — Main straight (south)
	Vector3(   0, 0, -600),  # 0  Start
	Vector3(   0, 0, -420),  # 1
	Vector3(   0, 0, -230),  # 2
	Vector3(   0, 0,  -60),  # 3  approaching Turn 1
	# Turn 1 — sweeping right (south → east)
	Vector3(  80, 0,   40),  # 4
	Vector3( 170, 0,   90),  # 5
	Vector3( 260, 0,  100),  # 6
	Vector3( 350, 0,  120),  # 7
	Vector3( 410, 0,  200),  # 8
	# Sector 2 — east section curving south
	Vector3( 430, 0,  300),  # 9
	# Hairpin right (doubles back west)
	Vector3( 410, 0,  390),  # 10
	Vector3( 350, 0,  460),  # 11
	Vector3( 250, 0,  490),  # 12 apex
	Vector3( 150, 0,  460),  # 13
	Vector3(  90, 0,  390),  # 14 exit hairpin
	# Sector 3 — west then south (stays below hairpin Z)
	Vector3(  30, 0,  310),  # 15
	Vector3( -50, 0,  280),  # 16
	Vector3(-130, 0,  310),  # 17
	Vector3(-190, 0,  390),  # 18
	# Sector 4 — left outer loop (all left side, south of hairpin)
	Vector3(-240, 0,  480),  # 19
	Vector3(-290, 0,  570),  # 20
	Vector3(-280, 0,  660),  # 21
	Vector3(-210, 0,  710),  # 22
	Vector3(-130, 0,  700),  # 23
	Vector3( -70, 0,  650),  # 24
	# Sector 5 — final run heading south-east to finish (away from start column)
	Vector3( -30, 0,  580),  # 25
	Vector3(  60, 0,  640),  # 26
	Vector3( 150, 0,  680),  # 27
	Vector3( 240, 0,  700),  # 28 Finish
]

enum State { LOBBY, COUNTDOWN, PLAYING, WIN, PLAYGROUND, RACE, ESCAPE, SIEGE, CAMPAIGN }
var state := State.LOBBY

# Slot registry: slot_info[i] = { color, ship_id, ship_node }
var slot_info    : Dictionary = {}
var active_ships : Array      = []   # all ships including bot
var human_ships  : Array      = []   # only human-controlled ships (get viewports)

# Keyboard debug (active only when no phones connected)
# kb_players entries: { ship, keys }
var kb_players : Array = []
var kb_ship    : Ship  = null

# Bot
var bot_ship  : Ship  = null
var bot_timer : float = 0.0

# Network
var bridge : NetworkBridge

# Scenes
var ship_scene        : PackedScene
var projectile_scene  : PackedScene

# World nodes
var ships_node       : Node3D
var projectiles_node : Node3D

# Split-screen
var viewport_layer : Control
var vp_data        : Array = []   # [{ sub_container, sub_vp, cam, ship, hp_fill, hp_max_w, enemy_fills }]

# HUD
var countdown_label  : Label
var win_label        : Label
var start_hint       : Label
var lobby_status     : Label
var playground_label : Label

# Timers
var countdown_val   := 3
var countdown_timer := 0.0
var win_timer       := 0.0

# Race / Escape state
var race_track_node     : Node3D    = null
var minimap_node        : Control   = null
var ship_checkpoint     : Dictionary = {}   # slot → next waypoint index to reach
var race_finished_slots : Array      = []
var _pending_race       : bool       = false
var _pending_escape     : bool       = false
var _pending_siege      : bool       = false
var _pending_mode       : String     = ""
var _pending_chapter    : int        = -1

# Escape mode
var escape_bots       : Array = []   # 6 Ship refs (may contain freed instances)
var escape_bot_speed  : float = 0.0

# Siege mode
var siege_mothership   : Node3D  = null
var siege_minions      : Array   = []
var _ms_hp_label       : Label   = null

# Campaign mode
var campaign_mode              : bool   = false
var campaign_chapter           : int    = 0
var _campaign_pending          : String = ""
var _campaign_post_game_chapter: int    = -1
var _skip_btn_layer            : CanvasLayer = null
var _campaign_lobby            : CanvasLayer = null
var _retry_layer               : CanvasLayer = null
var _main_lobby_layer          : CanvasLayer = null
var _lobby_card_refs           : Array       = []   # [{panel, sbf, accent, action}]
var _lobby_focus               : int         = 0
var _lobby_cols                : int         = 3

const CAMPAIGN_CHAPTERS := [
	"chapter_1a",
	"chapter_1b",
	"chapter_2a",
	"chapter_2b",
	"chapter_3a",
	"chapter_3b",
	"chapter_3c",
]

# ── Ready ─────────────────────────────────────────────────────────────────────

func _ready() -> void:
	ship_scene       = load("res://scenes/ship.tscn")
	projectile_scene = load("res://scenes/projectile.tscn")
	_setup_world()
	_setup_hud()
	_setup_bridge()
	_show_main_lobby()

# ── World ─────────────────────────────────────────────────────────────────────

func _setup_world() -> void:
	var env_node := WorldEnvironment.new()
	var env      := Environment.new()

	var sky_mat            := PanoramaSkyMaterial.new()
	sky_mat.panorama        = load("res://assets/skybox/space_anotherplanet.png")
	sky_mat.energy_multiplier = 1.0
	var sky                := Sky.new()
	sky.sky_material        = sky_mat
	sky.process_mode        = Sky.PROCESS_MODE_QUALITY

	env.background_mode     = Environment.BG_SKY
	env.sky                 = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color  = Color(0.06, 0.06, 0.18)
	env.ambient_light_energy = 1.0

	# Bloom — makes high-emission objects glow hot
	env.glow_enabled          = true
	env.glow_intensity        = 0.8
	env.glow_bloom            = 0.3
	env.glow_hdr_threshold    = 1.0
	env.glow_hdr_scale        = 2.0
	env.glow_strength         = 1.2

	env_node.environment     = env
	add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 40, 0)
	sun.light_energy     = 1.4
	sun.shadow_enabled   = true
	add_child(sun)

	ships_node            = Node3D.new()
	ships_node.name       = "Ships"
	projectiles_node      = Node3D.new()
	projectiles_node.name = "Projectiles"
	add_child(ships_node)
	add_child(projectiles_node)

	_build_arena()


const ASTEROID_MODELS := [
	"res://assets/ships/asteroid_1.glb",
	"res://assets/ships/asteroid_2.glb",
]

func _make_asteroid_node(rng: RandomNumberGenerator, radius: float) -> Node3D:
	var path  : String      = ASTEROID_MODELS[rng.randi() % ASTEROID_MODELS.size()]
	var scene : PackedScene = load(path)
	var root  : Node3D      = scene.instantiate()
	root.scale              = Vector3.ONE * radius * 0.55
	root.rotation_degrees   = Vector3(
		rng.randf_range(0, 360),
		rng.randf_range(0, 360),
		rng.randf_range(0, 360))
	return root

func _make_siege_asteroid(rng: RandomNumberGenerator, radius: float) -> Node3D:
	var ast := _make_asteroid_node(rng, radius)
	ast.set_script(load("res://scripts/siege_asteroid.gd"))

	var hit_r : float = radius * 0.55

	# Area3D — monitorable so mothership push_area detects it
	var ha               := Area3D.new()
	ha.collision_layer    = 2
	ha.collision_mask     = 0
	ha.monitorable        = true
	ha.monitoring         = false
	ha.set_meta("asteroid", true)
	var col   := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = hit_r
	col.shape    = shape
	ha.add_child(col)
	ast.add_child(ha)
	return ast

func _debug_sphere(parent: Node3D, radius: float, color: Color) -> void:
	if not DEBUG_HITBOXES:
		return
	var sm       := SphereMesh.new()
	sm.radius     = radius
	sm.height     = radius * 2.0
	sm.radial_segments = 12
	sm.rings      = 6
	var mi       := MeshInstance3D.new()
	mi.mesh       = sm
	var mat      := StandardMaterial3D.new()
	mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color              = Color(color.r, color.g, color.b, 0.35)
	mat.shading_mode              = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode                 = BaseMaterial3D.CULL_DISABLED
	mi.material_override          = mat
	mi.cast_shadow                = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

func _build_arena() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in 10:
		var r      := rng.randf_range(1.5, 4.5)
		var angle  := float(i) * TAU / 10.0 + rng.randf() * 0.6
		var radius := rng.randf_range(22.0, 60.0)

		var asteroid := _make_asteroid_node(rng, r)
		asteroid.position = Vector3(cos(angle) * radius,
								   rng.randf_range(-6.0, 6.0),
								   sin(angle) * radius)

		var sb  := StaticBody3D.new()
		sb.collision_layer = 4
		sb.collision_mask  = 0
		var col := CollisionShape3D.new()
		var sh  := SphereShape3D.new()
		sh.radius = r
		col.shape = sh
		sb.add_child(col)
		asteroid.add_child(sb)

		# Damage area — detects ship HitAreas (layer 1) on contact
		var hit_r := r
		var dmg_area             := Area3D.new()
		dmg_area.monitoring      = true
		dmg_area.monitorable     = true
		dmg_area.collision_layer = 2
		dmg_area.collision_mask  = 1
		dmg_area.set_meta("asteroid", true)
		var dcol   := CollisionShape3D.new()
		var dshape := SphereShape3D.new()
		dshape.radius = hit_r * 0.25
		dcol.shape    = dshape
		dmg_area.add_child(dcol)
		_debug_sphere(dmg_area, hit_r * 0.25, Color(0.0, 1.0, 0.2))
		dmg_area.area_entered.connect(func(area: Area3D):
			if not area.has_meta("ship"):
				return
			var ship = area.get_meta("ship")
			if not is_instance_valid(ship) or not ship.alive:
				return
			ship.take_damage(5)
			# Bounce ship away from asteroid
			var away : Vector3 = (ship.global_position - dmg_area.global_position)
			away.y = 0.0
			away   = away.normalized()
			var spd : float = maxf(Vector2(ship.velocity.x, ship.velocity.z).length(), 15.0)
			ship.velocity   = Vector3(away.x * spd, 0.0, away.z * spd)
		)
		asteroid.add_child(dmg_area)
		add_child(asteroid)

# ── HUD ───────────────────────────────────────────────────────────────────────

func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	viewport_layer = Control.new()
	viewport_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(viewport_layer)

	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(overlay)

	countdown_label = _make_label(overlay, "", 96, Color(1, 1, 1))
	countdown_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	countdown_label.custom_minimum_size  = Vector2(200, 120)
	countdown_label.visible              = false

	win_label = _make_label(overlay, "", 60, Color(1, 0.9, 0.1))
	win_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	win_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	win_label.custom_minimum_size  = Vector2(500, 100)
	win_label.visible              = false

	start_hint = _make_label(overlay,
		"SPACE — Bot   |   P — PvP   |   T — Race   |   E — Escape   |   B — Siege   |   C — Campaign",
		18, Color(0.45, 0.45, 0.45))
	start_hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	start_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	start_hint.offset_top = -40

	lobby_status = _make_label(overlay, "", 22, Color(0.85, 0.85, 0.85))
	lobby_status.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	lobby_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_status.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lobby_status.custom_minimum_size  = Vector2(600, 200)

	playground_label = _make_label(overlay, "PLAYGROUND  ·  PvP free fight  ·  P to exit", 26,
									Color(0.35, 1.0, 0.5))
	playground_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	playground_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	playground_label.offset_top = 14
	playground_label.visible    = false

func _make_label(parent: Control, text: String,
				  font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)
	return lbl

# ── Bridge ────────────────────────────────────────────────────────────────────

func _setup_bridge() -> void:
	bridge = NetworkBridge.new()
	add_child(bridge)
	bridge.pilot_joined.connect(_on_pilot_joined)
	bridge.pilot_left.connect(_on_pilot_left)
	bridge.ship_selected.connect(_on_ship_selected)
	bridge.pilot_ready.connect(_on_pilot_ready)
	bridge.input_received.connect(_on_input_received)
	bridge.mode_selected.connect(_on_pilot_mode_selected)

func _on_pilot_joined(slot: int, color: String) -> void:
	slot_info[slot] = { "color": color, "ship_id": "", "ship_node": null, "ready": false }
	print("Pilot joined slot %d (%s)" % [slot, color])
	_update_lobby_status()

func _on_pilot_left(slot: int) -> void:
	if slot in slot_info:
		var node = slot_info[slot].ship_node
		if node and is_instance_valid(node):
			node.queue_free()
		slot_info.erase(slot)
	print("Pilot left slot %d" % slot)
	_update_lobby_status()

func _on_ship_selected(slot: int, ship_id: String) -> void:
	if slot not in slot_info:
		slot_info[slot] = { "color": PLAYER_COLORS[slot], "ship_id": "", "ship_node": null, "ready": false }
	slot_info[slot].ship_id = ship_id
	print("Slot %d → ship: %s" % [slot, ship_id])
	_update_lobby_status()

func _on_pilot_ready(slot: int) -> void:
	if slot not in slot_info:
		return
	slot_info[slot].ready = true
	print("Slot %d gyro ready" % slot)
	_update_lobby_status()
	if state == State.LOBBY and _all_human_ready() and _pending_mode != "":
		_trigger_pending_mode()

func _all_human_ready() -> bool:
	if slot_info.is_empty():
		return false
	for info in slot_info.values():
		if not info.get("ready", false):
			return false
	return true

func _update_lobby_status() -> void:
	if state != State.LOBBY or lobby_status == null:
		return
	if slot_info.is_empty():
		lobby_status.text = ""
		return
	var lines : Array = []
	for slot in slot_info.keys():
		var info  = slot_info[slot]
		var ship  = info.ship_id.to_upper() if info.ship_id != "" else "—"
		var tag   := "READY ✓" if info.get("ready", false) else "Calibrating gyro..."
		lines.append("P%d  %s  —  %s" % [slot + 1, ship, tag])
	var body := "\n".join(lines)
	if _all_human_ready() and _pending_mode == "":
		body += "\n\nAll players ready!\nSPACE — Bot   |   P — PvP   |   T — Race   |   E — Escape   |   C — Campaign"
	elif _pending_mode != "" and not _all_human_ready():
		body += "\n\nMode selected — waiting for gyro calibration..."
	lobby_status.text = body

func _on_input_received(slot: int, data: Dictionary) -> void:
	if state != State.PLAYING and state != State.PLAYGROUND and state != State.RACE and state != State.ESCAPE and state != State.SIEGE:
		return
	if slot not in slot_info:
		return
	var node = slot_info[slot].ship_node   # untyped — avoids error on freed instance
	if not is_instance_valid(node):
		return
	var ship : Ship = node
	if ship.alive:
		ship.set_input(data.rotate, data.thrust, data.firing, data.burst)

# ── Keyboard input ────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE:
			if state == State.LOBBY:
				if slot_info.is_empty() or _all_human_ready():
					_start_countdown()
		KEY_P:
			if state == State.LOBBY:
				if slot_info.is_empty() or _all_human_ready():
					_start_playground()
			elif state == State.PLAYGROUND:
				_reset_to_lobby()
		KEY_T:
			if state == State.LOBBY:
				if slot_info.is_empty() or _all_human_ready():
					_start_race()
		KEY_E:
			if state == State.LOBBY:
				if slot_info.is_empty() or _all_human_ready():
					_start_escape()
		KEY_B:
			if state == State.LOBBY:
				if slot_info.is_empty() or _all_human_ready():
					_pending_siege = true
					_start_countdown()
		KEY_C:
			if state == State.LOBBY:
				_show_campaign_lobby()
		KEY_LEFT:
			if _lobby_card_refs.size() > 0:
				_lobby_move_focus(-1)
		KEY_RIGHT:
			if _lobby_card_refs.size() > 0:
				_lobby_move_focus(1)
		KEY_UP:
			if _lobby_card_refs.size() > 0:
				_lobby_move_focus(-_lobby_cols)
		KEY_DOWN:
			if _lobby_card_refs.size() > 0:
				_lobby_move_focus(_lobby_cols)
		KEY_ENTER, KEY_KP_ENTER:
			if _lobby_card_refs.size() > 0:
				_lobby_activate(_lobby_focus)
		KEY_R:
			if state == State.WIN:
				_reset_to_lobby()
		KEY_ESCAPE:
			if _campaign_lobby != null:
				_hide_campaign_lobby()
			else:
				get_tree().quit()

# ── State machine ─────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	match state:
		State.COUNTDOWN: _tick_countdown(delta)
		State.WIN:       _tick_win(delta)
	if state == State.PLAYING:
		_tick_bot(delta)
		_tick_kb()
		_update_hp_bars()
	elif state == State.PLAYGROUND:
		_tick_kb()
		_update_hp_bars()
	elif state == State.RACE:
		_tick_kb()
		_update_hp_bars()
		_check_race_progress()
		_enforce_track_boundaries()
		_update_race_hud()
	elif state == State.ESCAPE:
		_tick_kb()
		_update_hp_bars()
		_check_race_progress()        # reuse: first player to finish wins
		_enforce_track_boundaries()
		_update_race_hud()
		_tick_escape_bots(delta)
	elif state == State.SIEGE:
		_tick_kb()
		_update_hp_bars()
		_update_siege_hud()

func _physics_process(_delta: float) -> void:
	for vd in vp_data:
		var ship = vd["ship"]
		var cam  = vd["cam"]
		if not is_instance_valid(ship) or not is_instance_valid(cam):
			continue
		var behind : Vector3 = ship.transform.basis.z * 14.0
		var target : Vector3 = ship.position + behind + Vector3(0, 7, 0)
		cam.position   = cam.position.lerp(target, 0.15)
		cam.rotation.y = lerp_angle(cam.rotation.y, ship.rotation.y, 0.15)
		cam.rotation.x = deg_to_rad(-20.0)

# ── Campaign ──────────────────────────────────────────────────────────────────

func _start_campaign() -> void:
	campaign_mode              = true
	campaign_chapter           = 0
	_campaign_pending          = ""
	_campaign_post_game_chapter = -1
	state                      = State.CAMPAIGN
	start_hint.visible         = false
	lobby_status.text          = ""
	_play_campaign_chapter(0)

# ── Campaign Lobby ─────────────────────────────────────────────────────────────

const CHAPTER_META := [
	{ "num": "01", "title": "THE  DOWNLOAD",   "sub": "A corrupted patch. A malware trap.",    "bg": "res://storyline/Backgrounds/1a_b.png"             },
	{ "num": "02", "title": "CONSEQUENCES",    "sub": "The Empire found you.",                 "bg": "res://storyline/Backgrounds/rebel_base.png"        },
	{ "num": "03", "title": "THE  BRIEFING",   "sub": "SIGMA-9 must be destroyed.",            "bg": "res://storyline/Backgrounds/rebel_base.png"        },
	{ "num": "04", "title": "SIGMA - 9",       "sub": "The Kellian Corridor.",                 "bg": "res://storyline/Backgrounds/cargo explosion.png"   },
	{ "num": "05", "title": "PURSUIT",         "sub": "Something is wrong with Lyra.",         "bg": "res://storyline/Backgrounds/3_two_ships.png"       },
	{ "num": "06", "title": "THE  CHOICE",     "sub": "You know what has to be done.",         "bg": "res://storyline/Backgrounds/3_two_ships.png"       },
	{ "num": "07", "title": "AFTERMATH",       "sub": "Let's go home.",                        "bg": "res://storyline/Backgrounds/3_destroyed.png"       },
]

func _show_campaign_lobby() -> void:
	if _campaign_lobby != null:
		return

	_campaign_lobby = CanvasLayer.new()
	_campaign_lobby.layer = 20
	add_child(_campaign_lobby)

	# ── Full dark backdrop ────────────────────────────────────────────────────
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.01, 0.06, 0.96)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_campaign_lobby.add_child(backdrop)

	# Subtle star-scatter decoration
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 42
	var vp_sz : Vector2 = Vector2(get_viewport().size)
	for _i in 120:
		var dot := ColorRect.new()
		var sz   := rng2.randf_range(1.0, 2.5)
		dot.size    = Vector2(sz, sz)
		dot.position = Vector2(rng2.randf_range(0, vp_sz.x), rng2.randf_range(0, vp_sz.y))
		dot.color   = Color(1, 1, 1, rng2.randf_range(0.08, 0.35))
		_campaign_lobby.add_child(dot)

	# ── Root layout ───────────────────────────────────────────────────────────
	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left",   60)
	root.add_theme_constant_override("margin_right",  60)
	root.add_theme_constant_override("margin_top",    24)
	root.add_theme_constant_override("margin_bottom", 24)
	_campaign_lobby.add_child(root)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	root.add_child(vbox)

	# ── Header ────────────────────────────────────────────────────────────────
	var title_lbl := Label.new()
	title_lbl.text = "SPACE  PIRATES"
	title_lbl.add_theme_font_size_override("font_size", 58)
	title_lbl.add_theme_color_override("font_color", Color(1.0, 0.88, 0.22))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "—  SELECT  CHAPTER  —"
	sub_lbl.add_theme_font_size_override("font_size", 16)
	sub_lbl.add_theme_color_override("font_color", Color(0.45, 0.65, 1.0, 0.85))
	sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub_lbl)

	# Glowing separator
	var sep_margin := MarginContainer.new()
	sep_margin.add_theme_constant_override("margin_top",    14)
	sep_margin.add_theme_constant_override("margin_bottom", 18)
	vbox.add_child(sep_margin)
	var sep := ColorRect.new()
	sep.color = Color(1.0, 0.88, 0.22, 0.30)
	sep.custom_minimum_size = Vector2(0, 1)
	sep_margin.add_child(sep)

	# ── Card grid ─────────────────────────────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var grid_wrap := CenterContainer.new()
	grid_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_wrap.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid_wrap)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 20)
	grid_wrap.add_child(grid)

	for i in CHAPTER_META.size():
		grid.add_child(_make_chapter_card(i))

	# ── Footer row ────────────────────────────────────────────────────────────
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 0)
	vbox.add_child(footer)

	var back_btn := _make_menu_button("◀  BACK", Color(0.50, 0.55, 0.70))
	back_btn.custom_minimum_size = Vector2(140, 38)
	back_btn.add_theme_font_size_override("font_size", 15)
	back_btn.pressed.connect(func():
		_hide_campaign_lobby()
		_show_main_lobby()
	)
	footer.add_child(back_btn)

	var spacer2 := Control.new()
	spacer2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer2)

	var hint := Label.new()
	hint.text = "ESC  to close"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.35, 0.35, 0.45))
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer.add_child(hint)

func _make_chapter_card(chapter_idx: int) -> Control:
	var meta : Dictionary = CHAPTER_META[chapter_idx]

	var card := Panel.new()
	card.custom_minimum_size = Vector2(240, 185)

	var sbf := StyleBoxFlat.new()
	sbf.bg_color = Color(0.04, 0.04, 0.14, 0.97)
	sbf.set_border_width_all(2)
	sbf.border_color = Color(0.25, 0.35, 0.65, 0.55)
	sbf.set_corner_radius_all(8)
	sbf.anti_aliasing = true
	card.add_theme_stylebox_override("panel", sbf)

	# Background image
	var tex_rect := TextureRect.new()
	tex_rect.texture = load(meta["bg"])
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tex_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tex_rect.modulate = Color(1, 1, 1, 0.30)
	card.add_child(tex_rect)

	# Bottom dark fade for text legibility
	var fade := ColorRect.new()
	fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fade.color = Color(0.0, 0.0, 0.07, 0.72)
	card.add_child(fade)

	# Top-left chapter badge
	var badge_bg := ColorRect.new()
	badge_bg.color   = Color(1.0, 0.88, 0.22, 0.15)
	badge_bg.size    = Vector2(130, 22)
	badge_bg.position = Vector2(10, 10)
	card.add_child(badge_bg)

	var num_lbl := Label.new()
	num_lbl.text = "CHAPTER  %s" % meta["num"]
	num_lbl.add_theme_font_size_override("font_size", 11)
	num_lbl.add_theme_color_override("font_color", Color(1.0, 0.88, 0.22, 0.95))
	num_lbl.position = Vector2(14, 11)
	card.add_child(num_lbl)

	# Title near bottom
	var title_lbl := Label.new()
	title_lbl.text = meta["title"]
	title_lbl.add_theme_font_size_override("font_size", 17)
	title_lbl.add_theme_color_override("font_color", Color(1.0, 0.97, 0.92))
	title_lbl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	title_lbl.offset_left   = 12
	title_lbl.offset_right  = 228
	title_lbl.offset_bottom = -10
	title_lbl.offset_top    = -44
	card.add_child(title_lbl)

	# Subtitle above title
	var sub_lbl := Label.new()
	sub_lbl.text = meta["sub"]
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", Color(0.70, 0.72, 0.85, 0.80))
	sub_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub_lbl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	sub_lbl.offset_left   = 12
	sub_lbl.offset_right  = 228
	sub_lbl.offset_bottom = -46
	sub_lbl.offset_top    = -80
	card.add_child(sub_lbl)

	# Hover & click — update sbf refs captured in closure
	card.mouse_entered.connect(func():
		if not is_instance_valid(tex_rect): return
		sbf.border_color  = Color(1.0, 0.88, 0.22, 1.0)
		sbf.bg_color      = Color(0.09, 0.09, 0.22, 0.99)
		tex_rect.modulate = Color(1, 1, 1, 0.52)
		fade.color        = Color(0.0, 0.0, 0.04, 0.55)
	)
	card.mouse_exited.connect(func():
		if not is_instance_valid(tex_rect): return
		sbf.border_color  = Color(0.25, 0.35, 0.65, 0.55)
		sbf.bg_color      = Color(0.04, 0.04, 0.14, 0.97)
		tex_rect.modulate = Color(1, 1, 1, 0.30)
		fade.color        = Color(0.0, 0.0, 0.07, 0.72)
	)
	card.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT \
				and event.pressed:
			if not (slot_info.is_empty() or _all_human_ready()):
				_pending_mode    = "campaign"
				_pending_chapter = chapter_idx
				_update_lobby_status()
				return
			_hide_campaign_lobby()
			_start_campaign_at(chapter_idx)
	)

	var accent_ch := Color(0.45, 0.65, 1.0)
	_lobby_card_refs.append({ "panel": card, "sbf": sbf, "accent": accent_ch, "chapter": chapter_idx })
	if chapter_idx == 0:
		# First card — auto-focus; clear any previous refs
		_lobby_card_refs = [_lobby_card_refs.back()]
		sbf.border_color = Color(accent_ch.r, accent_ch.g, accent_ch.b, 1.0)
		sbf.bg_color     = Color(0.08, 0.08, 0.22, 0.99)
	_lobby_focus = 0
	_lobby_cols  = 4

	return card

func _hide_campaign_lobby() -> void:
	if _campaign_lobby != null:
		_campaign_lobby.queue_free()
		_campaign_lobby = null
	_lobby_card_refs.clear()
	_lobby_focus = 0

func _start_campaign_at(chapter: int) -> void:
	campaign_mode               = true
	campaign_chapter            = chapter
	_campaign_pending           = ""
	_campaign_post_game_chapter = -1
	state                       = State.CAMPAIGN
	start_hint.visible          = false
	lobby_status.text           = ""
	_play_campaign_chapter(chapter)

# ── Retry Screen ───────────────────────────────────────────────────────────────

func _show_retry_screen() -> void:
	if _retry_layer != null:
		return
	_retry_layer = CanvasLayer.new()
	_retry_layer.layer = 25
	add_child(_retry_layer)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.80)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_retry_layer.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_retry_layer.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 22)
	vbox.custom_minimum_size = Vector2(380, 0)
	center.add_child(vbox)

	var failed_lbl := Label.new()
	failed_lbl.text = "MISSION  FAILED"
	failed_lbl.add_theme_font_size_override("font_size", 52)
	failed_lbl.add_theme_color_override("font_color", Color(1.0, 0.18, 0.12))
	failed_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(failed_lbl)

	var ch_lbl := Label.new()
	ch_lbl.text = "Chapter %02d — %s" % [campaign_chapter + 1, CHAPTER_META[campaign_chapter]["title"]]
	ch_lbl.add_theme_font_size_override("font_size", 15)
	ch_lbl.add_theme_color_override("font_color", Color(0.55, 0.60, 0.80))
	ch_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(ch_lbl)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	var retry_btn := _make_menu_button("RETRY  CHAPTER", Color(1.0, 0.88, 0.22))
	retry_btn.pressed.connect(_on_retry_pressed)
	vbox.add_child(retry_btn)

	var quit_btn := _make_menu_button("QUIT  TO  LOBBY", Color(0.50, 0.55, 0.70))
	quit_btn.pressed.connect(_on_quit_campaign_pressed)
	vbox.add_child(quit_btn)

func _make_menu_button(label: String, col: Color) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(320, 52)
	btn.add_theme_font_size_override("font_size", 22)
	var sbf_n := StyleBoxFlat.new()
	sbf_n.bg_color = Color(col.r, col.g, col.b, 0.12)
	sbf_n.set_border_width_all(2)
	sbf_n.border_color = Color(col.r, col.g, col.b, 0.55)
	sbf_n.set_corner_radius_all(6)
	var sbf_h := StyleBoxFlat.new()
	sbf_h.bg_color = Color(col.r, col.g, col.b, 0.28)
	sbf_h.set_border_width_all(2)
	sbf_h.border_color = Color(col.r, col.g, col.b, 1.0)
	sbf_h.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("normal",  sbf_n)
	btn.add_theme_stylebox_override("hover",   sbf_h)
	btn.add_theme_stylebox_override("pressed", sbf_h)
	btn.add_theme_color_override("font_color",       col)
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	return btn

func _hide_retry_screen() -> void:
	if _retry_layer != null:
		_retry_layer.queue_free()
		_retry_layer = null

func _on_retry_pressed() -> void:
	_hide_retry_screen()
	_campaign_post_game_chapter = campaign_chapter
	_reset_to_lobby()

func _on_quit_campaign_pressed() -> void:
	_hide_retry_screen()
	campaign_mode = false
	_campaign_post_game_chapter = -1
	_reset_to_lobby()

# ── Main Lobby ────────────────────────────────────────────────────────────────

const MODE_CARDS := [
	{ "title": "CAMPAIGN",   "sub": "The full story.\n7 chapters of space piracy.",  "bg": "res://storyline/Backgrounds/1a_b.png",         "accent": Color(1.00, 0.88, 0.22), "action": "campaign" },
	{ "title": "SWARM",      "sub": "Outrun the\nEmpire's fleet.",                   "bg": "res://storyline/Backgrounds/mothership.png",    "accent": Color(0.25, 0.80, 1.00), "action": "escape"   },
	{ "title": "SIEGE",      "sub": "Destroy the\nmothership.",                      "bg": "res://storyline/Backgrounds/mothership.png",    "accent": Color(1.00, 0.28, 0.18), "action": "siege"    },
	{ "title": "RACE",       "sub": "First to the\nfinish line.",                    "bg": "res://storyline/Backgrounds/3_two_ships.png",   "accent": Color(0.18, 1.00, 0.42), "action": "race"     },
	{ "title": "PvP",        "sub": "Free-for-all.\nNo rules.",                      "bg": "res://storyline/Backgrounds/3_destroyed.png",   "accent": Color(1.00, 0.38, 0.90), "action": "pvp"      },
	{ "title": "BOT BATTLE", "sub": "Fight the\nmachine.",                           "bg": "res://storyline/Backgrounds/rebel_base.png",    "accent": Color(0.60, 0.60, 1.00), "action": "bot"      },
]

func _show_main_lobby() -> void:
	if _main_lobby_layer != null:
		return

	_main_lobby_layer = CanvasLayer.new()
	_main_lobby_layer.layer = 15
	add_child(_main_lobby_layer)

	# Semi-transparent dark overlay — 3D world visible behind
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.01, 0.06, 0.87)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_main_lobby_layer.add_child(bg)

	# Star scatter
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 99
	var vp_sz : Vector2 = Vector2(get_viewport().size)
	for _i in 140:
		var dot  := ColorRect.new()
		var sz   := rng2.randf_range(1.0, 2.8)
		dot.size     = Vector2(sz, sz)
		dot.position = Vector2(rng2.randf_range(0, vp_sz.x), rng2.randf_range(0, vp_sz.y))
		dot.color    = Color(1, 1, 1, rng2.randf_range(0.06, 0.32))
		_main_lobby_layer.add_child(dot)

	# Root layout
	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left",   70)
	root.add_theme_constant_override("margin_right",  70)
	root.add_theme_constant_override("margin_top",    20)
	root.add_theme_constant_override("margin_bottom", 20)
	_main_lobby_layer.add_child(root)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	root.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "SPACE  PIRATES"
	title.add_theme_font_size_override("font_size", 62)
	title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.22))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var tagline := Label.new()
	tagline.text = "—  CHOOSE  YOUR  MISSION  —"
	tagline.add_theme_font_size_override("font_size", 15)
	tagline.add_theme_color_override("font_color", Color(0.45, 0.65, 1.0, 0.80))
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(tagline)

	var sep_margin := MarginContainer.new()
	sep_margin.add_theme_constant_override("margin_top",    14)
	sep_margin.add_theme_constant_override("margin_bottom", 18)
	vbox.add_child(sep_margin)
	var sep := ColorRect.new()
	sep.color = Color(1.0, 0.88, 0.22, 0.28)
	sep.custom_minimum_size = Vector2(0, 1)
	sep_margin.add_child(sep)

	# Cards grid
	var grid_wrap := CenterContainer.new()
	grid_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_wrap.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.add_child(grid_wrap)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 22)
	grid.add_theme_constant_override("v_separation", 22)
	grid_wrap.add_child(grid)

	for i in MODE_CARDS.size():
		grid.add_child(_make_mode_card(i))

	# Footer: server hint
	var footer_lbl := Label.new()
	footer_lbl.text = "Connect phone controllers at  localhost:4000"
	footer_lbl.add_theme_font_size_override("font_size", 12)
	footer_lbl.add_theme_color_override("font_color", Color(0.30, 0.30, 0.42))
	footer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(footer_lbl)

func _make_mode_card(idx: int) -> Control:
	var meta    : Dictionary = MODE_CARDS[idx]
	var accent  : Color      = meta["accent"]

	var card := Panel.new()
	card.custom_minimum_size = Vector2(280, 195)

	var sbf := StyleBoxFlat.new()
	sbf.bg_color = Color(0.04, 0.04, 0.13, 0.97)
	sbf.set_border_width_all(2)
	sbf.border_color = Color(accent.r, accent.g, accent.b, 0.45)
	sbf.set_corner_radius_all(8)
	sbf.anti_aliasing = true
	card.add_theme_stylebox_override("panel", sbf)

	var tex_rect := TextureRect.new()
	tex_rect.texture     = load(meta["bg"])
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tex_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tex_rect.modulate    = Color(1, 1, 1, 0.28)
	card.add_child(tex_rect)

	var fade := ColorRect.new()
	fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fade.color = Color(0.0, 0.0, 0.07, 0.70)
	card.add_child(fade)

	# Accent bar at top
	var bar := ColorRect.new()
	bar.color = Color(accent.r, accent.g, accent.b, 0.70)
	bar.size     = Vector2(280, 3)
	bar.position = Vector2(0, 0)
	card.add_child(bar)

	var title_lbl := Label.new()
	title_lbl.text = meta["title"]
	title_lbl.add_theme_font_size_override("font_size", 28)
	title_lbl.add_theme_color_override("font_color", Color(accent.r, accent.g, accent.b, 1.0))
	title_lbl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	title_lbl.offset_left   = 14
	title_lbl.offset_right  = 266
	title_lbl.offset_bottom = -10
	title_lbl.offset_top    = -52
	card.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = meta["sub"]
	sub_lbl.add_theme_font_size_override("font_size", 11)
	sub_lbl.add_theme_color_override("font_color", Color(0.72, 0.74, 0.88, 0.80))
	sub_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub_lbl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	sub_lbl.offset_left   = 14
	sub_lbl.offset_right  = 266
	sub_lbl.offset_bottom = -55
	sub_lbl.offset_top    = -95
	card.add_child(sub_lbl)

	card.mouse_entered.connect(func():
		if not is_instance_valid(tex_rect): return
		sbf.border_color  = Color(accent.r, accent.g, accent.b, 1.0)
		sbf.bg_color      = Color(accent.r * 0.12, accent.g * 0.12, accent.b * 0.18, 0.99)
		tex_rect.modulate = Color(1, 1, 1, 0.50)
		bar.color         = Color(accent.r, accent.g, accent.b, 1.0)
	)
	card.mouse_exited.connect(func():
		if not is_instance_valid(tex_rect): return
		sbf.border_color  = Color(accent.r, accent.g, accent.b, 0.45)
		sbf.bg_color      = Color(0.04, 0.04, 0.13, 0.97)
		tex_rect.modulate = Color(1, 1, 1, 0.28)
		bar.color         = Color(accent.r, accent.g, accent.b, 0.70)
	)
	card.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT \
				and event.pressed:
			_on_mode_card_clicked(meta["action"])
	)

	_lobby_card_refs.append({ "panel": card, "sbf": sbf, "accent": accent, "action": meta["action"] })
	if _lobby_card_refs.size() == 1:
		# First card — auto-focus
		sbf.border_color = Color(accent.r, accent.g, accent.b, 1.0)
		sbf.bg_color     = Color(accent.r * 0.14, accent.g * 0.14, accent.b * 0.20, 0.99)
	_lobby_cols = 3

	return card

func _on_mode_card_clicked(action: String) -> void:
	if not (slot_info.is_empty() or _all_human_ready()):
		_pending_mode    = action
		_pending_chapter = -1
		_update_lobby_status()
		return
	_pending_mode = ""
	match action:
		"campaign":
			_hide_main_lobby()
			_show_campaign_lobby()
		"escape":
			_hide_main_lobby()
			_start_escape()
		"siege":
			_hide_main_lobby()
			_pending_siege = true
			_start_countdown()
		"race":
			_hide_main_lobby()
			_start_race()
		"pvp":
			_hide_main_lobby()
			_start_playground()
		"bot":
			_hide_main_lobby()
			_start_countdown()

func _hide_main_lobby() -> void:
	if _main_lobby_layer != null:
		_main_lobby_layer.queue_free()
		_main_lobby_layer = null
	_lobby_card_refs.clear()
	_lobby_focus = 0

# ── Lobby keyboard navigation ─────────────────────────────────────────────────

func _lobby_set_focus(idx: int) -> void:
	if _lobby_card_refs.is_empty():
		return
	# Reset old
	var old : Dictionary = _lobby_card_refs[_lobby_focus]
	var oa  : Color      = old["accent"]
	old["sbf"].border_color = Color(oa.r, oa.g, oa.b, 0.45)
	old["sbf"].bg_color     = Color(0.04, 0.04, 0.13, 0.97)
	# Apply new
	_lobby_focus = clampi(idx, 0, _lobby_card_refs.size() - 1)
	var nw : Dictionary = _lobby_card_refs[_lobby_focus]
	var na : Color      = nw["accent"]
	nw["sbf"].border_color = Color(na.r, na.g, na.b, 1.0)
	nw["sbf"].bg_color     = Color(na.r * 0.14, na.g * 0.14, na.b * 0.20, 0.99)

func _lobby_move_focus(delta: int) -> void:
	var next : int = _lobby_focus + delta
	next = clampi(next, 0, _lobby_card_refs.size() - 1)
	_lobby_set_focus(next)

func _lobby_activate(idx: int) -> void:
	if idx < 0 or idx >= _lobby_card_refs.size():
		return
	var entry : Dictionary = _lobby_card_refs[idx]
	if entry.has("action"):
		_on_mode_card_clicked(entry["action"])
	elif entry.has("chapter"):
		_hide_campaign_lobby()
		_start_campaign_at(entry["chapter"])

# ── Pilot mode selection ──────────────────────────────────────────────────────

func _on_pilot_mode_selected(mode: String, chapter: int) -> void:
	if state != State.LOBBY:
		return
	_pending_mode    = mode
	_pending_chapter = chapter
	_update_lobby_status()
	# Start immediately only if all connected pilots are already ready
	if _all_human_ready():
		_trigger_pending_mode()

func _trigger_pending_mode() -> void:
	var mode    := _pending_mode
	var chapter := _pending_chapter
	_pending_mode    = ""
	_pending_chapter = -1
	if mode == "campaign":
		_hide_campaign_lobby()
		_start_campaign_at(chapter)
	else:
		_on_mode_card_clicked(mode)

func _get_dialogic() -> Node:
	return get_node_or_null("/root/Dialogic")

func _play_campaign_chapter(chapter: int) -> void:
	campaign_chapter = chapter
	var dlg := _get_dialogic()
	if dlg == null:
		push_error("Dialogic autoload not found — is the addon enabled?")
		campaign_mode = false
		_reset_to_lobby()
		return
	if not dlg.signal_event.is_connected(_on_dialogic_signal):
		dlg.signal_event.connect(_on_dialogic_signal)
	if not dlg.timeline_ended.is_connected(_on_dialogic_timeline_ended):
		dlg.timeline_ended.connect(_on_dialogic_timeline_ended)
	dlg.start(CAMPAIGN_CHAPTERS[chapter])
	_show_skip_button()

func _on_dialogic_signal(argument: String) -> void:
	match argument:
		"start_race":
			_campaign_pending           = "race"
			_campaign_post_game_chapter = campaign_chapter + 1
		"start_siege":
			_campaign_pending           = "siege"
			_campaign_post_game_chapter = campaign_chapter + 1
		"lyra_possessed":
			_campaign_pending = "next_chapter"
		"start_pvp":
			_campaign_pending           = "pvp"
			_campaign_post_game_chapter = campaign_chapter + 1
		"chapter_complete":
			if campaign_chapter + 1 < CAMPAIGN_CHAPTERS.size():
				_campaign_pending = "next_chapter"
			else:
				_campaign_pending = "done"

func _show_skip_button() -> void:
	if _skip_btn_layer != null:
		return
	_skip_btn_layer = CanvasLayer.new()
	_skip_btn_layer.layer = 30
	add_child(_skip_btn_layer)

	var btn := _make_menu_button("SKIP  ▶▶", Color(0.55, 0.55, 0.70))
	btn.custom_minimum_size = Vector2(130, 38)
	btn.add_theme_font_size_override("font_size", 14)
	btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	btn.offset_left   = -150
	btn.offset_top    = -58
	btn.offset_right  = -20
	btn.offset_bottom = -20
	btn.pressed.connect(_on_skip_pressed)
	_skip_btn_layer.add_child(btn)

func _hide_skip_button() -> void:
	if _skip_btn_layer != null:
		_skip_btn_layer.queue_free()
		_skip_btn_layer = null

func _on_skip_pressed() -> void:
	_hide_skip_button()
	# Signal may not have fired yet — apply what this chapter would have triggered
	if _campaign_pending.is_empty():
		match campaign_chapter:
			0:  # chapter_1a → swarm
				_campaign_pending           = "race"
				_campaign_post_game_chapter = 1
			1:  # chapter_1b → next chapter
				_campaign_pending = "next_chapter"
			2:  # chapter_2a → siege
				_campaign_pending           = "siege"
				_campaign_post_game_chapter = 3
			3:  # chapter_2b → next chapter
				_campaign_pending = "next_chapter"
			4:  # chapter_3a → next chapter
				_campaign_pending = "next_chapter"
			5:  # chapter_3b → pvp
				_campaign_pending           = "pvp"
				_campaign_post_game_chapter = 6
			6:  # chapter_3c → done
				_campaign_pending = "done"
	var dlg := _get_dialogic()
	if dlg != null:
		dlg.end_timeline()

func _on_dialogic_timeline_ended() -> void:
	_hide_skip_button()
	match _campaign_pending:
		"race":
			_campaign_pending = ""
			_start_escape()
		"siege":
			_campaign_pending  = ""
			_pending_siege     = true
			_start_countdown()
		"pvp":
			_campaign_pending = ""
			_start_playground()
		"next_chapter":
			_campaign_pending  = ""
			campaign_chapter  += 1
			_play_campaign_chapter(campaign_chapter)
		"done":
			_campaign_pending  = ""
			campaign_mode      = false
			_reset_to_lobby()

# ── Countdown ─────────────────────────────────────────────────────────────────

func _start_countdown() -> void:
	_hide_main_lobby()
	state           = State.COUNTDOWN
	countdown_val   = 3
	countdown_timer = 1.0
	countdown_label.text    = str(countdown_val)
	countdown_label.visible = true
	start_hint.visible      = false
	lobby_status.text       = ""
	_spawn_ships()
	_spawn_bot()   # Bot mode always has a bot
	_build_split_screen()

func _tick_countdown(delta: float) -> void:
	countdown_timer -= delta
	if countdown_timer > 0.0:
		return
	countdown_val  -= 1
	countdown_timer = 1.0
	if countdown_val <= 0:
		countdown_label.text = "GO!"
		get_tree().create_timer(0.6).timeout.connect(_begin_playing)
	else:
		countdown_label.text = str(countdown_val)

func _begin_playing() -> void:
	if _pending_race:
		state         = State.RACE
		_pending_race = false
	elif _pending_escape:
		state           = State.ESCAPE
		_pending_escape = false
	elif _pending_siege:
		state          = State.SIEGE
		_pending_siege = false
		_start_siege()
	else:
		state = State.PLAYING
	countdown_label.visible = false
	bridge.send({ "type": "game_start" })

func _start_playground() -> void:
	_hide_main_lobby()
	state = State.PLAYGROUND
	start_hint.visible       = false
	playground_label.visible = true
	lobby_status.text        = ""
	_spawn_ships()
	# No bot, no invincibility — players fight each other freely
	_build_split_screen()
	bridge.send({ "type": "game_start" })

# ── Ship spawning ─────────────────────────────────────────────────────────────

# Returns the keyboard binding dict for a given local player index (0-3).
func _kb_set(i: int) -> Dictionary:
	match i % 4:
		0: return { "left": KEY_A,    "right": KEY_D,     "thrust": KEY_W,    "brake": KEY_S,    "fire": KEY_CTRL,  "special": KEY_E        }
		1: return { "left": KEY_LEFT, "right": KEY_RIGHT, "thrust": KEY_UP,   "brake": KEY_DOWN, "fire": KEY_SHIFT, "special": KEY_ENTER    }
		2: return { "left": KEY_J,    "right": KEY_L,     "thrust": KEY_I,    "brake": KEY_K,    "fire": KEY_U,     "special": KEY_O        }
		_: return { "left": KEY_KP_4, "right": KEY_KP_6,  "thrust": KEY_KP_8, "brake": KEY_KP_5, "fire": KEY_KP_0,  "special": KEY_KP_ENTER }

func _kb_ship_id(i: int) -> String:
	return (["corsair", "dreadnought", "phantom", "scavenger"])[i % 4]

func _kb_hint(i: int) -> String:
	return ([
		"Move:WASD  Fire:Ctrl  Spec:E",
		"Move:Arrows  Fire:Shift  Spec:Enter",
		"Move:IJKL  Fire:U  Spec:O",
		"Move:Num8/4/6  Fire:Num0  Spec:N.Enter",
	])[i % 4]

func _spawn_ships() -> void:
	active_ships.clear()
	human_ships.clear()
	kb_players.clear()
	kb_ship = null

	var live_slots := slot_info.keys().filter(
		func(k): return slot_info[k].ship_id != "")

	if live_slots.is_empty():
		# ── No phones: keyboard debug player ────────────────────────────────
		var ship : Ship = ship_scene.instantiate()
		ships_node.add_child(ship)
		ship.position    = Vector3(0.0, 0.0, 18.0)
		ship.rotation.y  = PI
		ship.setup(0, "corsair", projectile_scene, projectiles_node)
		ship.all_ships   = active_ships
		ship.died.connect(_on_ship_died)
		ship.set_meta("controls_hint", _kb_hint(0))
		active_ships.append(ship)
		human_ships.append(ship)
		kb_players.append({ "ship": ship, "keys": _kb_set(0) })
		kb_ship = ship
		return

	# ── Phone players — split screen sized automatically ─────────────────────
	var n := live_slots.size()
	for i in n:
		var sl   : int  = live_slots[i]
		var info        = slot_info[sl]
		var ship : Ship = ship_scene.instantiate()
		ships_node.add_child(ship)
		var angle       := float(i) / float(max(n, 2)) * TAU
		ship.position    = Vector3(cos(angle) * 14.0, 0.0, sin(angle) * 14.0)
		ship.rotation.y  = angle + PI
		ship.setup(sl, info.ship_id, projectile_scene, projectiles_node)
		ship.all_ships   = active_ships
		ship.died.connect(_on_ship_died)
		info.ship_node   = ship
		active_ships.append(ship)
		human_ships.append(ship)

# ── Split screen ──────────────────────────────────────────────────────────────

func _build_split_screen() -> void:
	for vd in vp_data:
		vd.sub_container.queue_free()
	vp_data.clear()

	var n      := maxi(human_ships.size(), 1)
	var screen := get_viewport().get_visible_rect().size
	var rects  := _split_rects(n, screen)

	for i in human_ships.size():
		var ship : Ship  = human_ships[i]
		var rect : Rect2 = rects[i]

		var sub_c        := SubViewportContainer.new()
		sub_c.position    = rect.position
		sub_c.size        = rect.size
		sub_c.stretch     = true
		viewport_layer.add_child(sub_c)

		var sub_vp        := SubViewport.new()
		sub_vp.size        = Vector2i(int(rect.size.x), int(rect.size.y))
		sub_vp.own_world_3d = false   # share the main world so all ships are visible
		sub_c.add_child(sub_vp)

		var cam   := Camera3D.new()
		cam.fov    = 72.0
		sub_vp.add_child(cam)

		# ── 2D HUD overlay inside this pane ───────────────────────────────────
		var hud := Control.new()
		hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sub_c.add_child(hud)

		# Player colour strip (top edge)
		var strip   := ColorRect.new()
		strip.color  = Color(PLAYER_COLORS[ship.slot])
		strip.size   = Vector2(rect.size.x, 4)
		hud.add_child(strip)

		# Player name label
		var name_lbl := Label.new()
		name_lbl.text = "P%d  %s" % [ship.slot + 1, ship.ship_id.to_upper()]
		name_lbl.add_theme_font_size_override("font_size", 18)
		name_lbl.add_theme_color_override("font_color", Color(PLAYER_COLORS[ship.slot]))
		name_lbl.position = Vector2(8, 8)
		hud.add_child(name_lbl)

		# Controls hint (only shown for keyboard players)
		var hint_str : String = ship.get_meta("controls_hint", "")
		if not hint_str.is_empty():
			var hint_lbl := Label.new()
			hint_lbl.text = hint_str
			hint_lbl.add_theme_font_size_override("font_size", 11)
			hint_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
			hint_lbl.position = Vector2(8, 30)
			hud.add_child(hint_lbl)

		# Own HP bar (bottom-centre)
		var bar_w  := minf(rect.size.x * 0.55, 280.0)
		var bar_h  := 14.0
		var bar_x  := (rect.size.x - bar_w) * 0.5
		var bar_y  := rect.size.y - 32.0

		var hp_bg  := ColorRect.new()
		hp_bg.color    = Color(0.08, 0.08, 0.08, 0.75)
		hp_bg.size     = Vector2(bar_w, bar_h)
		hp_bg.position = Vector2(bar_x, bar_y)
		hud.add_child(hp_bg)

		var hp_fill := ColorRect.new()
		hp_fill.color = Color(0.2, 1.0, 0.3)
		hp_fill.size  = Vector2(bar_w, bar_h)
		hp_bg.add_child(hp_fill)

		var hp_lbl := Label.new()
		hp_lbl.text = "HP"
		hp_lbl.add_theme_font_size_override("font_size", 11)
		hp_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		hp_lbl.position = Vector2(bar_x - 26, bar_y)
		hud.add_child(hp_lbl)

		# Enemy HP bars (top-right)
		var enemy_fills : Array = []
		var ey := 28.0
		for other in active_ships:
			if other == ship:
				continue
			var e_w := 80.0
			var e_h := 8.0
			var e_x := rect.size.x - e_w - 8.0

			var e_lbl := Label.new()
			e_lbl.text = "BOT" if other.slot == BOT_SLOT else "P%d" % (other.slot + 1)
			e_lbl.add_theme_font_size_override("font_size", 10)
			e_lbl.add_theme_color_override("font_color", Color(PLAYER_COLORS[other.slot]))
			e_lbl.position = Vector2(e_x - 28, ey - 1)
			hud.add_child(e_lbl)

			var e_bg := ColorRect.new()
			e_bg.color    = Color(0.08, 0.08, 0.08, 0.75)
			e_bg.size     = Vector2(e_w, e_h)
			e_bg.position = Vector2(e_x, ey)
			hud.add_child(e_bg)

			var e_fill := ColorRect.new()
			e_fill.color = Color(PLAYER_COLORS[other.slot])
			e_fill.size  = Vector2(e_w, e_h)
			e_bg.add_child(e_fill)

			enemy_fills.append({ "fill": e_fill, "ship": other, "max_w": e_w })
			ey += e_h + 6.0

		var vd_entry := {
			"sub_container": sub_c,
			"sub_vp":        sub_vp,
			"cam":           cam,
			"ship":          ship,
			"hp_fill":       hp_fill,
			"hp_max_w":      bar_w,
			"enemy_fills":   enemy_fills,
		}
		if state == State.RACE or _pending_escape:
			var race_lbl := Label.new()
			race_lbl.text = "CP 0/10"
			race_lbl.add_theme_font_size_override("font_size", 20)
			race_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.0))
			race_lbl.position = Vector2(8, 50)
			hud.add_child(race_lbl)
			vd_entry["race_lbl"] = race_lbl
		vp_data.append(vd_entry)

func _split_rects(n: int, s: Vector2) -> Array:
	var w := s.x; var h := s.y
	match n:
		1: return [Rect2(0, 0, w, h)]
		2: return [Rect2(0, 0, w/2, h), Rect2(w/2, 0, w/2, h)]
		3: return [Rect2(0, 0, w/2, h/2), Rect2(w/2, 0, w/2, h/2), Rect2(0, h/2, w, h/2)]
		4: return [Rect2(0, 0, w/2, h/2), Rect2(w/2, 0, w/2, h/2),
				   Rect2(0, h/2, w/2, h/2), Rect2(w/2, h/2, w/2, h/2)]
		5: return [Rect2(0, 0, w/2, h/2), Rect2(w/2, 0, w/2, h/2),
				   Rect2(0, h/2, w/3, h/2), Rect2(w/3, h/2, w/3, h/2), Rect2(2*w/3, h/2, w/3, h/2)]
		_: return [Rect2(0, 0, w, h)]

# ── Win / reset ───────────────────────────────────────────────────────────────

func _on_ship_died(_slot: int) -> void:
	if state == State.PLAYGROUND:
		return
	if state == State.SIEGE:
		# Player died — check if all players are gone
		var alive_players := active_ships.filter(func(s):
			return is_instance_valid(s) and s.alive and s.team == 0)
		if alive_players.is_empty():
			_end_game(-1)
		return
	if state == State.RACE:
		var race_survivors := active_ships.filter(func(s): return is_instance_valid(s) and s.alive)
		if race_survivors.size() <= 1:
			var winner_slot : int = race_survivors[0].slot if race_survivors.size() == 1 else -1
			_end_game(winner_slot)
		return
	if state == State.ESCAPE:
		if _slot >= BOT_SLOT:
			_on_escape_bot_died(_slot)   # bot destroyed — schedule respawn
			return
		# A player died — check if all players are eliminated
		var alive_players := active_ships.filter(func(s):
			return is_instance_valid(s) and s.alive and s.team == 0)
		if alive_players.is_empty():
			_end_game(-1)   # no survivors
		return
	if state != State.PLAYING:
		return
	var survivors := active_ships.filter(
		func(s): return is_instance_valid(s) and s.alive)
	if survivors.size() <= 1:
		var winner_slot : int = survivors[0].slot if survivors.size() == 1 else -1
		_end_game(winner_slot)

func _end_game(winner_slot: int) -> void:
	# Campaign failure — show retry screen instead of auto-advancing
	if campaign_mode and winner_slot == -1:
		state = State.WIN
		_show_retry_screen()
		bridge.send({ "type": "game_over", "winnerSlot": -1 })
		return

	if minimap_node and is_instance_valid(minimap_node):
		minimap_node.visible = false

	state     = State.WIN
	win_timer = 5.0 if campaign_mode else 7.0

	if winner_slot == BOT_SLOT:
		win_label.text = "BOT WINS!  (R to retry)"
		win_label.add_theme_color_override("font_color", Color(PLAYER_COLORS[BOT_SLOT]))
	elif winner_slot >= 0:
		win_label.text = "PLAYER %d WINS!" % (winner_slot + 1)
		win_label.add_theme_color_override("font_color", Color(PLAYER_COLORS[winner_slot]))
	else:
		win_label.text = "DRAW!"
	win_label.visible = true

	bridge.send({ "type": "game_over", "winnerSlot": winner_slot })

func _tick_win(delta: float) -> void:
	if _retry_layer != null:
		return  # retry screen open — wait for player input
	win_timer -= delta
	if win_timer <= 0.0:
		_reset_to_lobby()

func _reset_to_lobby() -> void:
	win_label.visible        = false
	playground_label.visible = false
	lobby_status.text        = ""
	_hide_retry_screen()

	for vd in vp_data:
		vd.sub_container.queue_free()
	vp_data.clear()

	if race_track_node and is_instance_valid(race_track_node):
		race_track_node.queue_free()
		race_track_node = null
	if minimap_node and is_instance_valid(minimap_node):
		minimap_node.get_parent().queue_free()
		minimap_node = null
	ship_checkpoint.clear()
	race_finished_slots.clear()
	_pending_race    = false
	_pending_escape  = false
	_pending_siege   = false
	_pending_mode    = ""
	_pending_chapter = -1
	escape_bots.clear()
	escape_bot_speed = 0.0

	# Clean up siege
	if is_instance_valid(siege_mothership):
		siege_mothership.queue_free()
	siege_mothership = null
	for m in siege_minions:
		if is_instance_valid(m):
			m.queue_free()
	siege_minions.clear()
	if is_instance_valid(_ms_hp_label):
		_ms_hp_label.queue_free()
	_ms_hp_label = null

	for ship in active_ships:
		if is_instance_valid(ship):
			ship.queue_free()
	active_ships.clear()
	human_ships.clear()
	kb_players.clear()
	kb_ship   = null
	bot_ship  = null
	bot_timer = 0.0

	for k in slot_info.keys():
		slot_info[k].ship_node = null
		slot_info[k].ready     = false

	for p in projectiles_node.get_children():
		p.queue_free()
	bridge.send({ "type": "lobby_reset" })

	# If a campaign chapter should follow this gameplay section, play it now
	if campaign_mode and _campaign_post_game_chapter >= 0:
		var next_ch := _campaign_post_game_chapter
		_campaign_post_game_chapter = -1
		state = State.CAMPAIGN
		start_hint.visible = false
		_play_campaign_chapter(next_ch)
		return

	campaign_mode      = false
	state              = State.LOBBY
	start_hint.visible = false
	_show_main_lobby()

# ── HP bar updates ────────────────────────────────────────────────────────────

func _update_hp_bars() -> void:
	for vd in vp_data:
		var ship = vd["ship"]
		if not is_instance_valid(ship):
			continue

		var pct  : float    = clampf(float(ship.hp) / float(ship.max_hp), 0.0, 1.0)
		var fill : ColorRect = vd["hp_fill"]
		fill.size.x = vd["hp_max_w"] * pct
		if pct > 0.5:
			fill.color = Color(0.2, 1.0, 0.3)
		elif pct > 0.25:
			fill.color = Color(1.0, 0.75, 0.0)
		else:
			fill.color = Color(1.0, 0.15, 0.15)

		for ed in vd["enemy_fills"]:
			var es = ed["ship"]
			if not is_instance_valid(es) or not es.alive:
				ed["fill"].size.x = 0.0
				continue
			var epct := clampf(float(es.hp) / float(es.max_hp), 0.0, 1.0)
			ed["fill"].size.x = ed["max_w"] * epct

# ── Keyboard player(s) ────────────────────────────────────────────────────────

func _tick_kb() -> void:
	for kp in kb_players:
		var raw = kp["ship"]
		if not is_instance_valid(raw):
			continue
		var ship : Ship = raw
		if not ship.alive:
			continue
		var keys   = kp["keys"]
		var rot    := 0.0
		var thrust := 1.0
		if Input.is_key_pressed(keys.left):  rot    =  1.0
		if Input.is_key_pressed(keys.right): rot    = -1.0
		if Input.is_key_pressed(keys.brake): thrust = -0.5
		var firing := Input.is_key_pressed(keys.fire)
		var burst  := Input.is_key_pressed(keys.special)
		ship.set_input(rot, thrust, firing, burst)

# ── Bot ───────────────────────────────────────────────────────────────────────

func _spawn_bot() -> void:
	var ship : Ship = ship_scene.instantiate()
	ships_node.add_child(ship)
	ship.position    = Vector3(0.0, 0.0, -18.0)
	ship.rotation.y  = 0.0
	ship.setup(BOT_SLOT, "corsair", projectile_scene, projectiles_node)
	ship.all_ships   = active_ships
	ship.died.connect(_on_ship_died)
	active_ships.append(ship)
	bot_ship = ship

func _tick_bot(delta: float) -> void:
	if not bot_ship or not is_instance_valid(bot_ship) or not bot_ship.alive:
		return

	bot_timer += delta
	var target := _bot_find_target()
	if not target:
		bot_ship.set_input(0.0, 0.2, false, false)
		return

	var to_target := target.global_position - bot_ship.global_position
	var distance  := to_target.length()
	var dir_flat  := Vector2(to_target.x, to_target.z).normalized()
	var fwd       := -bot_ship.transform.basis.z
	var fwd_flat  := Vector2(fwd.x, fwd.z).normalized()

	var angle     := fwd_flat.angle_to(dir_flat)
	var rot_input := clampf(angle * 2.5, -1.0, 1.0)

	var facing := fwd_flat.dot(dir_flat)
	var thrust := 0.7 if (facing > 0.4 and distance > 12.0) else 0.0
	var firing := absf(angle) < 0.3 and distance < 60.0

	var burst := false
	if bot_timer >= 10.0:
		burst     = true
		bot_timer = 0.0

	bot_ship.set_input(rot_input, thrust, firing, burst)

func _bot_find_target() -> Ship:
	var best   : Ship = null
	var best_d := INF
	for s in active_ships:
		if s == bot_ship or not is_instance_valid(s) or not s.alive:
			continue
		var d := bot_ship.global_position.distance_to(s.global_position)
		if d < best_d:
			best_d = d
			best   = s
	return best

# ── Race Mode ─────────────────────────────────────────────────────────────────

func _start_race() -> void:
	_hide_main_lobby()
	state            = State.COUNTDOWN
	_pending_race    = true
	countdown_val    = 3
	countdown_timer  = 1.0
	countdown_label.text    = str(countdown_val)
	countdown_label.visible = true
	start_hint.visible       = false
	playground_label.visible = false
	lobby_status.text        = ""
	ship_checkpoint.clear()
	race_finished_slots.clear()
	_spawn_ships_race()
	_build_race_track()
	_build_split_screen()

func _spawn_ships_race() -> void:
	active_ships.clear()
	human_ships.clear()
	kb_players.clear()
	kb_ship = null

	var start_base : Vector3 = TRACK_WAYPOINTS[0]
	var track_dir  : Vector3 = ((TRACK_WAYPOINTS[1] as Vector3) - start_base).normalized()
	var spawn_yaw  : float   = atan2(track_dir.x, -track_dir.z)  # angle to face track direction
	# Stagger grid perpendicular to track direction
	var perp := Vector3(-track_dir.z, 0, track_dir.x)
	var start_off := [
		perp * -10.0 + track_dir *   0.0,
		perp *  10.0 + track_dir *   0.0,
		perp * -10.0 + track_dir * -22.0,
		perp *  10.0 + track_dir * -22.0,
		perp *   0.0 + track_dir * -44.0,
	]

	var live_slots := slot_info.keys().filter(func(k): return slot_info[k].ship_id != "")

	if live_slots.is_empty():
		var ship : Ship = ship_scene.instantiate()
		ships_node.add_child(ship)
		ship.position   = start_base
		ship.rotation.y = spawn_yaw
		ship.setup(0, "corsair", projectile_scene, projectiles_node)
		ship.speed     *= 2.5
		ship.race_mode  = true
		ship.all_ships  = active_ships
		ship.died.connect(_on_ship_died)
		active_ships.append(ship)
		human_ships.append(ship)
		kb_players.append({ "ship": ship, "keys": _kb_set(0) })
		kb_ship = ship
		ship_checkpoint[0] = 1
		return

	var n := live_slots.size()
	for i in n:
		var sl    : int = live_slots[i]
		var info   = slot_info[sl]
		var ship : Ship = ship_scene.instantiate()
		ships_node.add_child(ship)
		ship.position   = start_base + start_off[i % start_off.size()]
		ship.rotation.y = spawn_yaw
		ship.setup(sl, info.ship_id, projectile_scene, projectiles_node)
		ship.speed     *= 2.5
		ship.race_mode  = true
		ship.all_ships  = active_ships
		ship.died.connect(_on_ship_died)
		info.ship_node  = ship
		active_ships.append(ship)
		human_ships.append(ship)
		ship_checkpoint[sl] = 1

func _build_race_track() -> void:
	if race_track_node and is_instance_valid(race_track_node):
		race_track_node.queue_free()
	race_track_node      = Node3D.new()
	race_track_node.name = "RaceTrack"
	add_child(race_track_node)

	var rng := RandomNumberGenerator.new()
	rng.seed = 1337

	# Dense asteroid walls — along segments
	for i in range(TRACK_WAYPOINTS.size() - 1):
		var p0  : Vector3 = TRACK_WAYPOINTS[i]
		var p1  : Vector3 = TRACK_WAYPOINTS[i + 1]
		var dir  := (p1 - p0).normalized()
		var perp := Vector3(-dir.z, 0.0, dir.x)
		var steps := int(p0.distance_to(p1) / 6.0) + 1
		for j in steps:
			var t      := float(j) / float(max(steps - 1, 1))
			var center := p0.lerp(p1, t)
			for side in [-1, 1]:
				for row in [0, 1, 2]:
					var offset : float = TRACK_HALF_WIDTH + float(row) * 6.0
					var bpos : Vector3 = center + perp * offset * float(side)
					bpos.y = 0.0
					_place_boundary_asteroid(race_track_node, bpos,
						rng.randf_range(2.5, 5.5), rng)

	# Fill corner gaps — extra asteroids fanned around each interior waypoint
	for i in range(1, TRACK_WAYPOINTS.size() - 1):
		var wp     : Vector3 = TRACK_WAYPOINTS[i]
		var d_in   : Vector3 = (wp - (TRACK_WAYPOINTS[i - 1] as Vector3)).normalized()
		var d_out  : Vector3 = ((TRACK_WAYPOINTS[i + 1] as Vector3) - wp).normalized()
		# Average perpendicular at this corner
		var avg_d  : Vector3 = (d_in + d_out).normalized()
		var _perp_c : Vector3 = Vector3(-avg_d.z, 0.0, avg_d.x)
		# Fan asteroids across the corner arc so no gaps are visible
		for side in [-1, 1]:
			for row in [0, 1, 2]:
				var offset : float = TRACK_HALF_WIDTH + float(row) * 6.0
				# Place along both incoming and outgoing perpendiculars
				for blend in [0.0, 0.33, 0.66, 1.0]:
					var in_perp  : Vector3 = Vector3(-d_in.z, 0.0, d_in.x)
					var out_perp : Vector3 = Vector3(-d_out.z, 0.0, d_out.x)
					var bp : Vector3 = wp + in_perp.lerp(out_perp, blend) * offset * float(side)
					bp.y = 0.0
					_place_boundary_asteroid(race_track_node, bp,
						rng.randf_range(2.5, 5.5), rng)

	# Finish line marker only in race mode — hidden during escape/swarm
	if not _pending_escape:
		var fin_pos  : Vector3 = TRACK_WAYPOINTS[TRACK_WAYPOINTS.size() - 1]
		var fin_prev : Vector3 = TRACK_WAYPOINTS[TRACK_WAYPOINTS.size() - 2]
		var fin_perp := Vector3(-(fin_pos - fin_prev).normalized().z, 0.0, (fin_pos - fin_prev).normalized().x)
		_place_checkpoint_marker(race_track_node, fin_pos, fin_perp, 0, true)

	if not _pending_escape:
		_setup_minimap()
	else:
		_spawn_base_ship_entrance()

	# Start line stripe
	var sl_mi  := MeshInstance3D.new()
	var sl_bm  := BoxMesh.new()
	sl_bm.size  = Vector3(TRACK_HALF_WIDTH * 2.0, 0.15, 1.5)
	sl_mi.mesh  = sl_bm
	sl_mi.position = TRACK_WAYPOINTS[0]
	var sl_mat := StandardMaterial3D.new()
	sl_mat.albedo_color              = Color(1.0, 0.1, 0.1)
	sl_mat.emission_enabled          = true
	sl_mat.emission                  = Color(1.0, 0.1, 0.1)
	sl_mat.emission_energy_multiplier = 2.5
	sl_mi.material_override = sl_mat
	race_track_node.add_child(sl_mi)

	var sl_lbl      := Label3D.new()
	sl_lbl.text      = "START"
	sl_lbl.font_size = 72
	sl_lbl.position  = TRACK_WAYPOINTS[0] + Vector3(0, 14, 0)
	sl_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sl_lbl.modulate  = Color(1.0, 0.35, 0.35)
	race_track_node.add_child(sl_lbl)

	_build_kuiper_belt()

## ── Base ship entrance tuning ─────────────────────────────────────────────────
## Adjust these three constants to reposition the base ship without touching any
## other code. All values are relative to the finish-line waypoint.
##   BASE_SHIP_FORWARD  — how far past the finish line (positive = further ahead)
##   BASE_SHIP_LATERAL  — side offset (positive = right of track, negative = left)
##   BASE_SHIP_VERTICAL — height above the play plane (0 = ground level)
const BASE_SHIP_FORWARD  : float =  90.0
const BASE_SHIP_LATERAL  : float =   0.0
const BASE_SHIP_VERTICAL : float =   0.0
const BASE_SHIP_SCALE    : float =   0.005

func _spawn_base_ship_entrance() -> void:
	var fin_pos  : Vector3 = TRACK_WAYPOINTS[TRACK_WAYPOINTS.size() - 1]
	var fin_prev : Vector3 = TRACK_WAYPOINTS[TRACK_WAYPOINTS.size() - 2]
	var forward  : Vector3 = (fin_pos - fin_prev).normalized()
	var right    : Vector3 = Vector3(-forward.z, 0.0, forward.x)

	var spawn_pos : Vector3 = fin_pos \
		+ forward * BASE_SHIP_FORWARD \
		+ right   * BASE_SHIP_LATERAL \
		+ Vector3(0, BASE_SHIP_VERTICAL, 0)

	var base := Node3D.new()
	base.name     = "BaseShipEntrance"
	base.position = spawn_pos
	# Rotate so the entrance faces the oncoming player
	base.rotation.y = atan2(forward.x, forward.z)

	# Textures
	var tex_alb  : Texture2D = load("res://assets/base_ship/GT_GA_Wall Greebles_BaseColor.png")
	var tex_emit : Texture2D = load("res://assets/base_ship/GT_GA_Wall Greebles_Emission.png")
	var tex_norm : Texture2D = load("res://assets/base_ship/GT_GA_Wall Greebles_Normal.png")

	var mat := StandardMaterial3D.new()
	mat.albedo_texture             = tex_alb
	mat.emission_enabled           = true
	mat.emission_texture           = tex_emit
	mat.emission_energy_multiplier = 2.0
	mat.normal_enabled             = true
	mat.normal_texture             = tex_norm

	for i in 9:
		var mesh_res : Mesh = load("res://assets/base_ship/model_%d.obj" % i)
		if mesh_res == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh              = mesh_res
		mi.rotation_degrees.x = 90.0   # OBJ is Z-up → Godot Y-up
		mi.scale             = Vector3(BASE_SHIP_SCALE, BASE_SHIP_SCALE, BASE_SHIP_SCALE)
		mi.material_override = mat
		base.add_child(mi)

	race_track_node.add_child(base)

func _build_kuiper_belt() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77

	# Bounding box: wider/taller than the track itself
	const XMIN := -700.0;  const XMAX := 700.0
	const ZMIN := -900.0;  const ZMAX := 950.0
	const CLEAR := TRACK_HALF_WIDTH + 30.0   # gap between track edge and rocks
	const COUNT := 600

	var placed := 0
	var tries  := 0
	while placed < COUNT and tries < COUNT * 12:
		tries += 1
		var px : float = rng.randf_range(XMIN, XMAX)
		var pz : float = rng.randf_range(ZMIN, ZMAX)

		# Reject if inside any track segment corridor
		var on_track := false
		for i in range(TRACK_WAYPOINTS.size() - 1):
			var a  : Vector3 = TRACK_WAYPOINTS[i]
			var b  : Vector3 = TRACK_WAYPOINTS[i + 1]
			var ab : Vector2 = Vector2(b.x - a.x, b.z - a.z)
			var ap : Vector2 = Vector2(px - a.x, pz - a.z)
			var t  : float   = clamp(ap.dot(ab) / ab.length_squared(), 0.0, 1.0)
			var closest      := Vector2(a.x + ab.x * t, a.z + ab.y * t)
			if Vector2(px, pz).distance_to(closest) < CLEAR:
				on_track = true
				break
		if on_track:
			continue

		var r  : float = rng.randf_range(0.8, 4.5)
		var py : float = rng.randf_range(-18.0, 18.0)
		var asteroid := _make_asteroid_node(rng, r)
		asteroid.position = Vector3(px, py, pz)
		race_track_node.add_child(asteroid)
		placed += 1

# ── Minimap ───────────────────────────────────────────────────────────────────

class MinimapDraw extends Control:
	var game_ref  : Node  = null
	var waypoints : Array = []
	const MAP_W   := 220.0
	const MAP_H   := 260.0
	const PAD     := 14.0

	var _mn_x : float = 0.0
	var _mn_z : float = 0.0
	var _sc   : float = 1.0

	func _ready() -> void:
		custom_minimum_size = Vector2(MAP_W, MAP_H)
		size                = Vector2(MAP_W, MAP_H)
		_precompute_bounds()

	func _precompute_bounds() -> void:
		if waypoints.is_empty():
			return
		var min_x := INF;  var max_x := -INF
		var min_z := INF;  var max_z := -INF
		for wp in waypoints:
			var v := wp as Vector3
			min_x = minf(min_x, v.x);  max_x = maxf(max_x, v.x)
			min_z = minf(min_z, v.z);  max_z = maxf(max_z, v.z)
		_mn_x = min_x
		_mn_z = min_z
		_sc = minf((MAP_W - PAD * 2.0) / maxf(max_x - min_x, 1.0),
				   (MAP_H - PAD * 2.0) / maxf(max_z - min_z, 1.0))

	func _world_to_map(v : Vector3) -> Vector2:
		return Vector2(PAD + (v.x - _mn_x) * _sc,
					   PAD + (v.z - _mn_z) * _sc)

	func _draw() -> void:
		# Background panel
		draw_rect(Rect2(0, 0, MAP_W, MAP_H), Color(0.04, 0.04, 0.10, 0.88), true)
		draw_rect(Rect2(0, 0, MAP_W, MAP_H), Color(0.25, 0.35, 0.55, 0.7), false, 1.5)

		if waypoints.is_empty():
			return

		# Track band
		for i in range(waypoints.size() - 1):
			var a := _world_to_map(waypoints[i]     as Vector3)
			var b := _world_to_map(waypoints[i + 1] as Vector3)
			draw_line(a, b, Color(0.22, 0.24, 0.32, 1.0), 7.0)

		# Centre dashes
		for i in range(waypoints.size() - 1):
			var a := _world_to_map(waypoints[i]     as Vector3)
			var b := _world_to_map(waypoints[i + 1] as Vector3)
			draw_line(a, b, Color(0.45, 0.48, 0.65, 0.45), 1.0)

		# Start dot (green) and Finish dot (yellow)
		draw_circle(_world_to_map(waypoints[0] as Vector3),
					4.5, Color(0.1, 1.0, 0.35))
		draw_circle(_world_to_map(waypoints[waypoints.size() - 1] as Vector3),
					4.5, Color(1.0, 0.85, 0.0))

		# Ships
		if game_ref == null:
			return
		for ship in game_ref.active_ships:
			if not is_instance_valid(ship) or not ship.alive:
				continue
			var sp  := _world_to_map(ship.global_position)
			var col : Color = ship.ship_mat.albedo_color if ship.ship_mat else Color.WHITE
			# Larger dot + arrow for human ships, small dot for bots
			if ship.team == 0:
				draw_circle(sp, 5.0, col)
				var fwd : Vector3 = -ship.transform.basis.z
				draw_line(sp, sp + Vector2(fwd.x, fwd.z).normalized() * 9.0, col, 2.0)
			else:
				draw_circle(sp, 3.0, Color(1.0, 0.2, 0.2, 0.8))

	func _process(_delta : float) -> void:
		queue_redraw()

func _setup_minimap() -> void:
	if minimap_node and is_instance_valid(minimap_node):
		minimap_node.queue_free()

	var canvas := CanvasLayer.new()
	canvas.layer = 20
	add_child(canvas)

	var mm        := MinimapDraw.new()
	mm.game_ref   = self
	mm.waypoints  = TRACK_WAYPOINTS
	mm.anchors_preset = Control.PRESET_BOTTOM_RIGHT if false else -1
	mm.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	mm.offset_left   = -240.0
	mm.offset_top    = -280.0
	mm.offset_right  = -10.0
	mm.offset_bottom = -10.0
	canvas.add_child(mm)
	minimap_node = mm

func _place_boundary_asteroid(parent: Node3D, pos: Vector3,
								radius: float, rng: RandomNumberGenerator) -> void:
	var asteroid  := _make_asteroid_node(rng, radius)
	asteroid.position = pos

	var hit_r            := radius
	var dmg_area             := Area3D.new()
	dmg_area.monitoring      = true
	dmg_area.monitorable     = true
	dmg_area.collision_layer = 2
	dmg_area.collision_mask  = 1
	dmg_area.set_meta("asteroid", true)
	var dcol   := CollisionShape3D.new()
	var dshape := SphereShape3D.new()
	dshape.radius = hit_r * 0.25
	dcol.shape    = dshape
	dmg_area.add_child(dcol)
	_debug_sphere(dmg_area, hit_r * 0.25, Color(0.0, 1.0, 0.2))
	dmg_area.area_entered.connect(func(area: Area3D):
		if not area.has_meta("ship"):
			return
		var ship = area.get_meta("ship")
		if not is_instance_valid(ship) or not ship.alive:
			return
		ship.take_damage(5)
		var away : Vector3 = (ship.global_position - dmg_area.global_position).normalized()
		ship.velocity = away * maxf(ship.velocity.length(), 15.0)
	)
	asteroid.add_child(dmg_area)
	parent.add_child(asteroid)

func _place_checkpoint_marker(parent: Node3D, pos: Vector3, perp: Vector3,
								index: int, is_finish: bool) -> void:
	var col := Color(1.0, 0.8, 0.0) if not is_finish else Color(0.1, 1.0, 0.4)

	for side in [-1, 1]:
		var pole_pos : Vector3 = pos + perp * (TRACK_HALF_WIDTH - 3.0) * float(side)
		var mi       := MeshInstance3D.new()
		var cm       := CylinderMesh.new()
		cm.top_radius    = 0.5
		cm.bottom_radius = 0.5
		cm.height        = 10.0
		mi.mesh     = cm
		mi.position = pole_pos + Vector3(0, 5, 0)
		var mat     := StandardMaterial3D.new()
		mat.albedo_color              = col
		mat.emission_enabled          = true
		mat.emission                  = col
		mat.emission_energy_multiplier = 3.5
		mi.material_override = mat
		parent.add_child(mi)

	var bar     := MeshInstance3D.new()
	var bm      := BoxMesh.new()
	bm.size      = Vector3((TRACK_HALF_WIDTH - 3.0) * 2.0, 0.4, 0.4)
	bar.mesh     = bm
	bar.position = pos + Vector3(0, 10, 0)
	bar.rotation.y = atan2(perp.x, perp.z)
	var bmat     := StandardMaterial3D.new()
	bmat.albedo_color              = col
	bmat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	bmat.albedo_color.a            = 0.75
	bmat.emission_enabled          = true
	bmat.emission                  = col
	bmat.emission_energy_multiplier = 2.5
	bmat.cull_mode                 = BaseMaterial3D.CULL_DISABLED
	bar.material_override = bmat
	parent.add_child(bar)

	var lbl     := Label3D.new()
	lbl.text    = "FINISH" if is_finish else ("CP %d" % index)
	lbl.font_size = 56 if is_finish else 36
	lbl.position  = pos + Vector3(0, 13, 0)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate  = col
	parent.add_child(lbl)

func _check_race_progress() -> void:
	var num_wps := TRACK_WAYPOINTS.size()
	for slot in ship_checkpoint.keys():
		var next_wp : int = ship_checkpoint[slot]
		if next_wp >= num_wps:
			continue

		var ship_node = null
		if slot in slot_info:
			var n = slot_info[slot].ship_node
			if is_instance_valid(n):
				ship_node = n
		elif kb_ship != null and is_instance_valid(kb_ship):
			ship_node = kb_ship

		if ship_node == null or not (ship_node as Ship).alive:
			continue

		var dist := (ship_node as Ship).global_position.distance_to(TRACK_WAYPOINTS[next_wp])
		if dist < CHECKPOINT_RADIUS:
			ship_checkpoint[slot] = next_wp + 1
			print("Slot %d → waypoint %d" % [slot, next_wp])
			if next_wp + 1 >= num_wps:
				_finish_race(slot)
				return

func _enforce_track_boundaries() -> void:
	for ship in active_ships:
		if not is_instance_valid(ship) or not ship.alive:
			continue
		_push_ship_to_track(ship)

func _push_ship_to_track(ship: Ship) -> void:
	var px := ship.position.x
	var pz := ship.position.z
	var min_dist := INF
	var bx := 0.0
	var bz := 0.0
	for i in range(TRACK_WAYPOINTS.size() - 1):
		var ax : float = (TRACK_WAYPOINTS[i] as Vector3).x
		var az : float = (TRACK_WAYPOINTS[i] as Vector3).z
		var ex : float = (TRACK_WAYPOINTS[i + 1] as Vector3).x
		var ez : float = (TRACK_WAYPOINTS[i + 1] as Vector3).z
		var dx : float = ex - ax
		var dz : float = ez - az
		var len2 : float = dx * dx + dz * dz
		if len2 == 0.0:
			continue
		var t  : float = clampf(((px - ax) * dx + (pz - az) * dz) / len2, 0.0, 1.0)
		var cx : float = ax + t * dx
		var cz : float = az + t * dz
		var d   := sqrt((px - cx) * (px - cx) + (pz - cz) * (pz - cz))
		if d < min_dist:
			min_dist = d
			bx = cx
			bz = cz

	# Near any waypoint, widen boundary proportionally to avoid invisible corner walls
	var curve_bonus : float = 0.0
	for i in range(1, TRACK_WAYPOINTS.size() - 1):
		var wx : float = (TRACK_WAYPOINTS[i] as Vector3).x
		var wz : float = (TRACK_WAYPOINTS[i] as Vector3).z
		var wd : float = sqrt((px - wx) * (px - wx) + (pz - wz) * (pz - wz))
		if wd < TRACK_HALF_WIDTH * 2.0:
			# Blend up to +40% width the closer we are to a waypoint
			var t2 : float = 1.0 - (wd / (TRACK_HALF_WIDTH * 2.0))
			curve_bonus = maxf(curve_bonus, TRACK_HALF_WIDTH * 0.4 * t2)

	var effective_width : float = TRACK_HALF_WIDTH + curve_bonus

	if min_dist > effective_width and min_dist > 0.001:
		var nx  := (px - bx) / min_dist
		var nz  := (pz - bz) / min_dist
		var pen := min_dist - effective_width
		ship.position.x -= nx * pen
		ship.position.z -= nz * pen
		var out_v := ship.velocity.x * nx + ship.velocity.z * nz
		if out_v > 0.0:
			ship.velocity.x -= nx * out_v * 1.5
			ship.velocity.z -= nz * out_v * 1.5

func _finish_race(slot: int) -> void:
	if state != State.RACE and state != State.ESCAPE:
		return
	if state == State.ESCAPE:
		# Stop the winning ship
		var winner_ship = null
		if slot in slot_info:
			var n = slot_info[slot].ship_node
			if is_instance_valid(n):
				winner_ship = n
		elif kb_ship != null and is_instance_valid(kb_ship):
			winner_ship = kb_ship
		if winner_ship != null:
			(winner_ship as Ship).velocity     = Vector3.ZERO
			(winner_ship as Ship).angular_vel  = 0.0
		state             = State.WIN
		win_timer         = 3.0
		win_label.text    = "YOU WIN!"
		win_label.add_theme_color_override("font_color", Color(1, 1, 1))
		win_label.visible = true
		bridge.send({ "type": "game_over", "winnerSlot": slot })
		return
	race_finished_slots.append(slot)
	print("Race over — slot %d wins!" % slot)
	_end_game(slot)

func _update_race_hud() -> void:
	var prog : Array = []
	for sl in ship_checkpoint.keys():
		prog.append([sl, ship_checkpoint[sl]])
	prog.sort_custom(func(a, b): return a[1] > b[1])

	var pos_names := ["1ST", "2ND", "3RD", "4TH", "5TH"]
	var pos_map   : Dictionary = {}
	for i in prog.size():
		pos_map[prog[i][0]] = pos_names[mini(i, pos_names.size() - 1)]

	var total_cps := TRACK_WAYPOINTS.size() - 1  # 10

	for vd in vp_data:
		if not "race_lbl" in vd:
			continue
		var ship = vd["ship"]
		if not is_instance_valid(ship):
			continue
		var sl  := (ship as Ship).slot
		var cp  := maxi(ship_checkpoint.get(sl, 1) - 1, 0)
		var pos_s : String = pos_map.get(sl, "?")
		vd["race_lbl"].text = "%s · CP %d/%d" % [pos_s, cp, total_cps]

# ── Escape Mode ───────────────────────────────────────────────────────────────

func _escape_bot_spawn_positions() -> Array:
	var start_base : Vector3 = TRACK_WAYPOINTS[0]
	var track_dir  : Vector3 = ((TRACK_WAYPOINTS[1] as Vector3) - start_base).normalized()
	var perp       : Vector3 = Vector3(-track_dir.z, 0.0, track_dir.x)
	# 5 bots in a grid directly behind the player start line
	return [
		start_base + perp * -12.0 + track_dir * -55.0,
		start_base + perp *  12.0 + track_dir * -55.0,
		start_base + perp * -12.0 + track_dir * -80.0,
		start_base + perp *  12.0 + track_dir * -80.0,
		start_base + perp *   0.0 + track_dir * -105.0,
	]

func _start_escape() -> void:
	_hide_main_lobby()
	state           = State.COUNTDOWN
	_pending_escape = true
	countdown_val   = 3
	countdown_timer = 1.0
	countdown_label.text    = str(countdown_val)
	countdown_label.visible = true
	start_hint.visible       = false
	playground_label.visible = false
	lobby_status.text        = ""
	ship_checkpoint.clear()
	race_finished_slots.clear()
	escape_bots.clear()

	_spawn_ships_race()
	for ship in human_ships:
		if is_instance_valid(ship):
			(ship as Ship).team = 0

	_spawn_escape_bots()
	_build_race_track()
	_build_split_screen()

func _spawn_escape_bots() -> void:
	var start_base : Vector3 = TRACK_WAYPOINTS[0]
	var track_dir  : Vector3 = ((TRACK_WAYPOINTS[1] as Vector3) - start_base).normalized()
	var spawn_yaw  : float   = atan2(track_dir.x, -track_dir.z)

	# Bots run at 115 % of player speed so they steadily close the gap
	var total_spd := 0.0
	var n_players := 0
	for ship in human_ships:
		if is_instance_valid(ship):
			total_spd += (ship as Ship).speed
			n_players += 1
	escape_bot_speed = (total_spd / float(max(n_players, 1)))

	var spawn_positions := _escape_bot_spawn_positions()
	for i in 5:
		var slot : int = BOT_SLOT + i
		var ship : Ship = ship_scene.instantiate()
		ships_node.add_child(ship)
		ship.position   = spawn_positions[i]
		ship.rotation.y = spawn_yaw
		ship.setup(slot, "corsair", projectile_scene, projectiles_node)
		ship.speed      = escape_bot_speed
		ship.race_mode  = true
		ship.team       = 1
		ship.all_ships  = active_ships
		ship.died.connect(_on_ship_died)
		active_ships.append(ship)
		escape_bots.append(ship)

func _on_escape_bot_died(slot: int) -> void:
	if state != State.ESCAPE:
		return
	var i : int = slot - BOT_SLOT
	# Capture death position before the node is freed
	var death_pos : Vector3 = Vector3.ZERO
	if i >= 0 and i < escape_bots.size() and is_instance_valid(escape_bots[i]):
		death_pos = escape_bots[i].global_position
	get_tree().create_timer(5.0).timeout.connect(
		func(): _respawn_escape_bot(slot, death_pos))

func _respawn_escape_bot(slot: int, spawn_pos: Vector3) -> void:
	if state != State.ESCAPE:
		return
	var i         : int   = slot - BOT_SLOT
	var track_dir : Vector3 = ((TRACK_WAYPOINTS[1] as Vector3) - TRACK_WAYPOINTS[0]).normalized()
	var spawn_yaw : float   = atan2(track_dir.x, -track_dir.z)
	var ship : Ship = ship_scene.instantiate()
	ships_node.add_child(ship)
	ship.position   = spawn_pos
	ship.rotation.y = spawn_yaw
	ship.setup(slot, "corsair", projectile_scene, projectiles_node)
	ship.speed      = escape_bot_speed
	ship.race_mode  = true
	ship.team       = 1
	ship.invincible = true
	ship.all_ships  = active_ships
	ship.died.connect(_on_ship_died)
	active_ships.append(ship)
	escape_bots[i]  = ship
	get_tree().create_timer(2.0).timeout.connect(
		func(): if is_instance_valid(ship): ship.invincible = false)

# Each bot aims slightly offset from the target so they fan out around the player
const BOT_SPREAD : Array = [
	Vector3( 10, 0,   0), Vector3(-10, 0,   0),
	Vector3(  0, 0,  10), Vector3(  0, 0, -10),
	Vector3(  0, 0,   0),
]

func _tick_escape_bots(_delta: float) -> void:
	for bi in escape_bots.size():
		var bot = escape_bots[bi]
		if not is_instance_valid(bot) or not bot.alive:
			continue

		# Find nearest living player
		var target : Ship = null
		var best_d := INF
		for s in active_ships:
			if not is_instance_valid(s) or not s.alive or s.team != 0:
				continue
			var d : float = bot.global_position.distance_to((s as Ship).global_position)
			if d < best_d:
				best_d = d
				target = s

		if target == null:
			bot.set_input(0.0, 0.2, false, false)
			continue

		# Each bot aims at a unique offset point around the target
		var aim_pos : Vector3 = target.global_position + BOT_SPREAD[bi % BOT_SPREAD.size()]
		var to_aim  : Vector3 = aim_pos - bot.global_position
		var dist    : float   = to_aim.length()
		var dir_f   : Vector2 = Vector2(to_aim.x, to_aim.z).normalized()

		# Separation: steer away from nearby fellow bots
		var sep := Vector2.ZERO
		for other in escape_bots:
			if not is_instance_valid(other) or other == bot or not other.alive:
				continue
			var diff := Vector2(bot.position.x - other.position.x,
								bot.position.z - other.position.z)
			var dd : float = diff.length()
			if dd < 18.0 and dd > 0.01:
				sep += diff.normalized() * (1.0 - dd / 18.0)

		# Blend chase direction with separation
		if sep.length() > 0.01:
			dir_f = (dir_f * 0.65 + sep.normalized() * 0.35).normalized()

		var fwd   : Vector3 = -bot.transform.basis.z
		var fwd_f : Vector2 = Vector2(fwd.x, fwd.z).normalized()
		var angle : float   = fwd_f.angle_to(dir_f)
		var rot   : float   = clampf(angle * 2.5, -1.0, 1.0)
		var thrust : float  = 0.8 if (fwd_f.dot(dir_f) > 0.3 and dist > 5.0) else 0.0
		var fire  : bool    = absf(angle) < 0.4 and \
								bot.global_position.distance_to(target.global_position) < 60.0
		bot.set_input(rot, thrust, fire, false)

# ── Siege mode ────────────────────────────────────────────────────────────────

func _start_siege() -> void:
	# Reposition player ships away from mothership spawn (400, 0, 0)
	var si := 0
	for ship in active_ships:
		ship.team       = 0
		ship.siege_mode = true
		ship.velocity   = Vector3.ZERO
		var a : float = float(si) / float(max(active_ships.size(), 1)) * TAU
		ship.global_position = Vector3(cos(a) * 18.0, 0.0, sin(a) * 18.0)
		ship.rotation.y = a + PI
		si += 1

	_build_siege_kuiper_belt()
	_spawn_siege_enemies()
	_setup_siege_hud()

func _build_siege_kuiper_belt() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99

	# Side walls — dense flanking clouds, split above and below the play plane
	for _i in 1800:
		var px : float = rng.randf_range(-3500.0, 3500.0)
		var pz : float = rng.randf_range(35.0, 300.0) * (1.0 if rng.randf() > 0.5 else -1.0)
		var py : float = rng.randf_range(10.0, 28.0) * (1.0 if rng.randf() > 0.5 else -1.0)
		var r  : float = rng.randf_range(1.0, 7.0)
		var asteroid := _make_siege_asteroid(rng, r)
		asteroid.position = Vector3(px, py, pz)
		add_child(asteroid)

	# Sparse scatter inside the corridor — above and below the flight plane
	for _i in 300:
		var px : float = rng.randf_range(-3500.0, 3500.0)
		var pz : float = rng.randf_range(-30.0, 30.0)
		var py : float = rng.randf_range(8.0, 20.0) * (1.0 if rng.randf() > 0.5 else -1.0)
		var r  : float = rng.randf_range(0.6, 2.5)
		var asteroid := _make_siege_asteroid(rng, r)
		asteroid.position = Vector3(px, py, pz)
		add_child(asteroid)

	# Ceiling — above the play zone, full X span
	for _i in 700:
		var px : float = rng.randf_range(-3500.0, 3500.0)
		var pz : float = rng.randf_range(-250.0, 250.0)
		var py : float = rng.randf_range(25.0, 100.0)
		var r  : float = rng.randf_range(1.0, 6.0)
		var asteroid := _make_siege_asteroid(rng, r)
		asteroid.position = Vector3(px, py, pz)
		add_child(asteroid)

	# Floor — below the play zone, full X span
	for _i in 700:
		var px : float = rng.randf_range(-3500.0, 3500.0)
		var pz : float = rng.randf_range(-250.0, 250.0)
		var py : float = rng.randf_range(-100.0, -25.0)
		var r  : float = rng.randf_range(1.0, 6.0)
		var asteroid := _make_siege_asteroid(rng, r)
		asteroid.position = Vector3(px, py, pz)
		add_child(asteroid)

func _spawn_siege_enemies() -> void:
	var ms_scene := load("res://scripts/mothership.gd")
	siege_mothership = Node3D.new()
	siege_mothership.set_script(ms_scene)
	siege_mothership.position = Vector3(400, 0, 0)
	ships_node.add_child(siege_mothership)
	siege_mothership.died.connect(_on_mothership_died)

	var mn_scene := load("res://scripts/minion.gd")
	# 2 left, 2 right, 1 back — relative to mothership facing +X
	var minion_offsets : Array = [
		Vector3(  0, 0, -130),   # left 1
		Vector3(-50, 0, -130),   # left 2
		Vector3(  0, 0,  130),   # right 1
		Vector3(-50, 0,  130),   # right 2
		Vector3( 160, 0,   0),   # front
	]
	for i in minion_offsets.size():
		var minion := Node3D.new()
		minion.set_script(mn_scene)
		minion.position        = siege_mothership.position + minion_offsets[i]
		minion.slot            = 200 + i
		minion.mothership      = siege_mothership
		minion.all_ships       = active_ships
		minion.projectile_scene = projectile_scene
		minion.projectiles_node = projectiles_node
		ships_node.add_child(minion)
		minion.died.connect(_on_minion_died)
		siege_minions.append(minion)

func _on_mothership_died() -> void:
	if state != State.SIEGE:
		return
	state             = State.WIN
	win_timer         = 3.0
	win_label.text    = "MISSION SUCCESS!"
	win_label.add_theme_color_override("font_color", Color(0.1, 1.0, 0.4))
	win_label.visible = true
	bridge.send({ "type": "game_over", "winnerSlot": 0 })

func _on_minion_died(_slot: int) -> void:
	siege_minions = siege_minions.filter(func(m): return is_instance_valid(m) and m.alive)

func _setup_siege_hud() -> void:
	# Mothership HP bar at top of screen on the main canvas
	var canvas := CanvasLayer.new()
	canvas.layer = 10
	add_child(canvas)

	var container    := VBoxContainer.new()
	container.position = Vector2(get_viewport().size.x / 2.0 - 160, 12)
	canvas.add_child(container)

	var title       := Label.new()
	title.text       = "MOTHERSHIP"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	container.add_child(title)

	_ms_hp_label = Label.new()
	_ms_hp_label.custom_minimum_size = Vector2(320, 0)
	_ms_hp_label.add_theme_font_size_override("font_size", 18)
	_ms_hp_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.2))
	_ms_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	container.add_child(_ms_hp_label)

func _update_siege_hud() -> void:
	if not is_instance_valid(_ms_hp_label):
		return
	if is_instance_valid(siege_mothership) and siege_mothership.alive:
		var pct : float = float(siege_mothership.hp) / float(siege_mothership.max_hp)
		var bar : String = ""
		var segments := 20
		for i in segments:
			bar += "█" if float(i) / segments < pct else "░"
		_ms_hp_label.text = "%s  %d / %d" % [bar, siege_mothership.hp, siege_mothership.max_hp]
	else:
		_ms_hp_label.text = "DESTROYED"
