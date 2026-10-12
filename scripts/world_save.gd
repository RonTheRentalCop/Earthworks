extends RefCounted
## Saves the world itself between sessions: every patch of ground that's been dug,
## filled, rutted or gravelled, which trees have been felled or pulled out, the logs and
## stumps still lying about, the demolition rubble and the ground mats. (Cash, unlocks and
## the fleet are the career's save.) Written to user:// next to the career save, a few
## hundred kilobytes, compressed.

const PATH := "user://earthworks_world.save"
## Where it's written (tests point this elsewhere so they never touch your save).
static var path := PATH
const VERSION := 3  # (3: the 1.5 km map)
## Old saves are kept here (copied the first time a newer game opens them), and so is any
## save that can't be read, so nothing is ever lost.
const BACKUPS := "user://backups/"


## Writes the save (safely: to a temporary file first, then swapped in).
static func save(main: Node) -> bool:
	var terrain = main.terrain
	var forests = main.forests
	# Each chunk is kept compressed between saves; only the ones changed since are redone.
	var chunks := []
	for index in terrain.edited:
		if terrain.save_stale.has(index) or not terrain.save_cache.has(index):
			var raw_chunk := var_to_bytes(terrain.net_pack_chunk(int(index)))
			terrain.save_cache[index] = [raw_chunk.size(), raw_chunk.compress(FileAccess.COMPRESSION_ZSTD)]
		chunks.append(terrain.save_cache[index])
	terrain.save_stale.clear()
	# Saved changes to ground not visited this session are still waiting: keep them too.
	for index in terrain._pending_chunks:
		if not terrain.edited.has(index):
			var raw_wait := var_to_bytes(terrain._pending_chunks[index])
			chunks.append([raw_wait.size(), raw_wait.compress(FileAccess.COMPRESSION_ZSTD)])
	var logs := []  # [tid, kind ("log" or "stump"), transform] for wood still lying about
	for tid in main.tree_bodies:
		var known: Array = main.tree_bodies[tid]
		for k in 2:
			var body: Node3D = main.bodies.get(int(known[k]))
			if is_instance_valid(body) and body.is_inside_tree():
				logs.append([int(tid), "log" if k == 0 else "stump", body.global_transform])
	var debris := []
	for k in main.debris.size():
		var b = main.debris[k]  # (untyped: a sold or cleared boulder is a freed instance)
		debris.append(b.global_transform if is_instance_valid(b) and b.is_inside_tree() else null)
	var mats := []
	var ores := []
	for id in main.bodies:
		var b = main.bodies[id]
		if is_instance_valid(b) and b.get_meta("label", "") == "ground mat":
			mats.append(b.global_transform)
		elif is_instance_valid(b) and b.has_meta("ore") and int(id) >= main.FIRST_DYNAMIC_ID and b.is_inside_tree():
			ores.append([b.get_meta("ore"), b.global_transform])
	# The fleet, where it was left (job trucks that broke down aren't yours to keep).
	var vehicles := []
	for v in main.machines + main.trailers:
		if is_instance_valid(v) and v.is_inside_tree() and not v.get("broken"):
			vehicles.append([String(v.get_meta("kind", "dump")), v.global_transform, main.vehicle_extra(v)])
	var data := {
		"version": VERSION, "cells": terrain.CELLS, "trees": forests.count(),
		"terrain": chunks, "tree_state": forests.state, "logs": logs, "debris": debris, "mats": mats, "ores": ores,
		"vehicles": vehicles, "player": main.player.global_transform,
		# (so later versions can always put this ground back, whatever their grid)
		"cell_size": terrain.CELL_SIZE, "game": String(main.Updater.current()),
	}
	var raw := var_to_bytes(data)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var temp := path + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return false
	file.store_32(raw.size())
	file.store_buffer(packed)
	file.close()
	var dir := DirAccess.open("user://")
	if dir.file_exists(path.get_file()):
		dir.remove(path.get_file())
	return dir.rename(temp.get_file(), path.get_file()) == OK


## Copies the save as it is into the backups folder (once per version it came from).
static func keep_copy(label: String) -> void:
	DirAccess.make_dir_recursive_absolute(BACKUPS)
	var to := BACKUPS + "earthworks_world-%s.save" % label.validate_filename()
	if not FileAccess.file_exists(to):
		DirAccess.copy_absolute(path, to)


## Moves a save that can't be read out of the way (into backups), so it's never overwritten.
static func set_aside(reason: String) -> void:
	DirAccess.make_dir_recursive_absolute(BACKUPS)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	DirAccess.rename_absolute(path, BACKUPS + "earthworks_world-%s-%s.save" % [reason, stamp])


static func exists() -> bool:
	return FileAccess.file_exists(path)


static func erase() -> void:
	var dir := DirAccess.open("user://")
	if dir and dir.file_exists(path.get_file()):
		dir.remove(path.get_file())


