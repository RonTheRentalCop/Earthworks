extends Node
## Multiplayer for up to 4 players, host-authoritative.
##
## Security: Godot's built-in ENet transport with DTLS encryption (a fresh certificate is
## generated every time you host) and a room password checked by HMAC challenge-response
## in both directions, so the password itself never crosses the network and a fake host
## can't pass itself off as yours. Clients can't message each other (no relay), and
## everything they send is type-checked and rate-limited. For play over the internet, run
## Tailscale (or another WireGuard VPN) on each PC and join using the host's Tailscale
## address — no port forwarding, and only your own devices can reach the game.
##
## The host runs the whole simulation. Joining players build the same world from the
## same seed, then receive a snapshot (changed terrain, machines, trees, logs, rubble,
## money, jobs) and a stream of updates: their machines are puppets that follow the host,
## and their controls are sent to the host to drive the machine they're in.

signal status_changed(text: String)
signal players_changed

const VERSION := "earthworks-net-2"  # bump whenever the messages change: mismatched games refuse politely
const DEFAULT_PORT := 24680
const MAX_PLAYERS := 4
const STATE_INTERVAL := 0.05  # 20 updates a second
const INPUT_INTERVAL := 1.0 / 30.0
const TERRAIN_INTERVAL := 0.25
const JOBS_INTERVAL := 0.5
const BODIES_PER_PACKET := 32  # 32 x 32 bytes: fits one network packet
const MAX_REQUESTS_PER_SECOND := 20
const INPUT_ACTIONS := ["drive_forward", "drive_back", "turn_left", "turn_right", "swing_left", "swing_right",
	"boom_up", "boom_down", "stick_out", "stick_in", "bucket_curl", "bucket_dump", "handbrake"]
const REQUESTS := ["enter", "exit", "utility", "ramps", "reset", "buy", "deliver", "take_job", "abandon_job", "return", "supply"]
const Player = preload("res://scripts/player.gd")
const COLORS: Array[Color] = [Color(1.0, 0.76, 0.1), Color(0.35, 0.75, 1.0), Color(0.55, 0.95, 0.45), Color(1.0, 0.45, 0.6)]

## Set before reloading the scene to join a game (survives the reload).
static var pending := {}

var main: Node3D
var role := "solo"  # solo, host, client
var my_name := "Player"
## peer id -> {name, color, driving (vehicle id, -1 on foot)}
var players := {}

var _password := ""
var _crypto := Crypto.new()
var _challenges := {}  # peer -> nonce we sent
var _client_nonce := PackedByteArray()
var _joining_names := {}  # peer -> name, between auth and connection
var _state_timer := 0.0
var _input_timer := 0.0
var _terrain_timer := 0.0
var _jobs_timer := 0.0
var _body_cursor := 0
var _body_sent := {}  # body id -> last sent transform origin + quaternion (host)
var _body_targets := {}  # body id -> Transform3D (joining players)
var _requests := {}  # peer -> [window start msec, count]
var _puppets := {}  # peer -> Player puppet
var _loaded := {}  # peers that have loaded the snapshot and take the live streams
## Changed ground still to send each joining player (chunk indices), a few per tick after
## the snapshot: a well-worked world is many megabytes, too much for one message.
var _terrain_out := {}
const GROUND_BYTES_PER_BATCH := 12000
const GROUND_BATCHES_IN_FLIGHT := 2
var _ground_unacked := {}  # peer -> batches sent but not yet confirmed
var _remote_inputs := {}  # peer -> {axes, winch}


func _ready() -> void:
	main = get_parent()
	var sm := _scene_multiplayer()
	sm.peer_connected.connect(_on_peer_connected)
	sm.peer_disconnected.connect(_on_peer_disconnected)
	sm.connected_to_server.connect(_on_connected)
	sm.connection_failed.connect(_on_connection_failed)
	sm.server_disconnected.connect(_on_server_disconnected)
	sm.peer_authenticating.connect(_on_peer_authenticating)
	sm.peer_authentication_failed.connect(_on_auth_failed)


