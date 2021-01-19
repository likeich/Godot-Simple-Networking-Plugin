extends Node
# Networking interface that allows for easy networking implementation.
# Any generic networking actions (state changes) will go through this interface.

# Default port for networking.
const DEFAULT_PORT := 34197
const MAX_PLAYERS := 4095
var my_global_ip := ""
var my_local_ip := get_local_ip()
var server_updates_per_second := 20.0

# Signals to enable custom behavior in lobbies and matches.
signal player_list_changed(player_list)
signal player_data_changed()
signal connection_succeeded()
signal connection_failed()
signal disconnected()
signal global_ip_found()

signal object_state_changed(new_state, object_name)

var network: NetworkedMultiplayerENet

var player_ids = [] # Holds the ids of every connected player
var custom_player_data = {} # Holds custom info from every player (name, color, team, etc.)

var server_can_update := true
var server_local_states: Dictionary = {}
var server_received_states: Dictionary = {}
var last_world_state_timestamp: int = 0
var world_state_buffer: Array = []

# Syncronized clock variables
var latency := 0
var delta_latency := 0
var client_clock := 0
var latency_array := []
var server_time_difference: int

var debug_label: Label

onready var http := HTTPRequest.new()
onready var timer := Timer.new()

func _ready():
	# Connects all networking signals from the SceneTree to our signals.
	get_tree().connect("network_peer_connected", self, "_player_connected")
	get_tree().connect("network_peer_disconnected", self,"_player_disconnected")
	get_tree().connect("connected_to_server", self, "_connected_ok")
	get_tree().connect("connection_failed", self, "_connected_fail")
	get_tree().connect("server_disconnected", self, "_server_disconnected")
	
	add_child(timer)
	timer.connect("timeout", self, "update_rate_timeout")
	timer.one_shot = true
	
	# Gets the global ip for this device.
	add_child(http)
	var _err = http.connect("request_completed", self, "set_my_global_ip")
	_err = http.request("https://api.ipify.org")
	
	get_local_ip()

func _physics_process(delta):
	# Server process
	if is_instance_valid(get_tree().network_peer) and get_tree().is_network_server() and server_can_update:
		server_can_update = false
		timer.stop()
		
		# Send world snapshot
		send_world_state()
		timer.start(1.0/server_updates_per_second)
	# Client process
	if is_instance_valid(get_tree().network_peer) and !get_tree().is_network_server():
		print(client_clock)
		process_world_state()

func _process(delta):
	if debug_label:
		update_debug()

func update_rate_timeout():
	server_can_update = true

# Add player to the list and send a signal.
func _player_connected(id):
	player_ids.append(id)
	emit_signal("player_list_changed", player_ids)

# Removes a player from the list and sends a signal
func _player_disconnected(id):
	player_ids.erase(id)
	custom_player_data.erase(str(id))
	emit_signal("player_list_changed", player_ids)
	emit_signal("player_data_changed")

# Client connects and adds it's own ID to the list. The server ID will be added
# with _player_connected.
func _connected_ok():
	player_ids.append(get_tree().get_network_unique_id())
	sync_with_server_time()
	var latency_timer = Timer.new()
	latency_timer.wait_time = 0.5
	latency_timer.autostart = true
	latency_timer.connect("timeout", self, "calculate_latency")
	
	var sync_timer = Timer.new()
	sync_timer.autostart = true
	sync_timer.wait_time = 2.5
	sync_timer.connect("timeout", self, "sync_with_server_time")
	add_child(sync_timer)
	
	self.add_child(latency_timer)
	
	emit_signal("connection_succeeded")

# Failed to connect.
func _connected_fail():
	emit_signal("connection_failed")

# Callback from SceneTree, only for clients (not server).
func _server_disconnected():
	emit_signal("disconnected")

remotesync func register_player_data(data: Dictionary):
	custom_player_data[str(get_tree().get_rpc_sender_id())] = data
	emit_signal("player_data_changed")

# Gets the device global IP from a web API.
func set_my_global_ip(_result, _response_code, _headers, body):
	my_global_ip = body.get_string_from_utf8()
	print(my_global_ip)
	emit_signal("global_ip_found")

func get_local_ip() -> String:
	for x in IP.get_local_addresses():
		if x.left(3) == "192":
			return x
	return ""

func start_server(port: int = DEFAULT_PORT, max_players: int = MAX_PLAYERS):
	if network: # Close network if one has been created
		network.close_connection()
	
	network = NetworkedMultiplayerENet.new()
	network.compression_mode = NetworkedMultiplayerENet.COMPRESS_ZLIB
	network.create_server(port, max_players)
	get_tree().set_network_peer(network)
	player_ids.append(1)

