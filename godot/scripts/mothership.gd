extends Node3D

signal died

# ── Identity (duck-typed as ship so projectiles work unchanged) ───────────────
var slot     : int    = 100
var team     : int    = 1
var alive    : bool   = true
var hp       : int    = 3000
var max_hp   : int    = 3000
var velocity      : Vector3 = Vector3.ZERO   # needed for asteroid bounce duck-typing
var _collision_cd : float   = 0.0            # duck-typed alongside ship.gd

# ── Refs ──────────────────────────────────────────────────────────────────────
var hit_area  : Area3D   # first hit zone (kept for compatibility)
var _push_area: Area3D   # monitors asteroid layer to push rocks away

# ── Linear patrol ─────────────────────────────────────────────────────────────
const PATROL_SPEED : float   = 6.0
const ARRIVE_DIST  : float   = 20.0
const PATH_START   : Vector3 = Vector3(-3500, 0,  0)
const PATH_END     : Vector3 = Vector3( 3500, 0,  0)
var _path_dir      : int     = 1   # 1 = toward end, -1 = toward start

# ── Assets ────────────────────────────────────────────────────────────────────
const _MESH     := preload("res://assets/mothership/model_0.obj")
const _TEX_ALB  := preload("res://assets/mothership/S_PLS_MS001_albedo.tga.png")
const _TEX_EMIT := preload("res://assets/mothership/S_PLS_MS001_emissive.tga.png")
const _TEX_NORM := preload("res://assets/mothership/S_PLS_MS001_normal.tga.png")
const _TEX_SPEC := preload("res://assets/mothership/S_PLS_MS001_specular.tga.png")

# ── Setup ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_build_visuals()
	_build_hit_area()

func _build_visuals() -> void:
	var mi               := MeshInstance3D.new()
	mi.mesh               = _MESH
	mi.scale              = Vector3(2.0, 2.0, 2.0)
	mi.rotation_degrees.x = 90.0   # OBJ is Z-up; rotate to Godot Y-up
	var mat               := StandardMaterial3D.new()
	mat.albedo_texture             = _TEX_ALB
	mat.emission_enabled           = true
	mat.emission_texture           = _TEX_EMIT
	mat.emission_energy_multiplier = 2.5
	mat.normal_enabled             = true
	mat.normal_texture             = _TEX_NORM
	mat.metallic_texture           = _TEX_SPEC
	mat.metallic_texture_channel   = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.metallic                   = 1.0
	mat.roughness                  = 0.35
	mi.material_override           = mat
	add_child(mi)

	# Red health ring indicator
	var ring_mesh         := CylinderMesh.new()
	ring_mesh.height       = 0.2
	ring_mesh.top_radius   = 6.0
	ring_mesh.bottom_radius = 6.0
	var ring_mi           := MeshInstance3D.new()
	ring_mi.mesh           = ring_mesh
	ring_mi.position.y     = -1.0
	var ring_mat          := StandardMaterial3D.new()
	ring_mat.albedo_color               = Color(1.0, 0.1, 0.1)
	ring_mat.emission_enabled           = true
	ring_mat.emission                   = Color(1.0, 0.0, 0.0)
	ring_mat.emission_energy_multiplier = 4.0
	ring_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mi.material_override           = ring_mat
	add_child(ring_mi)

func _build_hit_area() -> void:
	# ── Single box hitbox covering the full ship body ─────────────────────────
	# Model after rotation_degrees.x=90 at scale 2: length ~174 along Z,
	# width ~40 along X, height ~16 along Y. Center offset ~Z+90.
	hit_area                  = Area3D.new()
	hit_area.name             = "HitArea"
	hit_area.collision_layer  = 1
	hit_area.collision_mask   = 0
	hit_area.monitorable      = true
	hit_area.monitoring       = false
	hit_area.set_meta("ship", self)

	const BOX_SIZE   := Vector3(38.0, 16.0, 380.0)
	const BOX_OFFSET := Vector3(0.0,   5.0, 90.0)

	var shape         := BoxShape3D.new()
	shape.size         = BOX_SIZE
	var col           := CollisionShape3D.new()
	col.shape          = shape
	col.position       = BOX_OFFSET
	hit_area.add_child(col)


	add_child(hit_area)

	# ── Large push area — shoves asteroids out of the way ─────────────────────
	_push_area                  = Area3D.new()
	_push_area.name             = "PushArea"
	_push_area.collision_layer  = 0
	_push_area.collision_mask   = 2   # asteroid layer
	_push_area.monitorable      = false
	_push_area.monitoring       = true
	var pcol   := CollisionShape3D.new()
	var pshape := SphereShape3D.new()
	pshape.radius = 110.0
	pcol.shape    = pshape
	_push_area.add_child(pcol)
	add_child(_push_area)

# ── Process ───────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not alive:
		return
	_collision_cd = maxf(0.0, _collision_cd - delta)
	_patrol(delta)
	_push_nearby_asteroids(delta)

