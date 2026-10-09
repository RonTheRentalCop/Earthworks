extends Node
## The company's books: cash, which machines and tools are unlocked, and lifetime stats.
## Saved to user:// whenever something changes, so progress carries over between sessions.
## Unlocking a machine is a one-off purchase; after that any number can be called out to
## the depot for free.

signal money_changed(money: int, change: int, reason: String)
signal unlocked(id: String)

const SAVE_PATH := "user://earthworks_save.cfg"
const START_MONEY := 12000
const MAX_FLEET := 14

## Machines in the dealer catalogue. "kind" is what main.gd spawns.
const MACHINES := [
	{"id": "excavator", "name": "Excavator", "price": 0, "kind": "excavator",
		"blurb": "Digs, loads trucks, swaps tools.", "stats": ["3.5 m³ bucket", "Tracks · 360° swing", "160 kN winch"]},
	{"id": "dozer", "name": "Bulldozer", "price": 0, "kind": "dozer",
		"blurb": "U-blade: carries everything straight ahead.", "stats": ["9 m³ U-blade", "Tilt blade · ripper", "380 kN winch"]},
	{"id": "dozer_angle", "name": "Angle dozer", "price": 14000, "kind": "dozer_angle",
		"blurb": "Angle blade: rolls soil off to the side.", "stats": ["6 m³ angle blade", "Angles ±29°", "Ripper"]},
	{"id": "dump", "name": "Dump truck", "price": 0, "kind": "dump",
		"blurb": "Hauls soil from the dig to the fill.", "stats": ["8 m³ body", "40 km/h", "Tow hitch"]},
	{"id": "pickup", "name": "Site pickup", "price": 6500, "kind": "pickup",
		"blurb": "Quick 4x4 for getting around the site.", "stats": ["86 km/h", "4x4", "60 kN winch"]},
	{"id": "recovery", "name": "Recovery truck", "price": 18000, "kind": "recovery",
		"blurb": "Heavy 6x6 wrecker for stuck machines.", "stats": ["220 kN boom winch", "35 m cable", "6x6 mud tyres"]},
	{"id": "trailer", "name": "Lowboy trailer", "price": 9000, "kind": "trailer",
		"blurb": "Carries tracked machines. Hydraulic ramps.", "stats": ["9 m deck", "Hydraulic ramps", "Hitch to any truck"]},
	{"id": "logs", "name": "Log truck", "price": 15000, "kind": "logs",
		"blurb": "Carries logs to the shredder and tips them off.", "stats": ["Tipping log bed", "Tall stakes", "47 km/h"]},
	{"id": "haul", "name": "Heavy haul tractor", "price": 24000, "kind": "haul",
		"blurb": "Big pulling power for the lowboy.", "stats": ["400 kN tractive", "61 km/h", "8 t ballast"]},
	{"id": "adt", "name": "Articulated hauler", "price": 38000, "kind": "adt",
		"blurb": "Off-road 6x6 hauler. Laughs at mud.", "stats": ["14 m³ body", "6x6 · big tyres", "47 km/h"]},
	{"id": "excavator_xl", "name": "Mining excavator", "price": 52000, "kind": "excavator_xl",
		"blurb": "Twice the size: fills a hauler in two passes.", "stats": ["10 m³ bucket", "Huge reach", "Takes all tools"]},
]

## Excavator tools. "attachment" is the index in excavator.gd's ATTACHMENTS.
const TOOLS := [
	{"id": "bucket", "name": "Digging bucket", "price": 0, "attachment": 0, "blurb": "Standard 3.5 m³ bucket."},
	{"id": "trench", "name": "Trench bucket", "price": 3500, "attachment": 2, "blurb": "Narrow 1.5 m³ bucket for trenches."},
	{"id": "big_bucket", "name": "Bulk bucket", "price": 9000, "attachment": 1, "blurb": "6.5 m³ for fast truck loading."},
	{"id": "grapple", "name": "Tree grapple", "price": 7500, "attachment": 3, "blurb": "Fells trees, pulls stumps, lifts logs."},
]

