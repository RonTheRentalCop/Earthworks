extends SceneTree
## Two-process multiplayer check on this machine. Run the host, then a client:
##   godot --headless --path . -s tools/net_check.gd -- --role=host
##   godot --headless --path . -s tools/net_check.gd -- --role=client
##   godot --headless --path . -s tools/net_check.gd -- --role=badclient   (wrong password)
## The host waits for a player, then delivers a pickup, digs a hole and fells a tree; the
## client checks it sees all that, then drives the host's dump truck by remote control.

const Net = preload("res://scripts/net.gd")
const PASSWORD := "dig-deep-42"

var role := "host"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			role = arg.substr(7)
	if role == "host":
		await _host()
	else:
		await _client(role == "badclient")
	quit()


func _main() -> Node:
	return root.get_node_or_null("Main")


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _host() -> void:
	var main = load("res://main.tscn").instantiate()
	main.name = "Main"
	root.add_child(main)
	await _frames(10)
	main._on_host_requested(Net.DEFAULT_PORT, PASSWORD, "HostBot")
	print("[host] hosting: ", main.net.is_host())
	var waited := 0
	if "--wait" in OS.get_cmdline_user_args():
		await _frames(60 * 45)
		print("[host] players at the end: ", main.net.players.size())
		return
	while main.net.players.size() < 2 and waited < 60 * 40:
		await _frames(1)
		waited += 1
	print("[host] players: ", main.net.players.size())
	if main.net.players.size() < 2:
		return
	await _frames(120)
	main.spawn_vehicle("pickup")
	main.terrain.dig(Vector3(-60, main.terrain.get_height(-60, 0) - 1.2, 0), 1.5, 6.0)
	main.forests.apply_event(0, "fell", main)
	print("[host] delivered a pickup, dug at (-60, 0), felled tree 0")
	var truck = main.truck
	var start: Vector3 = truck.global_position
	var driven := false
	for i in 60 * 25:
		await _frames(1)
		if main.net.driver_of(int(truck.get_meta("net_id"))) > 1:
			driven = true
		if main.net.players.size() < 2:
			break
	print("[host] truck was driven by the client: %s, moved %.1f m" % [driven, truck.global_position.distance_to(start)])


func _client(bad: bool) -> void:
	Net.pending = {"mode": "join", "address": "127.0.0.1", "port": Net.DEFAULT_PORT,
		"password": "wrong-pass" if bad else PASSWORD, "name": "BadBot" if bad else "Bot%d" % (randi() % 1000)}
	var main = load("res://main.tscn").instantiate()
	main.name = "Main"
	root.add_child(main)
	var waited := 0
	while main.machines.is_empty() and waited < 60 * 20:
		await _frames(1)
		waited += 1
		if _main() != main:
			break
	if role == "idleclient":
		await _frames(60 * 6)
		print("[idleclient %s] got the world: %s  players %d  message '%s'" % [main.net.my_name, main.machines.size() > 0, main.net.players.size(), Net.pending.get("toast", "")])
		await _frames(60 * 25)
		return
	if bad:
		await _frames(120)
		print("[badclient] got the world: %s   message: '%s'" % [main.machines.size() > 0, Net.pending.get("toast", "")])
		return
	print("[client] joined: role %s, %d machines, %d trailers, players %d" % [main.net.role, main.machines.size(), main.trailers.size(), main.net.players.size()])
	var worst := 0
	for i in 240:
		var t0 := Time.get_ticks_usec()
		await process_frame
		worst = maxi(worst, Time.get_ticks_usec() - t0)
	print("[client] worst frame in the first 4 s after joining: %d ms" % (worst / 1000))
	var before: int = main.machines.size()
	var dug_before: float = main.terrain.original_height(-60, 0) - main.terrain.get_height(-60, 0)
	await _frames(60 * 5)
	var dug: float = main.terrain.original_height(-60, 0) - main.terrain.get_height(-60, 0)
	print("[client] after host actions: machines %d (was %d), hole %.2f m deep (was %.2f), tree 0 felled %s, logs %d" % [
		main.machines.size(), before, dug, dug_before, main.forests.state[0] == 1, main.bodies.size() - main.debris.size()])
	# Climb into the host's dump truck and drive it.
	var truck: Node3D = null
	for m in main.machines:
		if m.get_meta("kind", "") == "dump" and not m.get("broken"):
			truck = m
	main.player.global_position = truck.door_position()
	await _frames(10)
	main.net.request("enter", int(truck.get_meta("net_id")))
	await _frames(60)
	print("[client] in the truck: %s" % (main.driving() == truck))
	var start: Vector3 = truck.global_position
	Input.action_press("drive_forward")
	await _frames(60 * 4)
	Input.action_release("drive_forward")
	await _frames(60)
	print("[client] truck moved %.1f m on my screen; HUD says %s" % [truck.global_position.distance_to(start), str(main.remote_hud.get("speed", -1)).substr(0, 4)])
	main.net.request("exit")
	await _frames(30)
	print("[client] out of the truck: %s" % (main.driving() == null))
	main.net.leave()
	await _frames(30)
