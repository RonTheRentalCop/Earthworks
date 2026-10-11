extends SceneTree
## Checks the WebRTC plugin loads and which public brokers answer (round trip a message).

const Lobby = preload("res://scripts/lobby.gd")


func _init() -> void:
	var pc := WebRTCPeerConnection.new()
	print("[probe] webrtc init: ", pc.initialize({"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]}) == OK)
	var lobby: Node = Lobby.new()
	root.add_child.call_deferred(lobby)
	var topic := Lobby.room_topic(Lobby.new_code())
	var got := []
	lobby.message.connect(func(d: Dictionary) -> void: got.append(d))
	await process_frame
	lobby.start([topic])
	var t := 0
	var t0 := Time.get_ticks_msec()
	while lobby.brokers_up() < 4 and Time.get_ticks_msec() - t0 < 6000:
		await process_frame
		t += 1
	for link in lobby._links:
		print("[probe] ", link.url, " up: ", link.up)
	lobby.publish(topic, {"hi": 1})
	t = 0
	t0 = Time.get_ticks_msec()
	while got.size() < 1 and Time.get_ticks_msec() - t0 < 4000:
		await process_frame
		t += 1
	print("[probe] round trip: ", got)
	# Gather ICE candidates (needs STUN to answer).
	var cands := []
	pc.ice_candidate_created.connect(func(m: String, i: int, n: String) -> void: cands.append(n))
	pc.session_description_created.connect(func(ty: String, sdp: String) -> void: pc.set_local_description(ty, sdp))
	pc.create_data_channel("x")
	pc.create_offer()
	t = 0
	while t < 180:
		pc.poll()
		await process_frame
		t += 1
	print("[probe] candidates: ", cands)
	print("[probe] gathering state: ", pc.get_gathering_state() if pc.has_method("get_gathering_state") else "n/a")
	quit()