func start_client(address: String = "127.0.0.1", port: int = DEFAULT_PORT):
	if network: # Close network if one has been created
		network.close_connection()
	
	network = NetworkedMultiplayerENet.new()
	network.compression_mode = NetworkedMultiplayerENet.COMPRESS_ZLIB
	network.create_client(address, port)
	get_tree().set_network_peer(network)

# Exits the network and resets all multiplayer data.
func exit():
	network.close_connection()
	get_tree().set_network_peer(null)
	network = null
	player_ids = []
	custom_player_data = {}

func create_players(player_object: PackedScene, their_parent: Node) -> Array:
	var player_array = []
	
	for id in player_ids:
		var new_player = player_object.instance()
		new_player.set_network_master(id)
		new_player.name = str(id)
		their_parent.add_child(new_player)
		player_array.append(new_player)
	
	return player_array

func show_debug() -> void:
	for child in get_children():
		if child.name == "DebugLayer":
			child.queue_free()
			debug_label = null
			return
	
	var canvas = CanvasLayer.new()
	canvas.name = "DebugLayer"
	debug_label = Label.new()
	
	canvas.add_child(debug_label)
	add_child(canvas)

func update_debug():
	var text = ""
	text += str("Latency to server: ", latency, "\n")
	text += str("Server time difference: ", server_time_difference, "\n")
	text += str("Player Ids: ", player_ids, "\n")
	text += str("Custom player data: ", custom_player_data, "\n")
	
	debug_label.text = text

################################################################################
# Sync Functions

func sync_with_server_time():
	rpc_id(1, "get_server_time", OS.get_system_time_msecs())

remote func get_server_time(client_time: int):
	var id = get_tree().get_rpc_sender_id()
	rpc_id(id, "return_server_time", OS.get_system_time_msecs(), client_time)

remote func return_server_time(server_time: int, client_time: int):
	latency = (OS.get_system_time_msecs() - client_time) / 2
	client_clock = server_time + latency
	server_time_difference = server_time - client_time - latency

# Sends current time to the server to calculate latency.
func calculate_latency():
	rpc_id(1, "server_calculate_latency", OS.get_system_time_msecs())

# Server returns the time sent so client can calculate latency.
remote func server_calculate_latency(client_time: int):
	var id = get_tree().get_rpc_sender_id()
	rpc_id(id, "return_server_latency", client_time)

# The client receives the time back that they sent to calculate the latency.
remote func return_server_latency(client_time: int):
	latency_array.append((OS.get_system_time_msecs() - client_time) / 2)
	if latency_array.size() == 9:
		var total_latency = 0
		latency_array.sort()
		var mid_point = latency_array[4]
		for i in range(latency_array.size() - 1, -1, -1):
			if latency_array[i] > (2 * mid_point) and latency_array[i] > 20:
				latency_array.remove(i)
			else:
				total_latency += latency_array[i]
		delta_latency = (total_latency / latency_array.size()) - latency
		latency = total_latency / latency_array.size()
		print("LATENCY: ", latency)
		latency_array.clear()

remotesync func start_game(scene_path: String):
	get_tree().change_scene(scene_path)

# Sends the state of an object and its name to the server. If the server is
# calling this, then the server state dictionary is updated or added to.
func send_state(state: State, object_name: String):
	if !get_tree().is_network_server():
		rpc_unreliable_id(1, "process_state", state.to_array(), object_name)
	else:
		server_local_states[object_name] = state

# Processes the state by checking if the object name is empty. If so, then the
# sender id is used for processing. This is called only on the server so that
# the server can build dictionaries of all of the object states. Old timestamps
# are discarded.
remote func process_state(state_array: Array, object_name: String = ""):
	var new_state: State = State.to_instance(state_array)
	var sender_id = str(get_tree().get_rpc_sender_id())
	
	#print("Sent by: ", sender_id, " obj name: ", object_name, " Staet: ", new_state.to_string())
	if object_name.empty():
		if server_received_states.has(sender_id):
	# Check if new character state is fresh
			check_timestamps(new_state, sender_id)
		else:
			server_received_states[sender_id] = new_state
	elif server_received_states.has(object_name):
		# Check if new character state is fresh
		check_timestamps(new_state, sender_id)
	else:
		server_received_states[object_name] = new_state

# Adds the state at the given name if its timestamp is more recent.
func check_timestamps(new_state: State, added_name: String):
	if new_state.timestamp > server_received_states.get(added_name).timestamp:
		var old_state: State = server_received_states[added_name]
		server_received_states[added_name] = new_state
		emit_signal("object_state_changed", new_state, added_name)
		update_server_client_state(old_state, new_state, added_name)

func update_server_client_state(old_state: State, new_state: State, object_name: String):
	var object = get_tree().get_current_scene().find_node(object_name, true, false)
		
	# If the node exists and you are not its master, then sync.
	if object != null and !object.is_network_master():
		object.get_node("NetworkSyncer").interpolate_state(old_state, new_state)