func _exit_tree() -> void:
	var sm := _scene_multiplayer()
	sm.auth_callback = Callable()
	if role != "solo":
		sm.multiplayer_peer.close()
		sm.multiplayer_peer = OfflineMultiplayerPeer.new()


func is_host() -> bool:
	return role == "host"


func is_client() -> bool:
	return role == "client"


func is_online() -> bool:
	return role != "solo"


func my_id() -> int:
	return multiplayer.get_unique_id() if is_online() else 1


func _scene_multiplayer() -> SceneMultiplayer:
	return multiplayer as SceneMultiplayer


# --- Hosting and joining ------------------------------------------------------------------

## Opens the current world to up to 3 other players. Returns "" or an error message.
func host(port: int, password: String, player_name: String) -> String:
	if role != "solo":
		return "Already in a session"
	if password.length() < 4:
		return "Use a password of at least 4 characters"
	var peer := ENetMultiplayerPeer.new()
	# One spare connection, so a 5th player gets a "game is full" message instead of silence.
	if peer.create_server(port, MAX_PLAYERS) != OK:
		return "Couldn't open port %d (is another game using it?)" % port
	# A fresh key and self-signed certificate per session; all traffic is DTLS-encrypted.
	var key := _crypto.generate_rsa(2048)
	var cert := _crypto.generate_self_signed_certificate(key, "CN=earthworks,O=Earthworks,C=US")
	if peer.host.dtls_server_setup(TLSOptions.server(key, cert)) != OK:
		peer.close()
		return "Couldn't start encryption"
	# Pace big sends (the join snapshot) so a player's machine can keep up.
	peer.host.bandwidth_limit(0, 400000)
	_password = password
	my_name = _clean_name(player_name)
	_setup_auth()
	multiplayer.multiplayer_peer = peer
	role = "host"
	players = {1: {"name": my_name, "color": 0, "driving": -1}}
	main.terrain.net_record = true
	status_changed.emit("Hosting on port %d" % port)
	players_changed.emit()
	return ""


## Connects to a host (called on the freshly built world after the scene reload).
func join(address: String, port: int, password: String, player_name: String) -> String:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, port) != OK:
		return "Couldn't connect to %s:%d" % [address, port]
	if peer.host.dtls_client_setup("earthworks", TLSOptions.client_unsafe()) != OK:
		peer.close()
		return "Couldn't start encryption"
	_password = password
	my_name = _clean_name(player_name)
	_setup_auth()
	multiplayer.multiplayer_peer = peer
	role = "client"
	status_changed.emit("Connecting to %s:%d…" % [address, port])
	return ""


## Ends the session: the host stops hosting (its world carries on solo); a joining
## player goes back to their own solo world.
func leave() -> void:
	if role == "client":
		pending = {"toast": "Left the game"}
		get_tree().call_deferred("reload_current_scene")
	elif role == "host":
		for peer in players.keys():
			if peer != 1:
				main.remote_exit(peer)
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
		role = "solo"
		players = {}
		for p in _puppets.values():
			p.queue_free()
		_puppets.clear()
		main.terrain.net_record = false
		status_changed.emit("Stopped hosting")
		players_changed.emit()


func _setup_auth() -> void:
	var sm := _scene_multiplayer()
	sm.auth_callback = _on_auth
	sm.auth_timeout = 10.0
	sm.server_relay = false  # clients can only talk to the host
	sm.allow_object_decoding = false


func _clean_name(text: String) -> String:
	var out := ""
	for c in text.strip_edges():
		if c.is_valid_identifier() or c.is_valid_int() or c in " -_.":
			out += c
	out = out.substr(0, 16).strip_edges()
	return out if out != "" else "Player"


func _mac(nonce: PackedByteArray, label: String) -> PackedByteArray:
	return _crypto.hmac_digest(HashingContext.HASH_SHA256, _password.to_utf8_buffer(), nonce + label.to_utf8_buffer())


