extends Node3D

signal died(slot: int)

# ── Identity (duck-typed as ship so projectiles/collisions work unchanged) ────
var slot    : int   = 200
var team    : int   = 1
var alive   : bool  = true
var hp      : int   = 140
var max_hp  : int   = 140

# ── Physics ───────────────────────────────────────────────────────────────────
var velocity       : Vector3 = Vector3.ZERO
const SPEED        := 45.0
const TURN_SPEED   := 2.8
const LIN_DRAG     := 0.97

# ── Combat ────────────────────────────────────────────────────────────────────
var _fire_cd         : float = 0.0
const FIRE_RATE      : float = 1.5
const ATTACK_RANGE   : float = 200.0
var _collision_cd    : float = 0.0
var _bounce_timer    : float = 0.0   # suppresses AI thrust after mothership bounce
const MS_MIN_DIST    : float = 90.0  # minimum separation from mothership

# ── AI ────────────────────────────────────────────────────────────────────────
var mothership       : Node3D  = null
var all_ships        : Array   = []

# ── References (set by game.gd before adding to scene) ───────────────────────
var projectile_scene : PackedScene
var projectiles_node : Node3D

# ── Assets ────────────────────────────────────────────────────────────────────
const _PARTS := [
	preload("res://assets/minion/model_0.obj"),
	preload("res://assets/minion/model_1.obj"),
	preload("res://assets/minion/model_2.obj"),
	preload("res://assets/minion/model_3.obj"),
	preload("res://assets/minion/model_4.obj"),
	preload("res://assets/minion/model_5.obj"),
	preload("res://assets/minion/model_6.obj"),
	preload("res://assets/minion/model_7.obj"),
]
const _TEXTURES := [
	preload("res://assets/minion/Blaster.png"),
	preload("res://assets/minion/Braces.png"),
	preload("res://assets/minion/Head.png"),
	preload("res://assets/minion/Pulsor.png"),
	preload("res://assets/minion/Spheare.png"),
	preload("res://assets/minion/Turbine.png"),
	preload("res://assets/minion/Wings.png"),
	preload("res://assets/minion/Braces.png"),   # model_7 reuses braces texture
]

# ── Setup ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_build_visuals()
	_build_hit_area()

func _build_visuals() -> void:
	for i in _PARTS.size():
		var mi               := MeshInstance3D.new()
		mi.mesh               = _PARTS[i]
		mi.scale              = Vector3.ONE * 5.0
		mi.rotation_degrees.x = 90.0   # OBJ is Z-up; rotate to Godot Y-up
		var mat              := StandardMaterial3D.new()
		mat.albedo_texture = _TEXTURES[i]
		mat.metallic       = 0.5
		mat.roughness      = 0.5
		mi.material_override = mat
		add_child(mi)

	# Enemy red ring
	var ring_mesh          := CylinderMesh.new()
	ring_mesh.height        = 0.12
	ring_mesh.top_radius    = 1.5
	ring_mesh.bottom_radius = 1.5
	var ring_mi            := MeshInstance3D.new()
	ring_mi.mesh            = ring_mesh
	ring_mi.position.y      = -0.5
	var ring_mat           := StandardMaterial3D.new()
	ring_mat.albedo_color               = Color(1.0, 0.1, 0.1)
	ring_mat.emission_enabled           = true
	ring_mat.emission                   = Color(1.0, 0.0, 0.0)
	ring_mat.emission_energy_multiplier = 3.5
	ring_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mi.material_override           = ring_mat
	add_child(ring_mi)

func _build_hit_area() -> void:
	var ha                 := Area3D.new()
	ha.name                 = "HitArea"
	ha.collision_layer      = 1
	ha.collision_mask       = 1   # detect other layer-1 areas (mothership hit zones)
	ha.monitorable          = true
	ha.monitoring           = true
	ha.set_meta("ship", self)
	var col   := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(8.0, 4.0, 11.0)
	col.shape  = shape
	ha.add_child(col)
	add_child(ha)
	ha.area_entered.connect(_on_hit_area_entered)

func _on_hit_area_entered(area: Area3D) -> void:
	if _collision_cd > 0.0:
		return
	var other = area.get_meta("ship", null)
	if not is_instance_valid(other) or not other.alive:
		return
	if other == self:
		return
	# Only bounce off the mothership (slot 100), not other minions
	if other.slot < 100 or other.slot >= 200:
		return
	_collision_cd = 0.8
	_bounce_timer = 1.2
	var away : Vector3 = global_position - (other.global_position as Vector3)
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = Vector3(0.0, 0.0, 1.0)
	velocity = away.normalized() * 50.0

# ── Process ───────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not alive:
		return
	_fire_cd      = maxf(0.0, _fire_cd      - delta)
	_collision_cd = maxf(0.0, _collision_cd - delta)
	_bounce_timer = maxf(0.0, _bounce_timer - delta)
	_ai(delta)

