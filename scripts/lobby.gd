extends Node
## Room-code matchmaking for online play, with no server of our own: players find each
## other through free public MQTT brokers (message boards anyone can post to), swap
## WebRTC connection details there, then connect straight to each other. Several brokers
## are used at once, so one being down doesn't matter. Nothing secret crosses them: the
## topic is a hash of the room code, and the password check runs after connecting.

signal message(data: Dictionary)

## [url, username, password] (blank for brokers that don't ask).
const BROKERS := [
	["wss://broker.emqx.io:8084/mqtt", "", ""],
	["wss://public.cloud.shiftr.io:443", "public", "public"],
	["ws://test.mosquitto.org:8080", "", ""],
	["wss://broker-cn.emqx.io:8084/mqtt", "", ""],
]
const KEEPALIVE := 50

var _links: Array = []  # [{ws, buffer, up, ping}]
var _topics: Array = []
var _seen := {}
var _packet_id := 1


## Connects to the brokers and listens on `topics`.
func start(topics: Array) -> void:
	stop()
	_topics = topics
	for broker in BROKERS:
		var ws := WebSocketPeer.new()
		ws.supported_protocols = PackedStringArray(["mqtt"])
		ws.heartbeat_interval = 20.0
		if ws.connect_to_url(broker[0]) == OK:
			_links.append({"ws": ws, "buffer": PackedByteArray(), "up": false, "ping": 0.0, "url": broker[0], "user": broker[1], "pass": broker[2]})


func stop() -> void:
	for link in _links:
		(link.ws as WebSocketPeer).close()
	_links.clear()


## How many brokers are connected and listening.
func brokers_up() -> int:
	var n := 0
	for link in _links:
		if link.up:
			n += 1
	return n


## Posts `data` (a Dictionary, sent as JSON) to `topic` on every broker.
func publish(topic: String, data: Dictionary) -> void:
	data["n"] = randi()  # the same post arrives once per broker; keep the first
	var body := JSON.stringify(data).to_utf8_buffer()
	var packet := _string(topic) + body
	for link in _links:
		if link.up:
			_send(link, 0x30, packet)


func _process(delta: float) -> void:
	for link in _links:
		var ws: WebSocketPeer = link.ws
		ws.poll()
		match ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				if not link.has("hello"):
					link.hello = true
					var id := "ew" + str(randi())
					# CONNECT: protocol "MQTT" v3.1.1, clean session (+ username and password).
					var login: bool = link.user != ""
					var head := _string("MQTT") + PackedByteArray([4, 0xC2 if login else 0x02, KEEPALIVE >> 8, KEEPALIVE & 0xFF])
					var payload := _string(id)
					if login:
						payload += _string(link.user) + _string(link.pass)
					_send(link, 0x10, head + payload)
				while ws.get_available_packet_count() > 0:
					link.buffer = (link.buffer as PackedByteArray) + ws.get_packet()
				_parse(link)
				link.ping += delta
				if link.up and link.ping > KEEPALIVE * 0.5:
					link.ping = 0.0
					ws.send(PackedByteArray([0xC0, 0]))
			WebSocketPeer.STATE_CLOSED:
				link.up = false


func _parse(link: Dictionary) -> void:
	var buf: PackedByteArray = link.buffer
	while buf.size() >= 2:
		# Fixed header: type byte, then the remaining length as a varint.
		var length := 0
		var shift := 0
		var at := 1
		var complete := false
		while at < buf.size() and at < 5:
			var byte := buf[at]
			length |= (byte & 0x7F) << shift
			shift += 7
			at += 1
			if byte & 0x80 == 0:
				complete = true
				break
		if not complete or buf.size() < at + length:
			break
		var kind := buf[0] >> 4
		var body := buf.slice(at, at + length)
		buf = buf.slice(at + length)
		match kind:
			2:  # CONNACK
				if body.size() >= 2 and body[1] == 0:
					link.up = true
					for topic in _topics:
						_packet_id += 1
						_send(link, 0x82, PackedByteArray([_packet_id >> 8 & 0xFF, _packet_id & 0xFF]) + _string(topic) + PackedByteArray([0]))
			3:  # PUBLISH (QoS 0 only: no packet id)
				if body.size() >= 2:
					var topic_len := (body[0] << 8) | body[1]
					_receive(body.slice(2 + topic_len).get_string_from_utf8())
	link.buffer = buf


func _receive(text: String) -> void:
	var data = JSON.parse_string(text)
	if not data is Dictionary or not data.has("n"):
		return
	var n := int(data.n)
	if _seen.has(n):
		return
	_seen[n] = true
	if _seen.size() > 500:
		_seen.clear()
	message.emit(data)


func _send(link: Dictionary, header: int, body: PackedByteArray) -> void:
	var out := PackedByteArray([header])
	var length := body.size()
	while true:
		var byte := length & 0x7F
		length >>= 7
		if length > 0:
			byte |= 0x80
		out.append(byte)
		if length == 0:
			break
	(link.ws as WebSocketPeer).send(out + body)


func _string(text: String) -> PackedByteArray:
	var raw := text.to_utf8_buffer()
	return PackedByteArray([raw.size() >> 8, raw.size() & 0xFF]) + raw


## A random, easy-to-read room code like "KX7P-M3QD" (40 bits).
static func new_code() -> String:
	const LETTERS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var crypto := Crypto.new()
	var raw := crypto.generate_random_bytes(8)
	var out := ""
	for k in 8:
		out += LETTERS[raw[k] % 32]
		if k == 3:
			out += "-"
	return out


## Tidies what a player typed ("kx7p m3qd" -> "KX7P-M3QD").
static func clean_code(text: String) -> String:
	var out := ""
	for c in text.to_upper():
		if c in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789":
			out += c
	return out.substr(0, 4) + "-" + out.substr(4, 4) if out.length() == 8 else ""


## The message-board topic for a room (a hash: the code itself is never posted).
static func room_topic(code: String) -> String:
	var hash := ("earthworks-room:" + code).sha256_text()
	return "earthworks/r1/" + hash.substr(0, 32)
