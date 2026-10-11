extends Node
## Auto-updater (exported builds only; running from the project folder never updates).
## On start it asks GitHub for the newest release; if that's newer than the version
## running, it downloads the release's data pack for this platform into user://updates/
## in the background. Restarting (pause menu → RESTART TO UPDATE, or just next launch)
## runs the new version (boot.gd loads the pack).

signal update_ready(version: String)

const RELEASES := "https://api.github.com/repos/RonTheRentalCop/Earthworks/releases/latest"
const DIR := "user://updates/"
const TRYING := "user://updates/starting.txt"

var ready_version := ""  # downloaded and waiting for a restart
var _http: HTTPRequest
var _target := ""


## Only real (exported) builds update themselves; --check-updates forces it for testing.
static func enabled() -> bool:
	return OS.has_feature("template") or "--check-updates" in OS.get_cmdline_user_args()


## The version this game is running (an applied update, or the built-in one).
static func current() -> String:
	if Engine.has_meta("game_version"):
		return String(Engine.get_meta("game_version"))
	return String(ProjectSettings.get_setting("application/config/version", "0"))


## True if version `a` ("0.2.10") is newer than `b` ("0.2.9").
static func newer(a: String, b: String) -> bool:
	var x := a.trim_prefix("v").split(".")
	var y := b.trim_prefix("v").split(".")
	for k in maxi(x.size(), y.size()):
		var i := x[k].to_int() if k < x.size() else 0
		var j := y[k].to_int() if k < y.size() else 0
		if i != j:
			return i > j
	return false


## The game got going on this version: it isn't a broken update.
static func started_ok() -> void:
	if FileAccess.file_exists(TRYING):
		DirAccess.remove_absolute(TRYING)


func _ready() -> void:
	started_ok()
	if not enabled():
		return
	DirAccess.make_dir_recursive_absolute(DIR)
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	add_child(_http)
	_http.request_completed.connect(_on_release)
	_http.request(RELEASES, ["User-Agent: Earthworks-updater", "Accept: application/vnd.github+json"])


func _on_release(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_http.request_completed.disconnect(_on_release)
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return  # offline, or GitHub is busy: try again next launch
	var release = JSON.parse_string(body.get_string_from_utf8())
	if not release is Dictionary:
		return
	var version := String(release.get("tag_name", "")).trim_prefix("v")
	if version == "" or not newer(version, current()):
		return
	if FileAccess.file_exists(DIR + "Earthworks-%s.pck" % version):
		_ready_to_go(version)
		return
	var wanted := "Earthworks-macOS.pck" if OS.get_name() == "macOS" else "Earthworks-Windows.pck"
	for asset in release.get("assets", []):
		if asset is Dictionary and String(asset.get("name", "")) == wanted:
			_target = version
			_http.download_file = DIR + "download.part"
			_http.timeout = 600.0
			_http.request_completed.connect(_on_downloaded)
			_http.request(String(asset.browser_download_url), ["User-Agent: Earthworks-updater"])
			print("Earthworks: downloading update %s" % version)
			return


func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_http.request_completed.disconnect(_on_downloaded)
	var part := DIR + "download.part"
	var file := FileAccess.open(part, FileAccess.READ)
	var size := file.get_length() if file else 0
	file = null
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or size < 100000:
		DirAccess.remove_absolute(part)
		return
	DirAccess.rename_absolute(part, DIR + "Earthworks-%s.pck" % _target)
	_ready_to_go(_target)


func _ready_to_go(version: String) -> void:
	ready_version = version
	update_ready.emit(version)


## Saves and restarts into the new version.
func restart() -> void:
	OS.set_restart_on_exit(true, OS.get_cmdline_args())
	get_tree().quit()
