extends SceneTree
## Dev check for the recovery / towing / attachment systems. Prints numbers; run windowed
## with an output folder to also save first-person shots from every vehicle.
## Usage: godot --path . -s tools/feature_check.gd [-- out_dir]

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	root.size = Vector2i(1280, 720)
	await _frames(30)
	var t: Node = main.terrain
	var out: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else ""

	# --- Mud ruts deepen with each pass.
	var spot := Vector3(44, 0, 66)
	spot.y = t.get_height(spot.x, spot.z)
	var depths := []
	for pass_number in 3:
		t.press(spot, Vector3.FORWARD, 0.4, 0.3, 0.05)
		depths.append(snappedf(t.original_height(spot.x, spot.z) - t.get_height(spot.x, spot.z), 0.01))
	print("mud rut depth after passes 1-3: ", depths)

	# --- Recovery: a loaded dump truck bogged in the mud pit, winched out by the wrecker.
	var truck = main.truck
	truck.add_soil(8.0)
	truck.place(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(44, t.get_height(44, 66) + 0.3, 66)))
	await _frames(60)
	var rec = main.recovery
	# Facing away from the stuck truck so the boom winch at the back points at it.
	rec.place(Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(28, t.get_height(28, 66) + 0.4, 66)))
	main.player.global_position = rec.door_position()
	main._enter_machine(rec)
	await _frames(30)
	var start: Vector3 = truck.global_position
	var hooked: String = rec.winch.attach(rec.winch.global_position - rec.global_position)
	print("recovery winch hooked: '", hooked, "'  cable %.1f m" % rec.winch.length)
	rec.winch.reel(true)
	Input.action_press("drive_forward")
	await _frames(int(7.0 * 60))
	Input.action_release("drive_forward")
	rec.winch.reel(false)
	print("stuck truck pulled %.1f m, mud under it now %.2f (tension peaked during pull)" % [truck.global_position.distance_to(start), truck.mud_level])
	rec.winch.detach()

	# --- Trailer: hitch to the recovery truck, park the dozer on the deck, tow both.
	var trailer = main.trailer
	rec.place(Transform3D(Basis(Vector3.UP, PI), Vector3(0, t.get_height(0, 50) + 0.4, 50)))
	await _frames(20)
	var hitch: Vector3 = rec.hitch_point()
	trailer.place_behind(hitch, rec.global_basis)
	await _frames(20)
	main._press_utility()
	print("trailer hitched: ", trailer.towed_by == rec)
	var dozer = main.dozer
	var deck: Vector3 = trailer.deck_centre()
	dozer.place(Transform3D(trailer.global_basis.rotated(Vector3.UP, PI), deck))
	await _frames(40)
	print("dozer resting height above ground %.2f (deck ~1.1)" % (dozer.global_position.y - t.get_height(dozer.global_position.x, dozer.global_position.z)))
	var trailer_start: Vector3 = trailer.global_position
	var dozer_start: Vector3 = dozer.global_position
	Input.action_press("drive_forward")
	await _frames(int(5.0 * 60))
	Input.action_release("drive_forward")
	await _frames(60)
	print("towed: trailer moved %.1f m, dozer riding on it moved %.1f m" % [trailer.global_position.distance_to(trailer_start), dozer.global_position.distance_to(dozer_start)])
	main._exit_machine()

	# --- Excavator attachments and the grapple.
	var ex = main.excavator
	ex.place(Transform3D(Basis.IDENTITY, Vector3(-40, 0, 40)))
	main.player.global_position = ex.door_position()
	main._enter_machine(ex)
	var names := []
	for k in 3:
		names.append(ex.cycle_attachment())
	print("attachments: ", names, "  big bucket capacity was 6.5")
	await _frames(10)
	var log: RigidBody3D = main.forests.apply_event(0, "fell", main)
	await _frames(5)
	log.global_position = ex._grapple.to_global(Vector3(0, -1.25, 0)) - Vector3(0, 0.4, 0)
	log.linear_velocity = Vector3.ZERO
	ex._jaw = 1.0
	await _frames(5)
	print("grapple holding: ", ex.held != null)
	var held_y: float = log.global_position.y
	Input.action_press("boom_up")
	await _frames(60)
	Input.action_release("boom_up")
	print("log lifted %.2f m with the boom" % (log.global_position.y - held_y))

	if out != "" and DisplayServer.get_name() != "headless":
		main.hud.visible = false
		for m in [main.excavator, main.dozer, main.truck, main.recovery]:
			main._exit_machine()
			main.player.global_position = m.door_position()
			main._enter_machine(m)
			main.camera.toggle_cab_view()
			for i in 20:
				await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(out + "/cab_" + String(m.machine_name).replace(" ", "_") + ".png")
			main.camera.toggle_cab_view()
	quit()
