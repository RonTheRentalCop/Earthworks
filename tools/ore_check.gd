extends SceneTree
## Ore in the soil: bands get richer with depth; a bucket dug deep carries ore value into
## a truck; tipped into the ore crusher it pays, tipped into the portable forge it comes
## out as bars; the magnet picks bars up and a shredder buys them; the quarry tip pays
## for fill. Run:
##   godot --headless --path . -s tools/ore_check.gd

var main
var t


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


## Parks `truck` so the soil pouring off its tailgate lands in `receiver`.
func _back_up_to(truck, receiver) -> bool:
	var c: Vector3 = receiver.global_position
	for yaw_k in 8:
		var basis := Basis(Vector3.UP, yaw_k * TAU / 8.0)
		for r in range(2, 26):
			for side in range(-6, 7):
				var p: Vector3 = c + basis.z * (r * 0.5) + basis.x * (side * 0.5)
				truck.place(Transform3D(basis, Vector3(p.x, t.get_height(p.x, p.z) + 0.3, p.z)))
				if receiver.accepts_soil(truck._bed.to_global(Vector3(0, -0.6, 1.0))):
					return true
	return false


func _tip(truck) -> void:
	main.player.global_position = truck.door_position()
	main._enter_machine(truck)
	Input.action_press("boom_up")
	await _frames(300)
	Input.action_release("boom_up")
	Input.action_press("boom_down")
	await _frames(200)
	Input.action_release("boom_down")
	main._exit_machine()


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	t = main.terrain
	var Ores = main.Ores
	# --- Bands.
	var spot := Vector2(120, 170)
	var line := ""
	for d in [0.5, 1.5, 2.5, 3.5, 5.0, 7.0]:
		var g: Vector2 = Ores.grade(spot, d)
		line += "%.1f m %s $%.0f/m3%s;  " % [d, Ores.BANDS[Ores.band_at(d)][1], g.x, " (gold)" if g.y > 0.5 else ""]
	print("bands at (120, 170), region x%.2f: %s" % [Ores.region(spot), line])
	print("boulders/ore chunks lying about: %d" % main.get_tree().get_nodes_in_group("ore").size())
	# --- A real dig, deep: pre-dig a 4 m pit, then let the excavator dig its floor.
	var exc = main.excavator
	var pit := Vector3(spot.x, 0, spot.y)
	# A wide pit 4.2 m deep, the excavator sitting on its floor.
	for pass_k in 6:
		for dz in range(-4, 5):
			for dx in range(-4, 5):
				var c := Vector3(pit.x + dx * 2.0, 0, pit.z + dz * 2.0)
				t.dig(Vector3(c.x, t.original_height(c.x, c.z) - 4.2, c.z), 1.6, 30.0)
	exc.place(Transform3D(Basis.IDENTITY, Vector3(pit.x, t.get_height(pit.x, pit.z + 3), pit.z + 3)))
	main._update_anchors()
	await _frames(30)
	main.player.global_position = exc.door_position()
	main._enter_machine(exc)
	for step in [["boom_down", 150], ["stick_out", 60], ["bucket_curl", 240]]:
		Input.action_press(step[0])
		await _frames(step[1])
		Input.action_release(step[0])
	main._exit_machine()
	print("dug in the pit floor: bucket %.2f m3 worth $%.0f (gold $%.0f), teeth in %s" % [
		exc.bucket_load, exc.bucket_value, exc.bucket_gold, Ores.BANDS[exc.digging_band][1]])
	# --- Truck takes the ore value from a bucket pour (share for share).
	var truck = main.truck
	truck.add_soil(6.0)
	truck.add_value(900.0, 600.0)
	print("truck: %.1f m3 carrying ore $%.0f (gold $%.0f)" % [truck.payload, truck.payload_value, truck.payload_gold])
	# --- Crusher pays for it.
	var crusher = main.shredders[main.shredders.size() - 1]
	var placed := await _back_up_to(truck, crusher)
	await _frames(30)
	var money: int = main.career.money
	await _tip(truck)
	await _frames(120)
	print("crusher: truck backed up %s, cash +%d, ore left in the truck $%.0f" % [placed, main.career.money - money, truck.payload_value])
	# --- Forge makes bars.
	var forge = main.spawn_vehicle("forge")
	var fspot := Vector3(80, 0, 120)
	forge.place(Transform3D(Basis.IDENTITY, Vector3(fspot.x, t.get_height(fspot.x, fspot.z), fspot.z)))
	await _frames(20)
	truck.add_soil(6.0)
	truck.add_value(3000.0, 2200.0)
	placed = await _back_up_to(truck, forge)
	await _frames(20)
	var bars_before: int = main.get_tree().get_nodes_in_group("magnetic").size()
	var drop_ok := 0
	var drop_frames := 0
	main.player.global_position = truck.door_position()
	main._enter_machine(truck)
	Input.action_press("boom_up")
	for fr in 300:
		await _frames(1)
		if truck.payload > 0.0 and truck._bed.rotation.x > 0.2:
			drop_frames += 1
			if forge.accepts_soil(truck._bed.to_global(Vector3(0, -0.6, 1.0))):
				drop_ok += 1
	Input.action_release("boom_up")
	Input.action_press("boom_down")
	await _frames(200)
	Input.action_release("boom_down")
	main._exit_machine()
	print("forge: tailgate over the hopper %d of %d pouring frames" % [drop_ok, drop_frames])
	await _frames(60 * 12)
	var bars: Array = main.get_tree().get_nodes_in_group("magnetic")
	var kinds := {}
	for b in bars:
		kinds[b.get_meta("ore")] = kinds.get(b.get_meta("ore"), 0) + 1
	print("forge: truck backed up %s, took the soil (hopper now %.1f), bars out %s, made %d, left molten gold $%.0f silver $%.0f" % [
		placed, forge.hopper, kinds, forge.bars_made, forge.gold_metal, forge.silver_metal])
	# --- Magnet picks the bars up.
	exc.set_attachment(5)
	if bars.is_empty():
		quit()
		return
	var first: RigidBody3D = bars[0]
	exc.place(Transform3D(Basis.IDENTITY, Vector3(first.global_position.x, t.get_height(first.global_position.x, first.global_position.z + 7), first.global_position.z + 7)))
	await _frames(30)
	# Bring the bars under the magnet face (as if the operator lowered it onto them).
	var face: Vector3 = exc._magnet.to_global(Vector3(0, -1.0, 0))
	for b in bars:
		b.global_position = face + Vector3(randf_range(-0.5, 0.5), -0.3, randf_range(-0.5, 0.5))
		b.linear_velocity = Vector3.ZERO
	main.player.global_position = exc.door_position()
	main._enter_machine(exc)
	Input.action_press("bucket_curl")
	await _frames(30)
	Input.action_release("bucket_curl")
	await _frames(20)
	var held: int = exc._magnet_held.size()
	Input.action_press("boom_up")
	await _frames(60)
	Input.action_release("boom_up")
	var lifted: float = (exc._magnet_held[0][0] as Node3D).global_position.y - t.get_height(face.x, face.z) if held > 0 else 0.0
	Input.action_press("bucket_dump")
	await _frames(20)
	Input.action_release("bucket_dump")
	main._exit_machine()
	print("magnet: on %s, holding %d of %d bars, lifted %.1f m; switched off, holding %d" % [exc.magnet_on or held > 0, held, bars.size(), lifted, exc._magnet_held.size()])
	# --- A shredder buys a bar.
	var shredder = main.shredders[0]
	money = main.career.money
	var bar: RigidBody3D = bars[0]
	bar.global_position = shredder.infeed_point() + Vector3(0, 1.0, 0)
	bar.linear_velocity = Vector3.ZERO
	await _frames(60 * 3)
	print("shredder bought the %s: %s, cash +%d" % [bar.get_meta("label") if is_instance_valid(bar) else "bar", not is_instance_valid(bar), main.career.money - money])
	# --- Quarry tip pays for fill.
	truck.add_soil(8.0)
	placed = await _back_up_to(truck, main.tip)
	await _frames(20)
	money = main.career.money
	await _tip(truck)
	await _frames(90)
	print("quarry tip: backed up %s, cash +%d for fill, truck now %.1f m3" % [placed, main.career.money - money, truck.payload])
	quit()
