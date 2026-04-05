extends Area3D
class_name Projectile

const _M0 := preload("res://assets/ships/model_0.obj")
const _M1 := preload("res://assets/ships/model_1.obj")
const _M2 := preload("res://assets/ships/model_2.obj")
const _M3 := preload("res://assets/ships/model_3.obj")
const _TEX_METAL  := preload("res://assets/ships/space_mine_Material.003_Metallic.png")
const _TEX_ROUGH  := preload("res://assets/ships/space_mine_Material.003_Roughness.png")
const _TEX_NORM   := preload("res://assets/ships/space_mine_Material.003_Normal.png")
const _TEX_EMIT   := preload("res://assets/ships/space_mine_Material.003_Emissive.png")
const _TEX_HEIGHT := preload("res://assets/ships/space_mine_Material.003_Height.png")

static var _mine_mat_cache : StandardMaterial3D = null

var velocity    := Vector3.ZERO
var damage      := 10
var owner_slot  := -1
var owner_team  := -1
var owner_color       : Color  = Color(0.2, 1.0, 0.3)   # set before add_child
var bolt_sprite_path  : String = ""                      # set before add_child
var lifetime    := 3.0
var homing_target: Node3D = null
var homing_strength := 4.0
var weapon_type : String = "bullet"   # set before add_child

# visual refs for animated effects
var _core_mat  : StandardMaterial3D = null
var _mine_spin : float = 0.0

func _ready() -> void:
	area_entered.connect(_on_area_entered)
	monitoring       = true
	monitorable      = false
	collision_mask   = 3   # layer 1 = ships, layer 2 = asteroids
	_build_visuals()

func _build_visuals() -> void:
	match weapon_type:
		"rapid_laser":   _vis_bolt(owner_color, 0.06, 0.55)
		"spread_shot":   _vis_bolt(owner_color, 0.06, 0.40)
		"heavy_cannon":  _vis_orb (Color(1.0, 0.35, 0.0), 0.38)
		"homing_missile":_vis_missile()
		"mine":          _vis_mine()
		_:               _vis_bolt(owner_color, 0.06, 0.55)

# ── Emissive bolt + OmniLight ─────────────────────────────────────────────────
func _vis_bolt(col: Color, radius: float, length: float) -> void:
	# Core capsule
	var core_mesh             := CapsuleMesh.new()
	core_mesh.radius           = radius
	core_mesh.height           = length
	var core_mi               := MeshInstance3D.new()
	core_mi.mesh               = core_mesh
	core_mi.rotation_degrees.x = 90.0
	_core_mat                  = StandardMaterial3D.new()
	_core_mat.albedo_color               = col
	_core_mat.emission_enabled           = true
	_core_mat.emission                   = col
	_core_mat.emission_energy_multiplier = 12.0
	_core_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mi.material_override            = _core_mat
	add_child(core_mi)

	# Soft outer glow shell
	var glow_mesh             := CapsuleMesh.new()
	glow_mesh.radius           = radius * 2.5
	glow_mesh.height           = length * 0.7
	var glow_mi               := MeshInstance3D.new()
	glow_mi.mesh               = glow_mesh
	glow_mi.rotation_degrees.x = 90.0
	var glow_mat               := StandardMaterial3D.new()
	glow_mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.albedo_color               = Color(col.r, col.g, col.b, 0.15)
	glow_mat.emission_enabled           = true
	glow_mat.emission                   = col
	glow_mat.emission_energy_multiplier = 4.0
	glow_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	glow_mi.material_override           = glow_mat
	add_child(glow_mi)

	# Point light — illuminates ships/asteroids as the bolt passes
	var light            := OmniLight3D.new()
	light.light_color     = col
	light.light_energy    = 3.0
	light.omni_range      = 8.0
	light.shadow_enabled  = false
	add_child(light)