# Sends the world state from the server to all of the clients. States are
# received from clients and added to dictionaries. Those dictionaries are then
# combined and sent to all clients to be updated locally.
func send_world_state():
	if !server_received_states.empty() or !server_local_states.empty():
		var states : Dictionary = {}
		
		# Add the server local states to the state dictionary.
		for object_name in server_local_states:
			var local_state_array = server_local_states[object_name].to_array()
			states[object_name] = local_state_array
			
		# Add the received states from other players to the state dictionary.
		for object_name in server_received_states:
			var local_state_array = server_received_states[object_name].to_array()
			states[object_name] = local_state_array
		
		# Send the world state
		var world_state: Array = []
		world_state.append(OS.get_system_time_msecs())
		world_state.append(states)
		
		# Broadcasts the states to every client.
		rpc_unreliable_id(0, "update_world_state", world_state)

# Checks if the world state is newer than the last received state, if so, then
# add the state to the world state buffer for processing.
puppet func update_world_state(new_world_state : Array):
	if new_world_state[0] > last_world_state_timestamp and !get_tree().is_network_server():
		last_world_state_timestamp = new_world_state[0]
		world_state_buffer.append(new_world_state)

# This is called on clients only. Processes the world state by calculating the 
# interpolation ratio.
func process_world_state():
	var render_time = OS.get_system_time_msecs() + server_time_difference + latency - 100
	if world_state_buffer.size() > 1:
		while world_state_buffer.size() > 2 and render_time > world_state_buffer[1][0]:
			world_state_buffer.remove(0)
		var interp_ratio = float(render_time - world_state_buffer[0][0]) / float(world_state_buffer[1][0] - world_state_buffer[0][0])
		#print(interp_ratio)
		#interp_ratio = clamp(interp_ratio, 0, 1)
		var old_world_state: Array = world_state_buffer[0]
		var new_world_state: Array = world_state_buffer[1]
		world_state_changed(old_world_state, new_world_state, interp_ratio)

# Receives the state from the process and sends the interpolation information
# to the object if it is found in the root node.
# TODO: Refactor to save nodepaths instead of finding the node every time.
func world_state_changed(old_world_state: Array, new_world_state: Array, interp_ratio: float):
	for object_name in new_world_state[1].keys():
		var object = get_tree().get_current_scene().find_node(object_name, true, false)
		
		# If the node exists and you are not it's master, then sync.
		if object != null and !object.is_network_master():
			var old_state = Networking.State.to_instance(old_world_state[1][object_name])
			var new_state = Networking.State.to_instance(new_world_state[1][object_name])
			if new_state != null:
				object.get_node("NetworkSyncer").interpolate_state(old_state, new_state, interp_ratio)

################################################################################
# Custom Classes

# Long Bool is used to send object/character state data efficiently over a network.
# The data format used is an integer, and each individual bit is set and get 
# individually as if they are a boolean.
#
# This can be used to send input commands (forward = true, etc.) or other frame
# variables like shot = true. An enum is recommended to fill a longbool to provide
# a nice interface as opposed to setting and remembering indexes manually.
#
# Valid indexes for longbool are 0-63. Out of bound indexes will not be recorded.
class LongBool:
	var data: int
	
	func _init(new_data: int = 0):
		data = new_data
	
	func get_data() -> int:
		return data
	
	func set_data(new_data: int) -> void:
		data = new_data
	
	func clear_data() -> void:
		data = 0
	
	func get_array() -> Array:
		var array = []
		for index in 63:
			if get_value(index):
				array.append(1)
			else:
				array.append(0)
		return array
	
	func print_bool() -> void:
		print(get_array())
	
	func get_value(index : int) -> bool:
		return data & (1 << index) != 0
	
	func set_value(index: int, value: bool) -> void:
		if value:
			data = enable_index(index)
		else:
			data = disable_index(index)
	
	func enable_index(index : int) -> int:
		return data | 1 << index
	
	func disable_index(index : int) -> int:
		return data & ~(1 << index)


# State is used to send an object/character state over a network from a client
# to a server, and from a server back to every client.
#
# State provides two custom variables for holding any data individualized for
# each different object and a generic int timestamp for interpolation purposes.
class State:
	var custom_data: Array
	var custom_bools: int
	var timestamp: int
	
	func _init(_custom_data: Array, _long_bool_int: int, _timestamp: int):
		custom_data = _custom_data
		custom_bools = _long_bool_int
		timestamp = _timestamp
	
	func to_array() -> Array:
		return [custom_data, custom_bools, timestamp]
	
	static func to_instance(array : Array) -> State:
		return State.new(array[0], array[1], array[2])
