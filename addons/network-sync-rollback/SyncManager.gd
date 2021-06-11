extends Node
class_name SyncManager

class Peer extends Reference:
	var peer_id: int
	
	var rtt: int
	var last_ping_received: int
	var time_delta: float
	
	var last_remote_tick_received: int
	var next_local_tick_requested: int
	
	var remote_lag: int
	var local_lag: int
	
	var calculated_advantage: float
	var advantage_list := []
	
	func _init(_peer_id: int) -> void:
		peer_id = _peer_id
	
	func record_advantage(ticks_to_calculate_advantage: int) -> void:
		advantage_list.append(local_lag - remote_lag)
		if advantage_list.size() >= ticks_to_calculate_advantage:
			var total: float = 0
			for x in advantage_list:
				total += x
			calculated_advantage = total / advantage_list.size()
			advantage_list.clear()
	
	func clear_advantage() -> void:
		calculated_advantage = 0.0
		advantage_list.clear()

class InputForPlayer:
	var input := {}
	var predicted: bool
	
	func _init(_input: Dictionary, _predicted: bool) -> void:
		input = _input
		predicted = _predicted

class InputBufferFrame:
	var players := {}
	
	func is_complete(peers: Dictionary) -> bool:
		for peer_id in peers:
			if not players.has(peer_id) or players[peer_id].predicted:
				return false
		return true

var peers := {}
var input_buffer := []
var state_buffer := []

var max_state_count := 20
var ticks_to_calculate_advantage := 60

# In seconds, because we don't want it to be dependent on the network tick.
var ping_frequency := 1.0 setget set_ping_frequency

var current_tick: int = 0
var current_input_index: int = -1
var skip_ticks: int = 0
var rollback_ticks: int = 0
var started := false

var ping_timer: Timer

signal sync_started ()
signal sync_stopped ()
signal peer_pinged_back (peer)

func _ready() -> void:
	ping_timer = Timer.new()
	ping_timer.wait_time = ping_frequency
	ping_timer.autostart = true
	ping_timer.one_shot = false
	ping_timer.connect("timeout", self, "_on_ping_timer_timeout")
	add_child(ping_timer)

func set_ping_frequency(_ping_frequency) -> void:
	ping_frequency = _ping_frequency
	if ping_timer:
		ping_timer.wait_time = _ping_frequency

func add_peer(peer_id: int) -> void:
	assert(not peers.has(peer_id))
	
	if peers.has(peer_id):
		return
	peers[peer_id] = Peer.new(peer_id)

func _on_ping_timer_timeout() -> void:
	var system_time = OS.get_system_time_msecs()
	for peer_id in peers:
		var msg = {
			local_time = system_time,
		}
		rpc_id(peer_id, "_remote_ping", msg)

remote func _remote_ping(msg: Dictionary) -> void:
	msg['remote_time'] = OS.get_system_time_msecs()
	rpc_id(get_tree().get_rpc_sender_id(), "_remote_ping_back", msg)

remote func _remote_ping_back(msg: Dictionary) -> void:
	var system_time = OS.get_system_time_msecs()
	var peer_id = get_tree().get_rpc_sender_id()
	var peer = peers[peer_id]
	peer.last_ping_received = system_time
	peer.rtt = system_time - msg['local_time']
	peer.time_delta = msg['remote_time'] - msg['local_time'] - (peer.rtt / 2.0)
	emit_signal("peer_pinged_back", peer)

func start() -> void:
	assert(get_tree().is_network_server())
	if get_tree().is_network_server():
		# @todo Use latency information to time when we do our local start.
		rpc("_remote_start")

remotesync func _remote_start() -> void:
	started = true
	emit_signal("sync_started")

func stop() -> void:
	if get_tree().is_network_server():
		# @todo Use latency information to time when we do our local start.
		rpc("_remote_stop")
	else:
		_remote_stop()

remotesync func _remote_stop() -> void:
	started = false
	current_tick = 0
	skip_ticks = 0
	input_buffer.clear()
	state_buffer.clear()

func _call_network_process(delta: float, input_frame: InputBufferFrame) -> void:
	var nodes: Array = get_tree().get_nodes_in_group('network_sync')
	var i = nodes.size()
	while i > 0:
		i -= 1
		var node = nodes[i]
		if node.has_method('_network_process'):
			# @todo should we be passing in the input frame instead?
			node._network_process(delta, input_frame, self)