# ── Heavy cannon energy orb ───────────────────────────────────────────────────
func _vis_orb(col: Color, radius: float) -> void:
	var core_mesh    := SphereMesh.new()
	core_mesh.radius = radius
	core_mesh.height = radius * 2.0
	var core_mi      := MeshInstance3D.new()
	core_mi.mesh     = core_mesh
	_core_mat        = StandardMaterial3D.new()
	_core_mat.albedo_color               = col
	_core_mat.emission_enabled           = true
	_core_mat.emission                   = col
	_core_mat.emission_energy_multiplier = 10.0
	_core_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mi.material_override            = _core_mat
	add_child(core_mi)

	# Pulsing outer corona
	var halo_mesh    := SphereMesh.new()
	halo_mesh.radius = radius * 2.0
	halo_mesh.height = radius * 4.0
	var halo_mi      := MeshInstance3D.new()
	halo_mi.mesh     = halo_mesh
	var halo_mat     := StandardMaterial3D.new()
	halo_mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	halo_mat.albedo_color              = Color(col.r, col.g, col.b, 0.12)
	halo_mat.emission_enabled          = true
	halo_mat.emission                  = col
	halo_mat.emission_energy_multiplier = 2.5
	halo_mat.shading_mode              = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo_mat.cull_mode                 = BaseMaterial3D.CULL_DISABLED
	halo_mi.material_override          = halo_mat
	add_child(halo_mi)

	var light            := OmniLight3D.new()
	light.light_color     = col
	light.light_energy    = 5.0
	light.omni_range      = 12.0
	light.shadow_enabled  = false
	add_child(light)

# ── Homing missile ────────────────────────────────────────────────────────────
func _vis_missile() -> void:
	var col := Color(1.0, 0.45, 0.0)

	# Missile body
	var body_mesh       := CapsuleMesh.new()
	body_mesh.radius    = 0.12
	body_mesh.height    = 0.7
	var body_mi         := MeshInstance3D.new()
	body_mi.mesh        = body_mesh
	body_mi.rotation_degrees.x = 90.0
	_core_mat           = StandardMaterial3D.new()
	_core_mat.albedo_color               = col
	_core_mat.emission_enabled           = true
	_core_mat.emission                   = col
	_core_mat.emission_energy_multiplier = 5.0
	_core_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	body_mi.material_override            = _core_mat
	add_child(body_mi)

	# Engine exhaust glow (behind the missile)
	var exhaust_mesh    := SphereMesh.new()
	exhaust_mesh.radius = 0.18
	exhaust_mesh.height = 0.36
	var exhaust_mi      := MeshInstance3D.new()
	exhaust_mi.mesh     = exhaust_mesh
	exhaust_mi.position = Vector3(0, 0, 0.4)   # behind (+Z = back when rotated)
	var ex_mat          := StandardMaterial3D.new()
	ex_mat.albedo_color               = Color(0.4, 0.8, 1.0)
	ex_mat.emission_enabled           = true
	ex_mat.emission                   = Color(0.3, 0.7, 1.0)
	ex_mat.emission_energy_multiplier = 12.0
	ex_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	exhaust_mi.material_override      = ex_mat
	add_child(exhaust_mi)

const MINE_MODELS := [
	"res://assets/ships/model_0.obj",
	"res://assets/ships/model_1.obj",
	"res://assets/ships/model_2.obj",
	"res://assets/ships/model_3.obj",
]