func _push_nearby_asteroids(_delta: float) -> void:
	if _push_area == null:
		return
	for area in _push_area.get_overlapping_areas():
		if not area.get_meta("asteroid", false):
			continue
		var asteroid : Node3D = area.get_parent()
		if not is_instance_valid(asteroid):
			continue
		var away : Vector3 = asteroid.global_position - global_position
		away.y = 0.0
		if away.length_squared() < 0.01:
			away = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
		away = away.normalized()
		if "ast_vel" in asteroid:
			# Siege asteroid with velocity script — add impulse and wake it up
			asteroid.ast_vel += away * 8.0
			asteroid.set_process(true)
		else:
			# Fallback for non-siege asteroids
			asteroid.global_position += away * 40.0 * _delta

func _patrol(delta: float) -> void:
	var target : Vector3 = PATH_END if _path_dir == 1 else PATH_START
	var dir    : Vector3 = target - global_position
	dir.y = 0.0
	if dir.length() < ARRIVE_DIST:
		_path_dir *= -1   # reverse at each end
		return
	global_position += dir.normalized() * PATROL_SPEED * delta
	global_position.y = 0.0
	look_at(global_position + dir.normalized(), Vector3.UP)

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
	for child in get_children():
		if child is Area3D and child.has_meta("ship"):
			child.remove_meta("ship")
	_spawn_death_explosion()
	died.emit()
	await get_tree().create_timer(0.1).timeout
	queue_free()

func _spawn_death_explosion() -> void:
	var fx := Node3D.new()
	get_parent().add_child(fx)
	fx.global_position = global_position

	# Wave 1 — massive shockwave burst
	var burst                    := GPUParticles3D.new()
	burst.amount                  = 120
	burst.lifetime                = 1.5
	burst.one_shot                = true
	burst.explosiveness           = 0.98
	burst.randomness              = 0.25
	burst.local_coords            = false

	var bmat                      := ParticleProcessMaterial.new()
	bmat.emission_shape            = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	bmat.emission_sphere_radius    = 2.0
	bmat.spread                    = 180.0
	bmat.initial_velocity_min      = 20.0
	bmat.initial_velocity_max      = 65.0
	bmat.angular_velocity_min      = -720.0
	bmat.angular_velocity_max      = 720.0
	bmat.gravity                   = Vector3.ZERO
	bmat.damping_min               = 6.0
	bmat.damping_max               = 18.0
	bmat.scale_min                 = 0.15
	bmat.scale_max                 = 0.55

	var bg  := Gradient.new()
	bg.set_color(0, Color(4.0, 3.0, 1.5, 1.0))
	bg.add_point(0.15, Color(2.0, 0.7, 0.05, 1.0))
	bg.add_point(0.55, Color(0.8, 0.2, 0.0,  0.7))
	bg.add_point(1.0,  Color(0.05, 0.05, 0.0, 0.0))
	var bgt := GradientTexture1D.new()
	bgt.gradient = bg
	bmat.color_ramp = bgt

	var bmesh   := SphereMesh.new()
	bmesh.radius = 0.14
	bmesh.height = 0.28
	var bm_mat  := StandardMaterial3D.new()
	bm_mat.albedo_color               = Color.WHITE
	bm_mat.emission_enabled           = true
	bm_mat.emission                   = Color.WHITE
	bm_mat.emission_energy_multiplier = 10.0
	bm_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmesh.surface_set_material(0, bm_mat)
	burst.draw_pass_1     = bmesh
	burst.process_material = bmat
	fx.add_child(burst)

	# Wave 2 — lingering debris
	var debris                    := GPUParticles3D.new()
	debris.amount                  = 60
	debris.lifetime                = 3.5
	debris.one_shot                = true
	debris.explosiveness           = 0.85
	debris.randomness              = 0.45
	debris.local_coords            = false

	var dmat                      := ParticleProcessMaterial.new()
	dmat.emission_shape            = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	dmat.emission_sphere_radius    = 1.5
	dmat.spread                    = 180.0
	dmat.initial_velocity_min      = 3.0
	dmat.initial_velocity_max      = 20.0
	dmat.gravity                   = Vector3(0, -1.5, 0)
	dmat.damping_min               = 0.5
	dmat.damping_max               = 3.0
	dmat.scale_min                 = 0.18
	dmat.scale_max                 = 0.55

	var dg  := Gradient.new()
	dg.set_color(0, Color(2.0, 0.8, 0.1, 1.0))
	dg.add_point(0.3, Color(1.0, 0.35, 0.0, 0.9))
	dg.add_point(0.7, Color(0.25, 0.08, 0.0, 0.6))
	dg.add_point(1.0, Color(0.04, 0.04, 0.04, 0.0))
	var dgt := GradientTexture1D.new()
	dgt.gradient = dg
	dmat.color_ramp = dgt
	debris.draw_pass_1     = bmesh
	debris.process_material = dmat
	fx.add_child(debris)

	# Blinding flash
	var light             := OmniLight3D.new()
	light.light_color      = Color(1.0, 0.75, 0.3)
	light.light_energy     = 80.0
	light.omni_range       = 120.0
	light.shadow_enabled   = false
	fx.add_child(light)

	burst.restart()
	debris.restart()

	var t := fx.create_tween()
	t.tween_property(light, "light_energy", 0.0, 0.6)
	t.tween_callback(fx.queue_free).set_delay(4.0)
