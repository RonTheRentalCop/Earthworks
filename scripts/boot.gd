extends Node
## First scene: puts a downloaded update in place, then opens the game.
##
## Updates are the game's data pack (scripts, scenes, models) from the newest GitHub
## release, downloaded by updater.gd into user://updates/. Loading one over the built-in
## files before the game starts runs the new version on the same engine. A pack that
## fails to start the game is skipped next time (the game ticks it off once it's up).

const Updater = preload("res://scripts/updater.gd")


func _ready() -> void:
	var applied := ""
	if Updater.enabled():
		applied = _apply_newest()
	if applied != "":
		Engine.set_meta("game_version", applied)
		print("Earthworks: running update %s" % applied)
	get_tree().change_scene_to_file.call_deferred("res://main.tscn")


## Loads the newest downloaded pack that's newer than this build; returns its version.
func _apply_newest() -> String:
	var built_in := String(ProjectSettings.get_setting("application/config/version", "0"))
	var dir := DirAccess.open(Updater.DIR)
	if dir == null:
		return ""
	var best := ""
	for file in dir.get_files():
		if not file.ends_with(".pck"):
			continue
		var version := file.get_basename().trim_prefix("Earthworks-")
		if Updater.newer(version, built_in) and (best == "" or Updater.newer(version, best)):
			best = version
		elif not Updater.newer(version, built_in):
			dir.remove(file)  # this build is already as new (a fresh download replaced it)
	if best == "":
		return ""
	# The last start with this pack never reached the game: it's broken, drop it.
	if FileAccess.file_exists(Updater.TRYING) and FileAccess.get_file_as_string(Updater.TRYING) == best:
		dir.remove("Earthworks-%s.pck" % best)
		DirAccess.remove_absolute(Updater.TRYING)
		push_warning("Earthworks: update %s didn't start; skipped" % best)
		return ""
	var flag := FileAccess.open(Updater.TRYING, FileAccess.WRITE)
	if flag:
		flag.store_string(best)
		flag.close()
	if not ProjectSettings.load_resource_pack(Updater.DIR + "Earthworks-%s.pck" % best, true):
		return ""
	return best