# ── Floating mine ─────────────────────────────────────────────────────────────
func _vis_mine() -> void:
	# Build (or reuse) PBR material — created once, shared across all mines
	if _mine_mat_cache == null:
		var m := StandardMaterial3D.new()
		m.albedo_color                  = Color(0.6, 0.6, 0.65)
		m.metallic_texture              = _TEX_METAL
		m.metallic_texture_channel      = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.roughness_texture             = _TEX_ROUGH
		m.roughness_texture_channel     = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.normal_enabled                = true
		m.normal_texture                = _TEX_NORM
		m.emission_enabled              = true
		m.emission_texture              = _TEX_EMIT
		m.emission_energy_multiplier    = 2.5
		m.heightmap_enabled             = true
		m.heightmap_texture             = _TEX_HEIGHT
		_mine_mat_cache = m

	# Combine all 4 preloaded obj parts
	for mesh_res : Mesh in [_M0, _M1, _M2, _M3]:
		var mi              := MeshInstance3D.new()
		mi.mesh              = mesh_res
		mi.scale             = Vector3.ONE * 0.3
		mi.material_override = _mine_mat_cache
		add_child(mi)

	# Pulsing red warning core (animated in _process)
	var core_mesh    := SphereMesh.new()
	core_mesh.radius = 0.22
	core_mesh.height = 0.44
	var core_mi      := MeshInstance3D.new()
	core_mi.mesh     = core_mesh
	_core_mat        = StandardMaterial3D.new()
	_core_mat.albedo_color               = Color(1.0, 0.05, 0.05)
	_core_mat.emission_enabled           = true
	_core_mat.emission                   = Color(1.0, 0.0, 0.0)
	_core_mat.emission_energy_multiplier = 6.0
	_core_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mi.material_override            = _core_mat
	add_child(core_mi)

# ── Logic ─────────────────────────────────────────────────────────────────────

func init(pos: Vector3, dir: Vector3, spd: float, dmg: int, slot: int) -> void:
	global_position = pos
	velocity    = dir * spd
	damage      = dmg
	owner_slot  = slot

func _process(delta: float) -> void:
	if homing_target and is_instance_valid(homing_target):
		var to_target := (homing_target.global_position - global_position).normalized()
		velocity = velocity.lerp(to_target * velocity.length(), homing_strength * delta)

	global_position += velocity * delta

	if velocity.length_squared() > 0.01:
		look_at(global_position + velocity, Vector3.UP)

	# Mine: pulse red core + slow spin
	if weapon_type == "mine":
		_mine_spin += delta * 0.8
		rotation_degrees.y = rad_to_deg(_mine_spin)
		if _core_mat:
			var pulse := 0.5 + 0.5 * sin(_mine_spin * 3.0)
			_core_mat.emission_energy_multiplier = 4.0 + pulse * 8.0

	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()

