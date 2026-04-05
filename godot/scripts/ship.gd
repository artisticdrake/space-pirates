extends Node3D
class_name Ship

signal died(slot: int)

const SHIP_DATA := {
	"corsair":     { "speed": 18.0, "hp": 80,  "fire_rate": 0.10, "weapon": "rapid_laser",    "special": "speed_burst" },
	"dreadnought": { "speed":  8.0, "hp": 150, "fire_rate": 0.80, "weapon": "heavy_cannon",   "special": "shield"      },
	"phantom":     { "speed": 14.0, "hp": 90,  "fire_rate": 0.80, "weapon": "homing_missile", "special": "cloak"       },
	"scavenger":   { "speed": 14.0, "hp": 100, "fire_rate": 0.40, "weapon": "spread_shot",    "special": "ram_boost"   },
	"marauder":    { "speed": 14.0, "hp": 110, "fire_rate": 0.10, "weapon": "beam",            "special": "emp"         },
	"specter":     { "speed": 18.0, "hp": 70,  "fire_rate": 0.60, "weapon": "mine",            "special": "teleport"    },
}

const PLAYER_COLORS := ["#00f5ff", "#ff3f3f", "#39ff14", "#ff9f00", "#cc44ff", "#c0c0c0"]

const SHIP_MODELS := {
	"corsair":     "res://assets/ships/craft_racer.glb",
	"dreadnought": "res://assets/ships/craft_miner.glb",
	"phantom":     "res://assets/ships/craft_speederA.glb",
	"scavenger":   "res://assets/ships/craft_speederB.glb",
	"marauder":    "res://assets/ships/craft_speederC.glb",
	"specter":     "res://assets/ships/craft_speederD.glb",
}
const ARENA_RADIUS   := 80.0
const TURN_SPEED     := 2.5
const LIN_DRAG       := 0.97
const ANG_DRAG       := 0.88
const THRUST_RAMP_DOWN := 1.2   # units/sec — how fast thrust drops when braking
const THRUST_RAMP_UP   := 4.0   # units/sec — how fast thrust returns when released

# Identity
var slot    : int    = -1
var ship_id : String = "corsair"

# Stats
var hp      : int   = 100
var max_hp  : int   = 100
var speed   : float = 14.0
var fire_rate : float = 0.3
var weapon  : String = "rapid_laser"
var special : String = "speed_burst"

# State
var alive       : bool  = true
var invincible  : bool  = false
var race_mode   : bool  = false   # disables arena clamp in race track mode
var siege_mode  : bool  = false   # disables arena clamp in siege mode
var team        : int   = -1      # -1 = no team; 0 = player; 1 = escape bot

# Physics
var velocity    := Vector3.ZERO
var angular_vel : float = 0.0

# Input
var inp_rotate       : float = 0.0
var inp_thrust       : float = 0.0
var _thrust_target   : float = 0.0
var inp_firing       : bool  = false

# Timers
var fire_cd       : float = 0.0
var special_cd    : float = 0.0
var _collision_cd : float = 0.0
var special_dur : float = 0.0

# Special flags
var speed_boosted : bool = false
var shielded      : bool = false
var cloaked       : bool = false
var emp_disabled  : bool = false

# References (set by game.gd)
var projectile_scene : PackedScene
var projectiles_node : Node3D
var all_ships        : Array = []

# Visual
var model_node     : Node3D           # root of the loaded Kenney GLB
var mesh_instance  : MeshInstance3D   # player-color indicator ring under ship
var ship_mat       : StandardMaterial3D
var shield_mesh    : MeshInstance3D
var shield_mat     : StandardMaterial3D
var beam_mesh      : MeshInstance3D
var beam_mat       : StandardMaterial3D
var hit_area       : Area3D

const BEAM_LENGTH  := 40.0

# ── Audio ─────────────────────────────────────────────────────────────────────
static var _sfx_laser : AudioStreamWAV = null
static var _sfx_hit   : AudioStreamWAV = null
static var _sfx_death : AudioStreamWAV = null

var _snd_laser : AudioStreamPlayer = null
var _snd_hit   : AudioStreamPlayer = null