func _ai(delta: float) -> void:
	# Find nearest enemy (player ship, team != 1)
	var nearest      : Node3D = null
	var nearest_dist : float  = INF
	for s in all_ships:
		if not is_instance_valid(s) or not s.alive:
			continue
		if s.team == team:
			continue
		var d : float = global_position.distance_to(s.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = s

	# ── Mothership repulsion — always push away if too close ─────────────────
	var ms_dist : float = INF
	if is_instance_valid(mothership) and mothership.alive:
		ms_dist = global_position.distance_to(mothership.global_position as Vector3)
		if ms_dist < MS_MIN_DIST:
			var away : Vector3 = global_position - (mothership.global_position as Vector3)
			away.y = 0.0
			if away.length_squared() < 0.01:
				away = Vector3(0.0, 0.0, 1.0)
			velocity += away.normalized() * SPEED * 0.8 * delta
			velocity.y  = 0.0
			velocity   *= LIN_DRAG
			global_position += velocity * delta
			global_position.y = 0.0
			return

	# Decide target and thrust
	var target_pos : Vector3
	var thrust     : float

	if _bounce_timer > 0.0:
		# Just bounced — coast away, no AI thrust
		velocity.y  = 0.0
		velocity   *= LIN_DRAG
		global_position += velocity * delta
		global_position.y = 0.0
		return
	elif nearest != null and nearest_dist < ATTACK_RANGE:
		# Player in range — full thrust + fire
		target_pos = nearest.global_position
		thrust     = 1.0
		if _fire_cd <= 0.0:
			_fire_at(nearest)
	elif is_instance_valid(mothership) and mothership.alive:
		# Follow mothership — proportional thrust so they shadow it at its speed
		target_pos = mothership.global_position
		thrust = clamp(ms_dist / 25.0, 0.03, 0.45)
	else:
		velocity.y  = 0.0
		velocity   *= LIN_DRAG
		global_position += velocity * delta
		global_position.y = 0.0
		return

	# Steer toward target
	var dir : Vector3 = target_pos - global_position
	dir.y = 0.0
	if dir.length() > 1.5:
		var desired_fwd : Vector3 = dir.normalized()
		var current_fwd : Vector3 = -transform.basis.z
		var angle       : float   = current_fwd.signed_angle_to(desired_fwd, Vector3.UP)
		rotate_y(clamp(angle, -TURN_SPEED * delta, TURN_SPEED * delta))
		velocity += -transform.basis.z * thrust * SPEED * delta

	velocity.y  = 0.0
	velocity   *= LIN_DRAG
	global_position += velocity * delta
	global_position.y = 0.0

func _fire_at(target: Node3D) -> void:
	if not projectile_scene or not projectiles_node:
		return
	_fire_cd = FIRE_RATE
	var fwd     : Vector3 = -transform.basis.z
	var gun_pos : Vector3 = global_position + fwd * 2.0 + Vector3.UP * 0.1
	var aim_dir : Vector3 = (target.global_position - gun_pos)
	aim_dir.y = 0.0
	aim_dir   = aim_dir.normalized()

	var p = projectile_scene.instantiate()
	p.weapon_type      = "rapid_laser"
	p.owner_color      = Color(1.0, 0.2, 0.15)   # hostile red bolts
	p.bolt_sprite_path = ""
	p.owner_team       = team
	projectiles_node.add_child(p)
	p.init(gun_pos, aim_dir, 32.0, 5, slot)
	p.velocity += velocity

# ── Damage ────────────────────────────────────────────────────────────────────
func take_damage(amount: int) -> void:
	if not alive:
		return
	hp = maxi(0, hp - amount)
	if hp == 0:
		_die()

func _die() -> void:
	alive   = false
	visible = false
	# Clear ship meta so freed instance isn't accessed by other area callbacks
	for child in get_children():
		if child is Area3D and child.has_meta("ship"):
			child.remove_meta("ship")
	_spawn_death_explosion()
	died.emit(slot)
	await get_tree().create_timer(0.05).timeout
	queue_free()

func _spawn_death_explosion() -> void:
	var col : Color = Color(1.0, 0.25, 0.1)
	var fx          := Node3D.new()
	get_parent().add_child(fx)
	fx.global_position = global_position

	var burst                    := GPUParticles3D.new()
	burst.amount                  = 45
	burst.lifetime                = 0.65
	burst.one_shot                = true
	burst.explosiveness           = 0.97
	burst.randomness              = 0.2
	burst.local_coords            = false

	var bmat                      := ParticleProcessMaterial.new()
	bmat.emission_shape            = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	bmat.emission_sphere_radius    = 0.4
	bmat.spread                    = 180.0
	bmat.initial_velocity_min      = 12.0
	bmat.initial_velocity_max      = 38.0
	bmat.gravity                   = Vector3.ZERO
	bmat.damping_min               = 8.0
	bmat.damping_max               = 24.0
	bmat.scale_min                 = 0.07
	bmat.scale_max                 = 0.22

	var bg  := Gradient.new()
	bg.set_color(0, Color(3.0, 2.0, 1.0, 1.0))
	bg.add_point(0.2, Color(col.r * 2.2, col.g * 2.2, col.b * 2.2, 1.0))
	bg.add_point(0.6, Color(col.r, col.g, col.b, 0.7))
	bg.add_point(1.0, Color(0.08, 0.04, 0.0, 0.0))
	var bgt := GradientTexture1D.new()
	bgt.gradient = bg
	bmat.color_ramp = bgt

	var bmesh  := SphereMesh.new()
	bmesh.radius = 0.07
	bmesh.height = 0.14
	var bm_mat := StandardMaterial3D.new()
	bm_mat.albedo_color               = Color.WHITE
	bm_mat.emission_enabled           = true
	bm_mat.emission                   = Color.WHITE
	bm_mat.emission_energy_multiplier = 8.0
	bm_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmesh.surface_set_material(0, bm_mat)
	burst.draw_pass_1     = bmesh
	burst.process_material = bmat
	fx.add_child(burst)

	var light             := OmniLight3D.new()
	light.light_color      = Color(1.0, 0.4, 0.1)
	light.light_energy     = 20.0
	light.omni_range       = 22.0
	light.shadow_enabled   = false
	fx.add_child(light)

	burst.restart()

	var t := fx.create_tween()
	t.tween_property(light, "light_energy", 0.0, 0.25)
	t.tween_callback(fx.queue_free).set_delay(1.0)
