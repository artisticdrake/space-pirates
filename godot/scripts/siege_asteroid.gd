extends Node3D

var ast_vel : Vector3 = Vector3.ZERO

# 0.78 = retains 78% speed per second → smooth 6-8 second coast to a stop
const DRAG_PER_SEC : float = 0.78

func _process(delta: float) -> void:
	if ast_vel.length_squared() < 0.002:
		set_process(false)   # sleep until next push
		return
	global_position += ast_vel * delta
	ast_vel          *= pow(DRAG_PER_SEC, delta)