func _call_save_state() -> Dictionary:
	var state := {}
	var nodes: Array = get_tree().get_nodes_in_group('network_sync')
	for node in nodes:
		if node.has_method('_save_state'):
			state[str(node.get_path())] = node._save_state()
	return state

func _call_load_state(state: Dictionary) -> void:
	for node_path in state:
		if has_node(node_path):
			var node = get_node(node_path)
			if node.has_methode('_load_state'):
				node._load_state(state[node_path])

func _do_tick(delta: float) -> void:
	var input_frame = input_buffer[current_input_index]
	var previous_input_index = current_input_index - 1
	var previous_frame = input_buffer[previous_input_index] if abs(previous_input_index) <= input_buffer.size() else null
	for peer_id in peers:
		if not input_frame.players.has(peer_id) or input_frame.players[peer_id].predicted:
			var predicted_input := {}
			if previous_frame:
				predicted_input = _predict_input(previous_frame.players[peer_id].input)
			input_frame.players[peer_id] = InputForPlayer.new(predicted_input, true)
	
	_call_network_process(delta, input_frame)
	var new_state = _call_save_state()
	#print (new_state)
	state_buffer.append(new_state)
	while state_buffer.size() > max_state_count:
		state_buffer.pop_front()

func _gather_local_input(player_index: int) -> Dictionary:
	return {}

func _predict_input(previous_input: Dictionary) -> Dictionary:
	return previous_input.duplicate()

func _physics_process(delta: float) -> void:
	if not started:
		return
	
	if rollback_ticks > 0:
		# Rollback our internal state.
		_call_load_state(state_buffer[-rollback_ticks - 1])
		state_buffer.resize(state_buffer.size() - rollback_ticks)
		# @todo: Do we really want to remove the future input?
		#input_buffer.resize(input_buffer.size() - rollback_ticks)
		current_tick -= rollback_ticks
		current_input_index = -1 - rollback_ticks
		
		# Iterate forward until we're at the same spot we left off.
		#while rollback_ticks < 0:
		#	_do_tick(delta)
		#	rollback_ticks -= 1
		#	current_tick += 1
		#   current_input_index += 1
	
	if skip_ticks > 0:
		skip_ticks -= 1
		if skip_ticks == 0:
			for peer in peers.values():
				peer.clear_advantage()
		else:
			return
	
	var max_advantage: float
	for peer_id in peers:
		var peer = peers[peer_id]
		# Number of frames we are predicting for this peer.
		peer.local_lag = (current_tick + 1) - peer.last_remote_tick_received
		# Calculate the advantage the peer has over us.
		peer.record_advantage(ticks_to_calculate_advantage)
		# Attempt to find the greatest advantage.
		max_advantage = max(max_advantage, peer.calculated_advantage)
		
	if max_advantage >= 2.0 and skip_ticks == 0:
		skip_ticks = int(max_advantage / 2)
		return
	
	current_tick += 1
	
	var local_input = _gather_local_input(1)
	
	for peer_id in peers:
		var peer = peers[peer_id]
		var msg = {
			tick = current_tick,
			next_tick_requested = peer.last_remote_tick_received + 1,
			input = local_input,
		}
		# @todo Put local input into message
		# @todo Convert this to rpc_unreliable_id() by including multiple sets
		#       of input back to the peer.next_local_tick_requested
		rpc_id(peer_id, "receive_tick", msg)
	
	var input_frame = InputBufferFrame.new()
	input_frame.players[get_tree().get_network_unique_id()] = InputForPlayer.new(local_input, false)
	input_buffer.append(input_frame)
	while input_buffer.size() > max_state_count:
		var retired_input_frame = input_buffer.pop_front()
		#if not retired_input_frame.is_complete(peers):
		#	# @todo Yell loudly that things are broken!
		#	stop()
		#	return
			
	_do_tick(delta)

remote func receive_tick(msg: Dictionary) -> void:
	if not started:
		return
	
	var peer_id = get_tree().get_rpc_sender_id()
	var peer = peers[peer_id]
	peer.last_remote_tick_received = msg['tick']
	peer.next_local_tick_requested = msg['next_tick_requested']
	
	# Number of frames the remote is predicting for us.
	peer.remote_lag = (peer.last_remote_tick_received + 1) - peer.next_local_tick_requested
	
	# @todo Integrate remote input into input buffer
	# @todo Check each subsequent prediction, and if it doesn't match, mark a
	#       rollback to that tick.