## Consumables: bought as often as you like and delivered to the depot.
const SUPPLIES := [
	{"id": "mats", "name": "Ground mats ×4", "price": 1200, "blurb": "Heavy timber crane mats. Lay them on mud and nothing sinks."},
]

var money := START_MONEY
## Graphics quality 0 low, 1 medium, 2 high (Macs default to medium).
var quality := 1 if OS.get_name() == "macOS" else 2
## Multiplayer form defaults (remembered between sessions).
var player_name := ""
var last_address := ""
var last_port := 24680
var owned := {}  # id -> true
var stats := {"earned": 0, "jobs": 0, "logs": 0, "stumps": 0, "soil": 0.0}
## False in automated tests, so they never touch the player's save.
var persistent := true


func _ready() -> void:
	reset_defaults()
	_load_settings()
	if persistent:
		load_game()


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	quality = int(cfg.get_value("settings", "quality", quality))
	player_name = String(cfg.get_value("settings", "name", player_name))
	last_address = String(cfg.get_value("settings", "address", last_address))
	last_port = int(cfg.get_value("settings", "port", last_port))


## Saves just the settings (works while playing in someone else's game too).
func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("settings", "quality", quality)
	cfg.set_value("settings", "name", player_name)
	cfg.set_value("settings", "address", last_address)
	cfg.set_value("settings", "port", last_port)
	cfg.save(SAVE_PATH)


func reset_defaults() -> void:
	money = START_MONEY
	owned = {}
	for item in MACHINES + TOOLS:
		if int(item.price) == 0:
			owned[item.id] = true
	stats = {"earned": 0, "jobs": 0, "logs": 0, "stumps": 0, "soil": 0.0}


func new_game() -> void:
	reset_defaults()
	save_game()
	money_changed.emit(money, 0, "")


func is_owned(id: String) -> bool:
	return owned.has(id)


func can_afford(price: int) -> bool:
	return money >= price


## Buys a machine or tool; returns false if it can't be afforded.
func buy(id: String) -> bool:
	var item := find(id)
	if item.is_empty() or is_owned(id) or not can_afford(int(item.price)):
		return false
	money -= int(item.price)
	owned[id] = true
	save_game()
	money_changed.emit(money, -int(item.price), item.name)
	unlocked.emit(id)
	return true


## Multiplayer: joining players mirror the host's books.
func set_remote(new_money: int, owned_ids: Array, change: int, reason: String) -> void:
	money = new_money
	owned = {}
	for id in owned_ids:
		owned[String(id)] = true
	money_changed.emit(money, change, reason)


## Pays for something (supplies); false if it can't be afforded.
func spend(amount: int, reason: String) -> bool:
	if money < amount:
		return false
	money -= amount
	save_game()
	money_changed.emit(money, -amount, reason)
	return true


func earn(amount: int, reason: String) -> void:
	money += amount
	stats.earned = int(stats.earned) + amount
	save_game()
	money_changed.emit(money, amount, reason)


func find(id: String) -> Dictionary:
	for item in MACHINES + TOOLS:
		if item.id == id:
			return item
	return {}


func allowed_attachments() -> Array:
	var result := []
	for tool in TOOLS:
		if is_owned(tool.id):
			result.append(int(tool.attachment))
	return result


func save_game() -> void:
	if not persistent:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("career", "money", money)
	cfg.set_value("career", "owned", owned.keys())
	cfg.set_value("career", "stats", stats)
	cfg.set_value("settings", "quality", quality)
	cfg.set_value("settings", "name", player_name)
	cfg.set_value("settings", "address", last_address)
	cfg.set_value("settings", "port", last_port)
	cfg.save(SAVE_PATH)


func load_game() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	money = int(cfg.get_value("career", "money", START_MONEY))
	for id in cfg.get_value("career", "owned", []):
		owned[String(id)] = true
	quality = int(cfg.get_value("settings", "quality", quality))
	var saved: Dictionary = cfg.get_value("career", "stats", {})
	for key in saved:
		stats[key] = saved[key]