func _same(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff := 0
	for i in a.size():
		diff |= a[i] ^ b[i]
	return diff == 0


## Host: a client connected at the transport level; challenge it.
func _on_peer_authenticating(id: int) -> void:
	if role != "host":
		return
	var nonce := _crypto.generate_random_bytes(32)
	_challenges[id] = nonce
	_scene_multiplayer().send_auth(id, var_to_bytes({"v": VERSION, "nonce": nonce, "full": players.size() >= MAX_PLAYERS}))


## Both sides: the password handshake. Host -> client: a nonce. Client -> host: proof it
## knows the password, plus its own nonce. Host -> client: proof the host knows it too.
func _on_auth(id: int, data: PackedByteArray) -> void:
	var sm := _scene_multiplayer()
	var msg = bytes_to_var(data)
	if not msg is Dictionary:
		sm.disconnect_peer(id)
		return
	if role == "client":
		if msg.has("error"):
			_fail(String(msg.error))
		elif msg.has("nonce"):
			if String(msg.get("v", "")) != VERSION:
				_fail("The host is running a different version of Earthworks")
				return
			if msg.get("full", false):
				_fail("That game is full (%d players)" % MAX_PLAYERS)
				return
			_client_nonce = _crypto.generate_random_bytes(32)
			sm.send_auth(1, var_to_bytes({"v": VERSION, "mac": _mac(msg.nonce, "client"), "nonce": _client_nonce, "name": my_name}))
		elif msg.has("proof"):
			if msg.proof is PackedByteArray and _same(msg.proof, _mac(_client_nonce, "host")):
				sm.complete_auth(1)
			else:
				_fail("The host couldn't prove it knows the password")
		return
	# Host side.
	if not _challenges.has(id) or not msg.get("mac") is PackedByteArray or not msg.get("nonce") is PackedByteArray:
		sm.disconnect_peer(id)
		return
	var reason := ""
	if String(msg.get("v", "")) != VERSION:
		reason = "Different game version"
	elif players.size() >= MAX_PLAYERS:
		reason = "That game is full (%d players)" % MAX_PLAYERS
	elif not _same(msg.mac, _mac(_challenges[id], "client")):
		reason = "Wrong password"
	_challenges.erase(id)
	if reason != "":
		sm.send_auth(id, var_to_bytes({"error": reason}))
		get_tree().create_timer(0.5).timeout.connect(func() -> void: sm.disconnect_peer(id))
		return
	_joining_names[id] = _clean_name(String(msg.get("name", "Player")))
	sm.send_auth(id, var_to_bytes({"proof": _mac(msg.nonce, "host")}))
	sm.complete_auth(id)


func _on_auth_failed(_id: int) -> void:
	if role == "client":
		_fail("Couldn't join (wrong password or the host didn't answer)")


func _fail(reason: String) -> void:
	if pending.has("toast"):
		return  # the first reason is the real one (a disconnect usually follows)
	pending = {"toast": reason}
	get_tree().call_deferred("reload_current_scene")


func _on_peer_connected(id: int) -> void:
	if role != "host":
		return
	var used := []
	for p in players.values():
		used.append(int(p.color))
	var color := 0
	while color in used:
		color += 1
	players[id] = {"name": _joining_names.get(id, "Player"), "color": color, "driving": -1}
	_joining_names.erase(id)
	_send_snapshot(id)
	_broadcast_players()
	main.hud.toast("%s joined the game" % players[id].name, COLORS[color])
	rpc("_rx_toast", "%s joined the game" % players[id].name, COLORS[color])


func _on_peer_disconnected(id: int) -> void:
	if role != "host" or not players.has(id):
		return
	var who: String = players[id].name
	main.remote_exit(id)
	players.erase(id)
	_loaded.erase(id)
	_terrain_out.erase(id)
	_ground_unacked.erase(id)
	_remote_inputs.erase(id)
	if _puppets.has(id):
		_puppets[id].queue_free()
		_puppets.erase(id)
	_broadcast_players()
	main.hud.toast("%s left the game" % who)
	rpc("_rx_toast", "%s left the game" % who, Color.WHITE)


func _on_connected() -> void:
	status_changed.emit("Connected — loading the world…")


func _on_connection_failed() -> void:
	_fail("Couldn't reach the host (check the address, the port and the host's firewall)")


func _on_server_disconnected() -> void:
	_fail("The host ended the game")


# --- Per frame ----------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if role == "host":
		_host_tick(delta)
	elif role == "client" and multiplayer.get_unique_id() != 1:
		_client_tick(delta)


func _host_tick(delta: float) -> void:
	for peer in _remote_inputs:
		main.remote_input(peer, _remote_inputs[peer].axes, _remote_inputs[peer].winch)
	_send_ground()
	if _loaded.is_empty():
		return
	_state_timer -= delta
	if _state_timer <= 0.0:
		_state_timer = STATE_INTERVAL
		var people := [[1, main.player.net_state(), players[1].driving]]
		for peer in players:
			if peer != 1 and _puppets.has(peer):
				people.append([peer, _puppets[peer].net_state(), players[peer].driving])
		# A few machines per packet, so each stays under the network's packet size.
		var vehicles := []
		for v in main.machines + main.trailers:
			vehicles.append([int(v.get_meta("net_id")), v.global_transform, v.net_state()])
			if vehicles.size() == 3:
				_stream("_rx_state", [vehicles, people])
				vehicles = []
				people = []
		if not vehicles.is_empty() or not people.is_empty():
			_stream("_rx_state", [vehicles, people])
		var bodies := _changed_bodies()
		if not bodies.is_empty():
			_stream("_rx_bodies", [bodies])
		for peer in players:
			var vid: int = players[peer].driving
			if peer != 1 and vid >= 0 and peer in multiplayer.get_peers():
				var v: Node3D = main.vehicle_by_id(vid)
				if v:
					rpc_id(peer, "_rx_hud", v.hud_info())
	_terrain_timer -= delta
	if _terrain_timer <= 0.0:
		_terrain_timer = TERRAIN_INTERVAL
		var t = main.terrain
		if not t.net_dirty.is_empty():
			var chunks := []
			for index in t.net_dirty:
				chunks.append(t.net_pack_delta(index))
			t.net_dirty.clear()
			var raw := var_to_bytes(chunks)
			rpc("_rx_terrain", raw.compress(FileAccess.COMPRESSION_ZSTD), raw.size())
	_jobs_timer -= delta
	if _jobs_timer <= 0.0 and not main.jobs.active.is_empty():
		_jobs_timer = JOBS_INTERVAL
		send_jobs()


## Streams the changed ground to players who've just joined, packed as it goes (so a
## chunk changed meanwhile goes out as it is now). Paced by what the player has actually
## received: bursts bigger than their network buffer get dropped, and the resends would
## hold up every other message to them.
func _send_ground() -> void:
	for peer in _terrain_out.keys():
		var queue: Array = _terrain_out[peer]
		if not peer in multiplayer.get_peers() or queue.is_empty():
			_terrain_out.erase(peer)
			continue
		if int(_ground_unacked.get(peer, 0)) >= GROUND_BATCHES_IN_FLIGHT:
			continue  # wait for the player to confirm what they've got
		var chunks := []
		var bytes := 0
		while not queue.is_empty() and bytes < GROUND_BYTES_PER_BATCH:
			var index := int(queue.pop_back())
			var waiting = main.terrain._pending_chunks.get(index)
			var chunk: Array = waiting if waiting != null else main.terrain.net_pack_delta(index)
			chunks.append(chunk)
			bytes += var_to_bytes(chunk).size() / 6  # roughly what it compresses to
		var raw := var_to_bytes(chunks)
		_ground_unacked[peer] = int(_ground_unacked.get(peer, 0)) + 1
		rpc_id(peer, "_rx_ground", raw.compress(FileAccess.COMPRESSION_ZSTD), raw.size())


## Live updates go only to players who have finished loading.
func _stream(method: String, args: Array) -> void:
	for peer in _loaded:
		if peer in multiplayer.get_peers():
			callv("rpc_id", [peer, method] + args)


## Rubble, logs and stumps that moved since they were last sent (a few dozen per update,
## taking turns so a whole collapsing building gets through).
func _changed_bodies() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var ids: Array = main.bodies.keys()
	var count := ids.size()
	var sent := 0
	for step in count:
		if sent >= BODIES_PER_PACKET:
			break
		var id: int = ids[(_body_cursor + step) % count]
		var body: Node3D = main.bodies[id]
		if not is_instance_valid(body):
			main.bodies.erase(id)
			continue
		var xf := body.global_transform
		var q := xf.basis.get_rotation_quaternion()
		var last = _body_sent.get(id)
		if last != null and (last[0] as Vector3).distance_to(xf.origin) < 0.01 and (last[1] as Quaternion).angle_to(q) < 0.01:
			continue
		_body_sent[id] = [xf.origin, q]
		out.append_array([id, xf.origin.x, xf.origin.y, xf.origin.z, q.x, q.y, q.z, q.w])
		sent += 1
	_body_cursor = (_body_cursor + BODIES_PER_PACKET) % maxi(count, 1)
	return out


func _client_tick(delta: float) -> void:
	# Smooth rubble and logs towards where the host has them.
	var t := 1.0 - exp(-14.0 * delta)
	for id in _body_targets.keys():
		var body: Node3D = main.bodies.get(id)
		if not is_instance_valid(body):
			_body_targets.erase(id)
			continue
		body.global_transform = body.global_transform.interpolate_with(_body_targets[id], t)
	if not 1 in multiplayer.get_peers():
		return  # still shaking hands
	_input_timer -= delta
	if _input_timer <= 0.0:
		_input_timer = INPUT_INTERVAL
		if main.driving():
			var axes := PackedFloat32Array()
			for action in INPUT_ACTIONS:
				var value := Input.get_action_strength(action) + float(main.mouse.output.get(action, 0.0))
				axes.append(clampf(value, 0.0, 1.0) if not main.menu.is_open else 0.0)
			rpc_id(1, "_tx_input", axes, Input.is_action_pressed("winch") and not main.menu.is_open)
		rpc_id(1, "_tx_player", main.player.net_state())


# --- Host -> players ----------------------------------------------------------------------

func send_jobs() -> void:
	if role == "host" and players.size() > 1:
		rpc("_rx_jobs", main.jobs.net_state())


func send_career(change: int, reason: String) -> void:
	if role == "host" and players.size() > 1:
		rpc("_rx_career", main.career.money, main.career.owned.keys(), change, reason)


func send_spawn(node: Node3D) -> void:
	if role == "host" and players.size() > 1:
		rpc("_rx_spawn", int(node.get_meta("net_id")), _kind_of(node), node.global_transform, node.get("broken") == true)


func send_despawn(id: int) -> void:
	if role == "host" and players.size() > 1:
		rpc("_rx_despawn", id)


func send_tree(tid: int, event: String, body_id: int) -> void:
	if role == "host" and players.size() > 1:
		rpc("_rx_tree", tid, event, body_id)


func send_shred(shredder: int, body_id: int) -> void:
	if role == "host" and players.size() > 1:
		rpc("_rx_shred", shredder, body_id)


func send_mat(id: int, xform: Transform3D) -> void:
	if role == "host" and players.size() > 1:
		rpc("_rx_mat", id, xform)


func send_ramps(trailer_id: int, down: bool) -> void:
	if role == "host" and players.size() > 1:
		rpc("_rx_ramps", trailer_id, down)


func toast(peer: int, text: String, color := Color.WHITE) -> void:
	if peer == 1 or peer == 0:
		main.hud.toast(text, color)
	if role == "host" and peer != 1 and peer in multiplayer.get_peers():
		rpc_id(peer, "_rx_toast", text, color)


func toast_all(text: String, color := Color.WHITE) -> void:
	main.hud.toast(text, color)
	if role == "host" and players.size() > 1:
		rpc("_rx_toast", text, color)


## The host's answer to "can I get in?": tells everyone who's driving what.
func set_driver(peer: int, vehicle_id: int) -> void:
	if players.has(peer):
		players[peer].driving = vehicle_id
	if role == "host":
		if peer != 1 and peer in multiplayer.get_peers():
			if vehicle_id >= 0:
				rpc_id(peer, "_rx_entered", vehicle_id)
			else:
				rpc_id(peer, "_rx_exited")
		_broadcast_players()


func driver_of(vehicle_id: int) -> int:
	for peer in players:
		if int(players[peer].driving) == vehicle_id:
			return peer
	return 0


func _broadcast_players() -> void:
	players_changed.emit()
	if role == "host":
		rpc("_rx_players", players)


func _kind_of(node: Node3D) -> String:
	return String(node.get_meta("kind", "dump"))


func _send_snapshot(peer: int) -> void:
	var vehicles := []
	for v in main.machines + main.trailers:
		vehicles.append([int(v.get_meta("net_id")), _kind_of(v), v.global_transform, v.get("broken") == true, v.net_state()])
	var trees := []
	var forests = main.forests
	for tid in forests.state.size():
		if forests.state[tid] > 0:
			var known: Array = main.tree_bodies.get(tid, [-1, -1])
			trees.append([tid, forests.state[tid], known[0], known[1]])
	var debris := []
	for k in main.debris.size():
		var b: Node3D = main.debris[k]
		if is_instance_valid(b):
			debris.append([k, b.global_transform])
	var loose := []
	var mats := []
	for id in main.bodies:
		if id >= main.FIRST_DYNAMIC_ID and is_instance_valid(main.bodies[id]):
			if main.bodies[id].get_meta("label", "") == "ground mat":
				mats.append([id, main.bodies[id].global_transform])
			else:
				loose.append([id, main.bodies[id].global_transform])
	var chunks := []  # (the changed ground follows on its own, see _send_ground)
	var shredded := []
	for s in main.shredders:
		shredded.append(s.total_shredded)
	var snapshot := {
		"career": [main.career.money, main.career.owned.keys()], "jobs": main.jobs.net_state(),
		"vehicles": vehicles, "trees": trees, "debris": debris, "loose": loose, "terrain": chunks,
		"shredded": shredded, "players": players, "next_id": main.next_net_id, "mats": mats,
	}
	var raw := var_to_bytes(snapshot)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	print_verbose("snapshot for %d: %d bytes (%d raw)" % [peer, packed.size(), raw.size()])
	rpc_id(peer, "_rx_snapshot", packed, raw.size())
	# Everything in the snapshot counts as sent.
	for id in main.bodies:
		var b: Node3D = main.bodies[id]
		if is_instance_valid(b):
			_body_sent[id] = [b.global_position, b.global_basis.get_rotation_quaternion()]


# --- Players -> host ----------------------------------------------------------------------

func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return id if role == "host" and players.has(id) and id != 1 else 0


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _tx_input(axes: PackedFloat32Array, winch: bool) -> void:
	var peer := _sender()
	if peer == 0 or axes.size() != INPUT_ACTIONS.size():
		return
	var clean := {}
	for k in INPUT_ACTIONS.size():
		var value := axes[k]
		clean[INPUT_ACTIONS[k]] = clampf(value, 0.0, 1.0) if is_finite(value) else 0.0
	_remote_inputs[peer] = {"axes": clean, "winch": winch}


@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func _tx_player(state: Array) -> void:
	var peer := _sender()
	if peer == 0 or state.size() != 3 or not state[0] is Vector3 or not state[1] is float or not state[2] is float:
		return
	if not (state[0] as Vector3).is_finite():
		return
	_puppet_for(peer).apply_net_state(state)


@rpc("any_peer", "call_remote", "reliable", 3)
func _tx_ground_ack() -> void:
	var peer := _sender()
	if peer != 0:
		_ground_unacked[peer] = maxi(int(_ground_unacked.get(peer, 0)) - 1, 0)


@rpc("any_peer", "call_remote", "reliable")
func _tx_loaded() -> void:
	var peer := _sender()
	if peer != 0:
		_loaded[peer] = true
		# Now the changed ground: every chunk since the world was built (the host's save too).
		var changed: Dictionary = main.terrain.edited.duplicate()
		changed.merge(main.terrain.net_changed)
		changed.merge(main.terrain._pending_chunks)  # saved changes to ground not visited yet
		_terrain_out[peer] = changed.keys()


@rpc("any_peer", "call_remote", "reliable")
func _tx_request(action: String, arg: Variant) -> void:
	var peer := _sender()
	if peer == 0 or not action in REQUESTS:
		return
	# Rate limit: a flood of requests is dropped.
	var now := Time.get_ticks_msec()
	var window: Array = _requests.get(peer, [now, 0])
	if now - int(window[0]) > 1000:
		window = [now, 0]
	window[1] = int(window[1]) + 1
	_requests[peer] = window
	if int(window[1]) > MAX_REQUESTS_PER_SECOND:
		return
	if action in ["enter", "ramps", "reset", "take_job", "return"] and not arg is int:
		return
	if action in ["buy", "deliver", "supply"] and not arg is String:
		return
	main.remote_request(peer, action, arg)


## Joining player: ask the host to do something.
func request(action: String, arg: Variant = null) -> void:
	if role == "client":
		rpc_id(1, "_tx_request", action, arg)


# --- Host -> players: handlers (run on joining players' machines) ----------------------

func _from_host() -> bool:
	return role == "client" and multiplayer.get_remote_sender_id() == 1


@rpc("authority", "call_remote", "reliable")
func _rx_snapshot(data: PackedByteArray, size: int) -> void:
	if not _from_host():
		return
	var snap: Dictionary = bytes_to_var(data.decompress(size, FileAccess.COMPRESSION_ZSTD))
	main.apply_snapshot(snap)
	rpc_id(1, "_tx_loaded")
	players = snap.players
	players_changed.emit()
	status_changed.emit("Connected")


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _rx_state(vehicles: Array, people: Array) -> void:
	if not _from_host():
		return
	for entry in vehicles:
		var v: Node3D = main.vehicle_by_id(int(entry[0]))
		if v:
			v.apply_net_state(entry[1], entry[2])
	var me := multiplayer.get_unique_id()
	for entry in people:
		var peer: int = entry[0]
		if peer == me or not players.has(peer):
			continue
		var puppet := _puppet_for(peer)
		puppet.apply_net_state(entry[1])
		_seat_puppet(puppet, int(entry[2]))


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rx_bodies(data: PackedFloat32Array) -> void:
	if not _from_host():
		return
	for i in range(0, data.size() - 7, 8):
		var id := int(data[i])
		var body: Node3D = main.bodies.get(id)
		if body:
			var q := Quaternion(data[i + 4], data[i + 5], data[i + 6], data[i + 7]).normalized()
			_body_targets[id] = Transform3D(Basis(q), Vector3(data[i + 1], data[i + 2], data[i + 3]))


# The changed ground after joining, batch by batch; each is confirmed so the host sends
# the next only when this one's in (on its own channel, so it never holds up the rest).
@rpc("authority", "call_remote", "reliable", 3)
func _rx_ground(data: PackedByteArray, size: int) -> void:
	if not _from_host():
		return
	for chunk in bytes_to_var(data.decompress(size, FileAccess.COMPRESSION_ZSTD)):
		main.terrain.net_apply_chunk(chunk)
	rpc_id(1, "_tx_ground_ack")


# Its own channel: ground streaming never holds up the other messages behind it.
@rpc("authority", "call_remote", "reliable", 3)
func _rx_terrain(data: PackedByteArray, size: int) -> void:
	if not _from_host():
		return
	for chunk in bytes_to_var(data.decompress(size, FileAccess.COMPRESSION_ZSTD)):
		main.terrain.net_apply_chunk(chunk)


@rpc("authority", "call_remote", "reliable")
func _rx_spawn(id: int, kind: String, xform: Transform3D, broken: bool) -> void:
	if _from_host():
		main.net_spawn(id, kind, xform, broken)


@rpc("authority", "call_remote", "reliable")
func _rx_despawn(id: int) -> void:
	if _from_host():
		var v: Node3D = main.vehicle_by_id(id)
		if v:
			main.despawn(v)


@rpc("authority", "call_remote", "reliable")
func _rx_tree(tid: int, event: String, body_id: int) -> void:
	if _from_host():
		main.net_tree_event(tid, event, body_id)


@rpc("authority", "call_remote", "reliable")
func _rx_shred(shredder: int, body_id: int) -> void:
	if _from_host() and shredder < main.shredders.size():
		var body: RigidBody3D = main.bodies.get(body_id)
		if body:
			_body_targets.erase(body_id)
			main.shredders[shredder].take(body)


@rpc("authority", "call_remote", "reliable")
func _rx_mat(id: int, xform: Transform3D) -> void:
	if _from_host() and not main.bodies.has(id):
		main._register_body(main.make_mat(xform), id)


@rpc("authority", "call_remote", "reliable")
func _rx_ramps(trailer_id: int, down: bool) -> void:
	if _from_host():
		var t: Node3D = main.vehicle_by_id(trailer_id)
		if t:
			t.ramps_down = down


@rpc("authority", "call_remote", "reliable")
func _rx_career(money: int, owned: Array, change: int, reason: String) -> void:
	if _from_host():
		main.career.set_remote(money, owned, change, reason)


@rpc("authority", "call_remote", "reliable")
func _rx_jobs(state: Array) -> void:
	if _from_host():
		main.jobs.apply_net_state(state)


@rpc("authority", "call_remote", "reliable")
func _rx_toast(text: String, color: Color) -> void:
	if _from_host():
		main.hud.toast(text, color)


@rpc("authority", "call_remote", "reliable")
func _rx_players(list: Dictionary) -> void:
	if not _from_host():
		return
	players = list
	for peer in _puppets.keys():
		if not players.has(peer):
			_puppets[peer].queue_free()
			_puppets.erase(peer)
	players_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rx_entered(vehicle_id: int) -> void:
	if _from_host():
		var v: Node3D = main.vehicle_by_id(vehicle_id)
		if v:
			main.client_enter(v)


@rpc("authority", "call_remote", "reliable")
func _rx_exited() -> void:
	if _from_host():
		main.client_exit()


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rx_hud(info: Dictionary) -> void:
	if _from_host():
		main.remote_hud = info


# --- Other players' workers ---------------------------------------------------------------

func _puppet_for(peer: int) -> Node3D:
	if not _puppets.has(peer):
		var p := Player.new()
		p.camera = main.camera
		main.add_child(p)
		var info: Dictionary = players.get(peer, {"name": "Player", "color": 1})
		p.make_puppet(String(info.name), COLORS[int(info.color) % COLORS.size()])
		_puppets[peer] = p
	return _puppets[peer]


## Seats another player's worker in the machine they're driving (or stands them up).
func _seat_puppet(puppet: Node3D, vehicle_id: int) -> void:
	var seated: int = puppet.get_meta("seated", -1)
	if seated == vehicle_id:
		return
	puppet.set_meta("seated", vehicle_id)
	if vehicle_id >= 0:
		var v: Node3D = main.vehicle_by_id(vehicle_id)
		if v:
			puppet.set_active(false)
			puppet.sit(v.seat)
	else:
		puppet.stand()
		puppet.set_active(true)


## Host: keep remote players' workers seated where the host says they are.
func _process(_delta: float) -> void:
	if role != "host":
		return
	for peer in _puppets:
		if players.has(peer):
			_seat_puppet(_puppets[peer], int(players[peer].driving))


func player_color(peer: int) -> Color:
	return COLORS[int(players[peer].color) % COLORS.size()] if players.has(peer) else Color.WHITE