# ── Setup ────────────────────────────────────────────────────────────────────

func setup(p_slot: int, p_ship_id: String,
		   p_proj_scene: PackedScene, p_projs: Node3D) -> void:
	slot             = p_slot
	ship_id          = p_ship_id
	projectile_scene = p_proj_scene
	projectiles_node = p_projs

	var data := SHIP_DATA.get(ship_id, SHIP_DATA["corsair"]) as Dictionary
	hp        = data.get("hp",        100)
	max_hp    = hp
	speed     = data.get("speed",     14.0)
	fire_rate = data.get("fire_rate", 0.3)
	weapon    = data.get("weapon",    "rapid_laser")
	special   = data.get("special",   "speed_burst")

	_build_visuals()
	_init_sounds()

func _init_sounds() -> void:
	if _sfx_laser == null:
		_sfx_laser = _gen_laser_wav()
		_sfx_hit   = _gen_hit_wav()
		_sfx_death = _gen_death_wav()

	_snd_laser = AudioStreamPlayer.new()
	_snd_laser.stream    = _sfx_laser
	_snd_laser.volume_db = -6.0
	add_child(_snd_laser)

	_snd_hit = AudioStreamPlayer.new()
	_snd_hit.stream    = _sfx_hit
	_snd_hit.volume_db = -2.0
	add_child(_snd_hit)

static func _make_wav() -> AudioStreamWAV:
	var wav      := AudioStreamWAV.new()
	wav.format    = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate  = 44100
	wav.stereo    = false
	return wav

static func _write_sample(data: PackedByteArray, i: int, val: float) -> void:
	var s : int = clampi(int(val), -32768, 32767)
	data[i * 2]     = s & 0xFF
	data[i * 2 + 1] = (s >> 8) & 0xFF

static func _gen_laser_wav() -> AudioStreamWAV:
	const SR     := 44100
	var   frames := int(SR * 0.12)
	var   data   := PackedByteArray()
	data.resize(frames * 2)
	for i in frames:
		var t    : float = float(i) / SR
		var pct  : float = float(i) / frames
		var freq : float = lerp(1600.0, 280.0, pct)
		var env  : float = exp(-pct * 5.0)
		var v    : float = sin(TAU * freq * t) * env
		v += sin(TAU * freq * 2.1 * t) * env * 0.22
		_write_sample(data, i, v * 13000.0)
	var wav := _make_wav()
	wav.data = data
	return wav