## Puts the saved world back (call once the fresh world is built). False if there's no
## save, or it's from a different map.
static func restore(main: Node) -> bool:
	if not exists():
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 8:
		return false
	var size := file.get_32()
	var packed := file.get_buffer(file.get_length() - 4)
	file.close()
	var raw := packed.decompress(size, FileAccess.COMPRESSION_ZSTD)
	var data = bytes_to_var(raw) if raw.size() == size else null
	if not data is Dictionary or not data.has("terrain") or int(data.get("version", 0)) < 2:
		set_aside("unreadable")
		return false
	var terrain = main.terrain
	var forests = main.forests
	# A save from another version: keep a copy of it as it was, then bring it in.
	var made_by := String(data.get("game", "v%d" % int(data.get("version", 0))))
	if made_by != String(main.Updater.current()):
		keep_copy(made_by)
	var old_cells := int(data.get("cells", terrain.CELLS))
	var old_cell := float(data.get("cell_size", 0.25 if old_cells == 4096 else terrain.CELL_SIZE))
	var same_grid: bool = old_cells == terrain.CELLS and is_equal_approx(old_cell, terrain.CELL_SIZE)
	for entry in data.terrain:
		var chunk = bytes_to_var((entry[1] as PackedByteArray).decompress(int(entry[0]), FileAccess.COMPRESSION_ZSTD))
		if not chunk is Array:
			continue
		if not same_grid:
			# Made on another map size or grid: put it back by world position.
			terrain.import_foreign_chunk(chunk, old_cells, old_cell)
			var span: float = float(terrain.CHUNK_CELLS) * old_cell
			var old_chunks: int = old_cells / terrain.CHUNK_CELLS
			var c := Vector2((int(chunk[0]) % old_chunks) * span, (int(chunk[0]) / old_chunks) * span) - Vector2.ONE * old_cells * old_cell * 0.5
			terrain.area_changed.emit(Rect2(c, Vector2(span, span)))
			continue
		if not terrain.net_apply_chunk(chunk):
			continue  # far off: goes in when that ground is first generated
		# Water, collision, grass and the minimap all redraw from this.
		var index: int = chunk[0]
		var size_m: float = terrain.CHUNK_CELLS * terrain.CELL_SIZE
		var corner := Vector2((index % terrain.CHUNKS) * size_m - terrain.HALF_SIZE, (index / terrain.CHUNKS) * size_m - terrain.HALF_SIZE)
		terrain.area_changed.emit(Rect2(corner, Vector2(size_m, size_m)))
	# Trees: the wood that's still lying about comes back as bodies where it was left;
	# the rest just keeps its felled / pulled state.
	var lying := {}
	for entry in data.logs:
		lying["%d/%s" % [int(entry[0]), entry[1]]] = entry[2]
	var saved_state: PackedByteArray = data.tree_state
	var dirty_cells := {}
	# (New forests are only ever added after the old ones, so a tree's number stays the same.)
	for tid in mini(saved_state.size(), forests.count()):
		var s := int(saved_state[tid])
		if s == 0 or forests.state[tid] != 0:
			continue
		var log_key := "%d/log" % tid
		var stump_key := "%d/stump" % tid
		if s >= 1 and lying.has(log_key):
			var body: RigidBody3D = forests.apply_event(tid, "fell", main)
			if body:
				body.global_transform = lying[log_key]
				body.sleeping = true
		if s == 2 and lying.has(stump_key):
			var body: RigidBody3D = forests.apply_event(tid, "pulled", main)
			if body:
				body.global_transform = lying[stump_key]
				body.sleeping = true
		if forests.state[tid] != s:
			forests.state[tid] = s
			dirty_cells[forests._cell_of(Vector2(forests.pos[tid].x, forests.pos[tid].z))] = true
	for c in dirty_cells:
		forests._rebuild_cell(c)
	for k in mini(data.debris.size(), main.debris.size()):
		var xform = data.debris[k]
		var b: RigidBody3D = main.debris[k]
		if xform is Transform3D and is_instance_valid(b):
			b.global_transform = xform
			b.sleeping = true
		elif xform == null and is_instance_valid(b) and b.has_meta("ore"):
			b.queue_free()  # a boulder that was sold at the crusher
	for entry in data.get("ores", []):
		if String(entry[0]).ends_with("_bar"):  # (old saves' loose ore chunks are gone: ore is in the soil now)
			main.spawn_ore(String(entry[0]), entry[1])
	if not data.mats.is_empty():
		for xform in data.mats:
			var id: int = main.next_body_id
			main.next_body_id += 1
			main._register_body(main.make_mat(xform), id)
	if data.has("vehicles") and not (data.vehicles as Array).is_empty():
		main.restore_fleet(data.vehicles)
	if data.get("player") is Transform3D:
		main.player.global_transform = data.player
	return true
