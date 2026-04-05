extends Node
class_name NetworkBridge

signal pilot_joined(slot: int, color: String)
signal pilot_left(slot: int)
signal ship_selected(slot: int, ship_id: String)
signal pilot_ready(slot: int)
signal input_received(slot: int, data: Dictionary)
signal mode_selected(mode: String, chapter: int)

const WS_URL := "ws://localhost:4000"
const RECONNECT_INTERVAL := 3.0

var socket := WebSocketPeer.new()
var connected := false
var reconnect_timer := 0.0

func _ready() -> void:
	_connect_socket()

func _connect_socket() -> void:
	print("NetworkBridge: connecting to ", WS_URL)
	socket = WebSocketPeer.new()
	socket.connect_to_url(WS_URL)

func _process(delta: float) -> void:
	socket.poll()
	var s := socket.get_ready_state()

	if s == WebSocketPeer.STATE_OPEN:
		if not connected:
			connected = true
			reconnect_timer = 0.0
			print("NetworkBridge: connected")
		_drain_packets()

	elif s == WebSocketPeer.STATE_CLOSED:
		if connected:
			connected = false
			print("NetworkBridge: lost connection — retrying in %.0fs" % RECONNECT_INTERVAL)
		reconnect_timer += delta
		if reconnect_timer >= RECONNECT_INTERVAL:
			reconnect_timer = 0.0
			_connect_socket()

func _drain_packets() -> void:
	while socket.get_available_packet_count() > 0:
		var raw := socket.get_packet()
		_handle(raw.get_string_from_utf8())

func _handle(text: String) -> void:
	var msg = JSON.parse_string(text)
	if msg == null:
		push_warning("NetworkBridge: bad JSON: " + text)
		return
	match msg.get("type", ""):
		"pilot_joined":
			pilot_joined.emit(int(msg.slot), str(msg.color))
		"pilot_left":
			pilot_left.emit(int(msg.slot))
		"ship_selected":
			ship_selected.emit(int(msg.slot), str(msg.shipId))
		"pilot_ready":
			pilot_ready.emit(int(msg.slot))
		"input":
			input_received.emit(int(msg.slot), {
				"rotate": float(msg.get("rotate", 0.0)),
				"thrust":  float(msg.get("thrust",  0.0)),
				"firing":  bool(msg.get("firing",  false)),
				"burst":   bool(msg.get("burst",   false)),
			})
		"lobby_mode_selected":
			mode_selected.emit(str(msg.get("mode", "")), int(msg.get("chapter", -1)))

func send(obj: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(obj))