func _spawn_hit_fx(pos: Vector3) -> void:
	var fx := Node3D.new()

	# ── Spark burst — fast hot shards flying out ──────────────────────────────
	var sparks                    := GPUParticles3D.new()
	sparks.amount                  = 28
	sparks.lifetime                = 0.45
	sparks.one_shot                = true
	sparks.explosiveness           = 0.95
	sparks.randomness              = 0.25
	sparks.local_coords            = false

	var smat                       := ParticleProcessMaterial.new()
	smat.emission_shape             = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	smat.emission_sphere_radius     = 0.15
	smat.direction                  = Vector3(0, 0, 0)
	smat.spread                     = 180.0
	smat.initial_velocity_min       = 10.0
	smat.initial_velocity_max       = 26.0
	smat.angular_velocity_min       = -360.0
	smat.angular_velocity_max       = 360.0
	smat.gravity                    = Vector3(0, -4.0, 0)
	smat.scale_min                  = 0.06
	smat.scale_max                  = 0.18
	smat.damping_min                = 8.0
	smat.damping_max                = 20.0

	var sg  := Gradient.new()
	sg.set_color(0, Color(2.0, 1.8, 1.0, 1.0))                              # white-hot core
	sg.add_point(0.25, Color(owner_color.r * 2, owner_color.g * 2, owner_color.b * 2, 1.0))  # bright color
	sg.add_point(0.7,  Color(owner_color.r, owner_color.g, owner_color.b, 0.6))
	sg.add_point(1.0,  Color(owner_color.r * 0.3, owner_color.g * 0.3, owner_color.b * 0.3, 0.0))
	var sgt := GradientTexture1D.new()
	sgt.gradient = sg
	smat.color_ramp = sgt

	var spark_mesh         := SphereMesh.new()
	spark_mesh.radius       = 0.06
	spark_mesh.height       = 0.12
	var spark_draw_mat      := StandardMaterial3D.new()
	spark_draw_mat.albedo_color               = Color.WHITE
	spark_draw_mat.emission_enabled           = true
	spark_draw_mat.emission                   = Color.WHITE
	spark_draw_mat.emission_energy_multiplier = 6.0
	spark_draw_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mesh.surface_set_material(0, spark_draw_mat)
	sparks.draw_pass_1     = spark_mesh
	sparks.process_material = smat
	fx.add_child(sparks)

	# ── Ember drift — slower particles that float and cool ────────────────────
	var embers                    := GPUParticles3D.new()
	embers.amount                  = 14
	embers.lifetime                = 0.9
	embers.one_shot                = true
	embers.explosiveness           = 0.7
	embers.randomness              = 0.5
	embers.local_coords            = false

	var emat                       := ParticleProcessMaterial.new()
	emat.emission_shape             = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	emat.emission_sphere_radius     = 0.3
	emat.direction                  = Vector3(0, 1, 0)
	emat.spread                     = 60.0
	emat.initial_velocity_min       = 2.0
	emat.initial_velocity_max       = 7.0
	emat.gravity                    = Vector3(0, 1.5, 0)   # float upward like heat
	emat.scale_min                  = 0.05
	emat.scale_max                  = 0.14
	emat.damping_min                = 2.0
	emat.damping_max                = 5.0

	var eg  := Gradient.new()
	eg.set_color(0, Color(owner_color.r * 2, owner_color.g * 2, owner_color.b * 2, 1.0))
	eg.add_point(0.5, Color(owner_color.r, owner_color.g * 0.4, 0.0, 0.7))   # cooling ember orange
	eg.add_point(1.0, Color(0.15, 0.05, 0.0, 0.0))                            # dead ash
	var egt := GradientTexture1D.new()
	egt.gradient = eg
	emat.color_ramp = egt

	var ember_mesh         := SphereMesh.new()
	ember_mesh.radius       = 0.05
	ember_mesh.height       = 0.10
	var ember_draw_mat      := StandardMaterial3D.new()
	ember_draw_mat.albedo_color               = Color.WHITE
	ember_draw_mat.emission_enabled           = true
	ember_draw_mat.emission                   = Color.WHITE
	ember_draw_mat.emission_energy_multiplier = 4.0
	ember_draw_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	ember_mesh.surface_set_material(0, ember_draw_mat)
	embers.draw_pass_1     = ember_mesh
	embers.process_material = emat
	fx.add_child(embers)

	# ── Impact flash light ────────────────────────────────────────────────────
	var light             := OmniLight3D.new()
	light.light_color      = Color(1.0, 0.75, 0.35)   # hot white-orange regardless of color
	light.light_energy     = 14.0
	light.omni_range       = 14.0
	light.shadow_enabled   = false
	fx.add_child(light)

	get_parent().add_child(fx)
	fx.global_position = pos

	sparks.restart()
	embers.restart()

	var t := fx.create_tween()
	t.tween_property(light, "light_energy", 0.0, 0.18)
	t.tween_callback(fx.queue_free).set_delay(1.0)

func _on_area_entered(area: Area3D) -> void:
	# Asteroid hit
	if area.get_meta("asteroid", false):
		_spawn_hit_fx(global_position)
		queue_free()
		return

	# Ship hit
	if not area.has_meta("ship"):
		return
	var ship = area.get_meta("ship")
	if not is_instance_valid(ship):
		return
	if ship.slot == owner_slot:
		return
	if owner_team >= 0 and ship.team == owner_team:
		return
	_spawn_hit_fx(global_position)
	ship.take_damage(damage)
	queue_free()