static func _gen_hit_wav() -> AudioStreamWAV:
	const SR     := 44100
	var   frames := int(SR * 0.08)
	var   data   := PackedByteArray()
	data.resize(frames * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in frames:
		var t   : float = float(i) / SR
		var pct : float = float(i) / frames
		var env : float = exp(-pct * 9.0)
		var v   : float = rng.randf_range(-1.0, 1.0) * env * 0.75
		v += sin(TAU * 520.0 * t) * env * 0.35
		_write_sample(data, i, v * 11000.0)
	var wav := _make_wav()
	wav.data = data
	return wav

static func _gen_death_wav() -> AudioStreamWAV:
	const SR     := 44100
	var   frames := int(SR * 0.65)
	var   data   := PackedByteArray()
	data.resize(frames * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	for i in frames:
		var t      : float = float(i) / SR
		var pct    : float = float(i) / frames
		var attack : float = minf(1.0, float(i) / int(SR * 0.015))
		var env    : float = exp(-pct * 2.8) * attack
		var noise  : float = rng.randf_range(-1.0, 1.0)
		var rumble : float = sin(TAU * 55.0 * t) * 0.5 + sin(TAU * 90.0 * t) * 0.25
		var v      : float = (noise * 0.65 + rumble * 0.35) * env
		_write_sample(data, i, v * 22000.0)
	var wav := _make_wav()
	wav.data = data
	return wav

func _recolor_yellow_to_red(root: Node3D) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(i)
			if not (mat is StandardMaterial3D):
				continue
			var col : Color = (mat as StandardMaterial3D).albedo_color
			# Yellow hue is ~0.11–0.22 in Godot's 0–1 HSV range (40°–80°)
			if col.s > 0.35 and col.h >= 0.11 and col.h <= 0.22:
				var new_mat := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
				new_mat.albedo_color = Color(0.85, 0.05, 0.05, col.a)
				if new_mat.emission_enabled:
					new_mat.emission = Color(0.9, 0.02, 0.02)
				mi.set_surface_override_material(i, new_mat)

func _build_visuals() -> void:
	# Load Kenney 3D model — keep original textures intact
	var model_path  : String      = SHIP_MODELS.get(ship_id, SHIP_MODELS["corsair"])
	var model_scene : PackedScene = load(model_path)
	model_node                    = model_scene.instantiate()
	model_node.scale              = Vector3.ONE * 2.0
	model_node.rotation_degrees.y = 180.0   # face -Z (forward)
	_recolor_yellow_to_red(model_node)
	add_child(model_node)
	# Defer centering so world transforms are resolved first
	call_deferred("_center_model_node")

	# Colored glowing ring — child of self so it stays at the ship's true origin
	ship_mat = StandardMaterial3D.new()
	ship_mat.albedo_color               = Color(PLAYER_COLORS[slot % PLAYER_COLORS.size()])
	ship_mat.emission_enabled           = true
	ship_mat.emission                   = Color(PLAYER_COLORS[slot % PLAYER_COLORS.size()])
	ship_mat.emission_energy_multiplier = 2.5
	ship_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED

	var ring_mesh            := CylinderMesh.new()
	ring_mesh.top_radius      = 1.4
	ring_mesh.bottom_radius   = 1.4
	ring_mesh.height          = 0.06
	ring_mesh.radial_segments = 24
	mesh_instance             = MeshInstance3D.new()
	mesh_instance.mesh        = ring_mesh
	mesh_instance.material_override = ship_mat
	add_child(mesh_instance)

	# Shield bubble (hidden until shield special is active)
	shield_mesh = MeshInstance3D.new()
	var shield_sm       := SphereMesh.new()
	shield_sm.radius    = 2.2
	shield_sm.height    = 4.4
	shield_mesh.mesh    = shield_sm
	shield_mat          = StandardMaterial3D.new()
	shield_mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	shield_mat.albedo_color              = Color(0.3, 0.6, 1.0, 0.28)
	shield_mat.emission_enabled          = true
	shield_mat.emission                  = Color(0.2, 0.5, 1.0)
	shield_mat.emission_energy_multiplier = 3.0
	shield_mat.cull_mode                 = BaseMaterial3D.CULL_DISABLED
	shield_mesh.material_override        = shield_mat
	shield_mesh.visible                  = false
	add_child(shield_mesh)

	# Beam weapon visual (Marauder only — hidden otherwise)
	beam_mesh = MeshInstance3D.new()
	var beam_box       := BoxMesh.new()
	beam_box.size       = Vector3(0.08, 0.08, BEAM_LENGTH)
	beam_mesh.mesh = beam_box
	beam_mat = StandardMaterial3D.new()
	beam_mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.albedo_color              = Color(PLAYER_COLORS[slot % PLAYER_COLORS.size()])
	beam_mat.albedo_color.a            = 0.82
	beam_mat.emission_enabled          = true
	beam_mat.emission                  = Color(PLAYER_COLORS[slot % PLAYER_COLORS.size()])
	beam_mat.emission_energy_multiplier = 5.0
	beam_mat.shading_mode              = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_mesh.material_override        = beam_mat
	# Position in local space: starts at gun point (1.5 forward), extends BEAM_LENGTH ahead
	beam_mesh.position = Vector3(0.0, 0.1, -(1.5 + BEAM_LENGTH * 0.5))
	beam_mesh.visible  = false
	add_child(beam_mesh)

	# Hit area (Area3D so projectiles can detect it)
	hit_area = Area3D.new()
	hit_area.name            = "HitArea"
	hit_area.collision_layer = 1
	hit_area.collision_mask  = 0
	hit_area.monitoring      = true
	hit_area.collision_mask  = 1
	hit_area.monitorable     = true
	hit_area.set_meta("ship", self)
	hit_area.area_entered.connect(_on_ship_collision)

	var col   := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.4, 0.5, 2.4)
	col.shape  = shape
	hit_area.add_child(col)
	add_child(hit_area)

func _center_model_node() -> void:
	if not is_instance_valid(model_node):
		return
	# Average world positions of all mesh instances → offset model_node to center them on self
	var sum   := Vector3.ZERO
	var count := 0
	for node in model_node.find_children("*", "MeshInstance3D", true, false):
		sum   += (node as MeshInstance3D).global_position
		count += 1
	if count == 0:
		return
	var world_center : Vector3 = sum / float(count)
	var local_offset : Vector3 = to_local(world_center)
	model_node.position -= local_offset

# ── Input ─────────────────────────────────────────────────────────────────────

func set_input(rot: float, thrust: float, firing: bool, burst: bool) -> void:
	if emp_disabled:
		return
	inp_rotate     = rot
	_thrust_target = thrust
	inp_firing     = firing
	if burst and special_cd <= 0.0:
		_trigger_special()

# ── Process ───────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not alive:
		return

	fire_cd       = maxf(0.0, fire_cd       - delta)
	special_cd    = maxf(0.0, special_cd    - delta)
	_collision_cd = maxf(0.0, _collision_cd - delta)

	_tick_specials(delta)
	_move(delta)
	_clamp_to_arena()
	_update_beam_visual()

	if inp_firing and fire_cd <= 0.0 and not emp_disabled:
		_fire()

func _update_beam_visual() -> void:
	if weapon != "beam":
		return
	var on := inp_firing and not emp_disabled
	beam_mesh.visible = on
	if on:
		# Pulse emission so the beam feels alive
		var pulse := 4.5 + sin(Time.get_ticks_msec() * 0.009) * 2.0
		beam_mat.emission_energy_multiplier = pulse

func _move(delta: float) -> void:
	var eff_speed := speed * (2.0 if speed_boosted else 1.0)

	# Ramp thrust gradually — slow to brake, fast to return to forward
	var ramp := THRUST_RAMP_DOWN if _thrust_target < inp_thrust else THRUST_RAMP_UP
	inp_thrust = move_toward(inp_thrust, _thrust_target, ramp * delta)

	angular_vel += -inp_rotate * TURN_SPEED * delta * 20.0
	angular_vel *= ANG_DRAG
	rotate_y(angular_vel * delta)

	var forward := -transform.basis.z
	velocity    += forward * inp_thrust * eff_speed * delta * 8.0
	velocity    *= LIN_DRAG

	position    += velocity * delta

func _clamp_to_arena() -> void:
	if race_mode or siege_mode:
		return   # no arena boundary in race/siege
	var dist := position.length()
	if dist > ARENA_RADIUS:
		velocity -= position.normalized() * (dist - ARENA_RADIUS) * 0.5
		position  = position.normalized() * ARENA_RADIUS

# ── Weapons ───────────────────────────────────────────────────────────────────

func _muzzle_flash() -> void:
	var col   : Color = Color(PLAYER_COLORS[slot % PLAYER_COLORS.size()])
	var light         := OmniLight3D.new()
	light.position     = Vector3(0, 0.1, -1.5)   # local gun offset, moves with ship
	light.light_color  = col
	light.light_energy = 10.0
	light.omni_range   = 5.0
	light.shadow_enabled = false
	add_child(light)
	var t := create_tween()
	t.tween_property(light, "light_energy", 0.0, 0.04)
	t.tween_callback(light.queue_free)

func _on_ship_collision(area: Area3D) -> void:
	if _collision_cd > 0.0:
		return
	var other = area.get_meta("ship", null)
	if not is_instance_valid(other) or not other.alive:
		return
	if other.slot == slot:
		return
	if team >= 0 and other.team == team:
		return
	_collision_cd       = 0.5
	other._collision_cd = 0.5
	var dmg : int = 5 if other.slot >= 100 else 8
	take_damage(dmg)
	other.take_damage(dmg)
	# Bounce off mothership and minions — slam you away at full speed
	if other.slot >= 100:
		var away : Vector3 = global_position - (other.global_position as Vector3)
		away.y = 0.0
		if away.length_squared() < 0.01:
			away = Vector3(1.0, 0.0, 0.0)
		velocity = away.normalized() * maxf(velocity.length(), 35.0)

func _fire() -> void:
	fire_cd = fire_rate
	if is_instance_valid(_snd_laser):
		_snd_laser.play()
	var fwd     := -transform.basis.z
	var gun_pos := global_position + fwd * 1.5 + Vector3.UP * 0.1
	_muzzle_flash()

	match weapon:
		"rapid_laser":
			_spawn_proj(gun_pos, fwd, 40.0, 13)

		"heavy_cannon":
			_spawn_proj(gun_pos, fwd, 22.0, 40)

		"homing_missile":
			var p := _spawn_proj(gun_pos, fwd, 20.0, 28)
			if p:
				p.homing_target   = _nearest_enemy()
				p.homing_strength = 4.5
				p.lifetime        = 6.0

		"spread_shot":
			for deg in [-15.0, 0.0, 15.0]:
				var dir := fwd.rotated(Vector3.UP, deg_to_rad(deg))
				_spawn_proj(gun_pos, dir, 30.0, 12)

		"beam":
			_beam_damage()

		"mine":
			var back := transform.basis.z   # behind ship
			var p    := _spawn_proj(global_position + back * 2.5, Vector3.ZERO, 0.0, 45)
			if p:
				p.lifetime = 20.0
				p.scale    = Vector3(2.0, 2.0, 2.0)

func _spawn_proj(pos: Vector3, dir: Vector3, spd: float, dmg: int,
				 wtype: String = "") -> Projectile:
	if not projectile_scene:
		return null
	var p: Projectile = projectile_scene.instantiate()
	p.weapon_type       = wtype if wtype != "" else weapon   # set before _ready/_build_visuals
	p.owner_color       = Color(PLAYER_COLORS[slot % PLAYER_COLORS.size()])
	p.bolt_sprite_path  = _bolt_sprite_for(ship_id)
	projectiles_node.add_child(p)
	p.init(pos, dir, spd, dmg, slot)
	# Inherit ship velocity so bullets aren't slower than the ship in race mode
	var wt := wtype if wtype != "" else weapon
	if wt != "mine":
		p.velocity += velocity
	p.owner_team = team
	return p

func _bolt_sprite_for(id: String) -> String:
	match id:
		"corsair":     return "res://assets/lasers/55.png"   # blue
		"dreadnought": return "res://assets/lasers/60.png"   # orange/red
		"phantom":     return "res://assets/lasers/66.png"   # green sparkle
		"scavenger":   return "res://assets/lasers/60.png"   # orange/red
		"marauder":    return "res://assets/lasers/40.png"   # purple
		"specter":     return "res://assets/lasers/45.png"   # yellow-green
		_:             return "res://assets/lasers/42.png"   # pink/red (bots)

func _beam_damage() -> void:
	var space := get_world_3d().direct_space_state
	if not space:
		return
	var fwd    := -transform.basis.z
	var params := PhysicsRayQueryParameters3D.create(
		global_position + fwd * 1.5, global_position + fwd * 70.0)
	params.collision_mask       = 1
	params.collide_with_areas   = true   # Area3D hit detection
	params.collide_with_bodies  = false
	params.exclude              = [hit_area.get_rid()]  # don't hit self
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return
	var target_ship = hit.collider.get_meta("ship", null)
	if target_ship and is_instance_valid(target_ship) and target_ship.slot != slot:
		if team < 0 or target_ship.team != team:   # no friendly-fire
			target_ship.take_damage(3)

func _nearest_enemy() -> Node3D:
	var best : Node3D = null
	var best_d := INF
	for s in all_ships:
		if s == self or not is_instance_valid(s) or not s.alive:
			continue
		var d := global_position.distance_to(s.global_position)
		if d < best_d:
			best_d = d
			best   = s
	return best

# ── Special FX helpers (declared before _trigger_special to satisfy parser) ───

func _fx_tween_emission_restore(duration: float) -> void:
	var t := create_tween()
	t.tween_interval(duration)
	t.tween_callback(_restore_emission)

func _fx_shockwave() -> void:
	# Expanding orange-white ring burst
	ship_mat.emission                  = Color(1.0, 0.55, 0.0)
	ship_mat.emission_energy_multiplier = 6.0
	_fx_tween_emission_restore(0.4)

	var ring     := MeshInstance3D.new()
	var tm       := TorusMesh.new()
	tm.outer_radius = 1.0
	tm.inner_radius = 0.6
	ring.mesh    = tm
	var rmat     := StandardMaterial3D.new()
	rmat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_color              = Color(1.0, 0.65, 0.1, 1.0)
	rmat.emission_enabled          = true
	rmat.emission                  = Color(1.0, 0.4, 0.0)
	rmat.emission_energy_multiplier = 8.0
	rmat.cull_mode                 = BaseMaterial3D.CULL_DISABLED
	ring.material_override         = rmat
	add_child(ring)
	var t := create_tween()
	t.tween_property(ring, "scale", Vector3(22, 22, 22), 0.45)
	t.parallel().tween_property(rmat, "albedo_color:a", 0.0, 0.45)
	t.tween_callback(ring.queue_free)

func _apply_shockwave() -> void:
	const RADIUS   := 22.0
	const DAMAGE   := 45
	const KNOCKBACK := 32.0
	for s in all_ships:
		if s == self or not is_instance_valid(s) or not s.alive:
			continue
		var diff    : Vector3 = s.global_position - global_position
		var dist    : float   = diff.length()
		if dist < RADIUS:
			var falloff : float = 1.0 - (dist / RADIUS) * 0.4
			s.take_damage(int(DAMAGE * falloff))
			# Knock them away from the Scavenger
			if dist > 0.1:
				s.velocity += diff.normalized() * KNOCKBACK

func _fx_emp_ring() -> void:
	var ring     := MeshInstance3D.new()
	var tm       := TorusMesh.new()
	tm.outer_radius = 1.0
	tm.inner_radius = 0.7
	ring.mesh    = tm
	var rmat     := StandardMaterial3D.new()
	rmat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_color              = Color(1.0, 0.9, 0.1, 0.9)
	rmat.emission_enabled          = true
	rmat.emission                  = Color(1.0, 0.7, 0.0)
	rmat.emission_energy_multiplier = 5.0
	rmat.cull_mode                 = BaseMaterial3D.CULL_DISABLED
	ring.material_override         = rmat
	add_child(ring)
	var t := create_tween()
	t.tween_property(ring, "scale", Vector3(28, 28, 28), 0.7)
	t.parallel().tween_property(rmat, "albedo_color:a", 0.0, 0.7)
	t.tween_callback(ring.queue_free)

func _fx_teleport_flash(from: Vector3) -> void:
	var flash    := MeshInstance3D.new()
	var sm       := SphereMesh.new()
	sm.radius    = 2.0
	flash.mesh   = sm
	var fmat     := StandardMaterial3D.new()
	fmat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.albedo_color              = Color(0.75, 0.3, 1.0, 0.85)
	fmat.emission_enabled          = true
	fmat.emission                  = Color(0.5, 0.1, 1.0)
	fmat.emission_energy_multiplier = 6.0
	fmat.cull_mode                 = BaseMaterial3D.CULL_DISABLED
	flash.material_override = fmat
	get_parent().add_child(flash)
	flash.global_position   = from   # set after added to tree
	var t := create_tween()
	t.tween_property(flash, "scale", Vector3(3.5, 3.5, 3.5), 0.35)
	t.parallel().tween_property(fmat, "albedo_color:a", 0.0, 0.35)
	t.tween_callback(flash.queue_free)

# ── Specials ──────────────────────────────────────────────────────────────────

func _trigger_special() -> void:
	special_cd  = 8.0
	special_dur = 0.0

	match special:
		"speed_burst":
			speed_boosted = true
			special_dur   = 2.0
			# Bright cyan engine trail
			ship_mat.emission                  = Color(0.0, 1.0, 1.0)
			ship_mat.emission_energy_multiplier = 4.0

		"shield":
			shielded              = true
			special_dur           = 3.0
			shield_mesh.visible   = true
			ship_mat.emission                  = Color(0.3, 0.6, 1.0)
			ship_mat.emission_energy_multiplier = 2.5

		"cloak":
			cloaked     = true
			special_dur = 2.0
			model_node.visible    = false
			mesh_instance.visible = false

		"ram_boost":
			velocity   += -transform.basis.z * 45.0   # keep the lunge
			special_dur = 0.3
			_fx_shockwave()
			_apply_shockwave()

		"emp":
			_do_emp()
			_fx_emp_ring()

		"teleport":
			_fx_teleport_flash(global_position)
			position += -transform.basis.z * 24.0

func _tick_specials(delta: float) -> void:
	if special_dur > 0.0:
		special_dur -= delta
		if special_dur <= 0.0:
			_deactivate_special()

func _deactivate_special() -> void:
	speed_boosted = false
	if shielded:
		shielded              = false
		shield_mesh.visible   = false
	if cloaked:
		cloaked               = false
		model_node.visible    = true
		mesh_instance.visible = true
	_restore_emission()

func _restore_emission() -> void:
	ship_mat.emission                  = Color(PLAYER_COLORS[slot % PLAYER_COLORS.size()])
	ship_mat.emission_energy_multiplier = 0.6

func _do_emp() -> void:
	for s in all_ships:
		if s == self or not is_instance_valid(s) or not s.alive:
			continue
		if global_position.distance_to(s.global_position) < 28.0:
			s.emp_disabled   = true
			s.inp_firing     = false   # cuts beam / fire instantly
			s.inp_thrust     = 0.0
			s._thrust_target = 0.0
			get_tree().create_timer(3.0).timeout.connect(
				func(): if is_instance_valid(s): s.emp_disabled = false)

# ── Damage ────────────────────────────────────────────────────────────────────

func take_damage(amount: int) -> void:
	if not alive or shielded or invincible:
		return
	hp -= amount
	_flash_hit()
	if hp <= 0:
		hp = 0
		_die()

func _flash_hit() -> void:
	if is_instance_valid(_snd_hit):
		_snd_hit.play()
	ship_mat.emission = Color(1, 0.1, 0.1)
	get_tree().create_timer(0.08).timeout.connect(_restore_color)

func _restore_color() -> void:
	# Only restore if no special is currently active
	if is_instance_valid(self) and alive and special_dur <= 0.0:
		_restore_emission()


func _die() -> void:
	alive   = false
	visible = false
	for child in get_children():
		if child is Area3D and child.has_meta("ship"):
			child.remove_meta("ship")
	_spawn_death_explosion()
	died.emit(slot)
	await get_tree().create_timer(0.05).timeout
	queue_free()

func _spawn_death_explosion() -> void:
	# Play explosion sound on a detached player so it outlives the ship node
	if _sfx_death != null:
		var snd := AudioStreamPlayer.new()
		snd.stream    = _sfx_death
		snd.volume_db = 4.0
		get_parent().add_child(snd)
		snd.play()
		get_tree().create_timer(1.2).timeout.connect(func(): if is_instance_valid(snd): snd.queue_free())

	var col : Color = Color(PLAYER_COLORS[slot % PLAYER_COLORS.size()])
	var fx          := Node3D.new()
	get_parent().add_child(fx)
	fx.global_position = global_position

	# ── Core blast — fast shards in all directions ────────────────────────────
	var burst                     := GPUParticles3D.new()
	burst.amount                   = 60
	burst.lifetime                 = 0.7
	burst.one_shot                 = true
	burst.explosiveness            = 0.98
	burst.randomness               = 0.2
	burst.local_coords             = false

	var bmat                       := ParticleProcessMaterial.new()
	bmat.emission_shape             = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	bmat.emission_sphere_radius     = 0.5
	bmat.spread                     = 180.0
	bmat.initial_velocity_min       = 15.0
	bmat.initial_velocity_max       = 45.0
	bmat.angular_velocity_min       = -720.0
	bmat.angular_velocity_max       = 720.0
	bmat.gravity                    = Vector3.ZERO
	bmat.damping_min                = 10.0
	bmat.damping_max                = 30.0
	bmat.scale_min                  = 0.08
	bmat.scale_max                  = 0.28

	var bg  := Gradient.new()
	bg.set_color(0, Color(3.0, 2.5, 1.5, 1.0))
	bg.add_point(0.15, Color(col.r * 2.5, col.g * 2.5, col.b * 2.5, 1.0))
	bg.add_point(0.5,  Color(col.r, col.g, col.b, 0.8))
	bg.add_point(1.0,  Color(col.r * 0.2, col.g * 0.2, col.b * 0.2, 0.0))
	var bgt := GradientTexture1D.new()
	bgt.gradient = bg
	bmat.color_ramp = bgt

	var bmesh      := SphereMesh.new()
	bmesh.radius    = 0.08
	bmesh.height    = 0.16
	var bm_mat     := StandardMaterial3D.new()
	bm_mat.albedo_color               = Color.WHITE
	bm_mat.emission_enabled           = true
	bm_mat.emission                   = Color.WHITE
	bm_mat.emission_energy_multiplier = 8.0
	bm_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmesh.surface_set_material(0, bm_mat)
	burst.draw_pass_1     = bmesh
	burst.process_material = bmat
	fx.add_child(burst)

	# ── Debris drift — slower chunks that linger and cool ─────────────────────
	var debris                    := GPUParticles3D.new()
	debris.amount                  = 30
	debris.lifetime                = 1.8
	debris.one_shot                = true
	debris.explosiveness           = 0.85
	debris.randomness              = 0.4
	debris.local_coords            = false

	var dmat                       := ParticleProcessMaterial.new()
	dmat.emission_shape             = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	dmat.emission_sphere_radius     = 0.4
	dmat.spread                     = 180.0
	dmat.initial_velocity_min       = 4.0
	dmat.initial_velocity_max       = 16.0
	dmat.angular_velocity_min       = -180.0
	dmat.angular_velocity_max       = 180.0
	dmat.gravity                    = Vector3(0, -2.0, 0)
	dmat.damping_min                = 1.0
	dmat.damping_max                = 4.0
	dmat.scale_min                  = 0.12
	dmat.scale_max                  = 0.35

	var dg  := Gradient.new()
	dg.set_color(0, Color(col.r * 2.0, col.g * 2.0, col.b * 2.0, 1.0))
	dg.add_point(0.3, Color(1.0, 0.45, 0.05, 1.0))
	dg.add_point(0.7, Color(0.3, 0.1, 0.0, 0.6))
	dg.add_point(1.0, Color(0.05, 0.05, 0.05, 0.0))
	var dgt := GradientTexture1D.new()
	dgt.gradient = dg
	dmat.color_ramp = dgt

	var dmesh      := SphereMesh.new()
	dmesh.radius    = 0.10
	dmesh.height    = 0.20
	var dm_mat     := StandardMaterial3D.new()
	dm_mat.albedo_color               = Color.WHITE
	dm_mat.emission_enabled           = true
	dm_mat.emission                   = Color.WHITE
	dm_mat.emission_energy_multiplier = 5.0
	dm_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmesh.surface_set_material(0, dm_mat)
	debris.draw_pass_1     = dmesh
	debris.process_material = dmat
	fx.add_child(debris)

	# ── Blinding flash light ──────────────────────────────────────────────────
	var light             := OmniLight3D.new()
	light.light_color      = Color(1.0, 0.8, 0.4)
	light.light_energy     = 30.0
	light.omni_range       = 30.0
	light.shadow_enabled   = false
	fx.add_child(light)

	burst.restart()
	debris.restart()

	var t := fx.create_tween()
	t.tween_property(light, "light_energy", 0.0, 0.3)
	t.tween_callback(fx.queue_free).set_delay(2.0)
