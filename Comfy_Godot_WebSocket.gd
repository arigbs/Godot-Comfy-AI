extends Node

var server_address := "127.0.0.1:8188"
var client_id := str(randi())
var socket := WebSocketPeer.new()
var socket_state
var last_socket_state := WebSocketPeer.STATE_CLOSED
var prompt_id := ""
var comfy_workflow := "res://basic_comfy_workflow_api.json"
var workflow_json_data: String
var workflow_json: Dictionary
@onready var image_display: TextureRect = %ImageDisplay_TextureRect
@onready var positive_prompt_input: LineEdit = %PositivePrompt_Input
@onready var negative_prompt_input: LineEdit = %NegativePrompt_Input
@onready var seed_input: SpinBox = %Seed_SpinBox
@onready var console_output: Label = %Console_Label


func _ready():
	# Load the workflow JSON from file
	var workflow_json_file = FileAccess.open(comfy_workflow, FileAccess.READ)
	if workflow_json_file != null:
		workflow_json_data = workflow_json_file.get_as_text()
		workflow_json_file.close()
		
		var json = JSON.new()
		var error = json.parse(workflow_json_data)
		if error == OK:
			workflow_json = json.data
		else:
			print("Failed to parse JSON with error: ", json.get_error_message())
	else:
		print("Failed to open file")

func wait_for_parsed_data():
	print("Waiting for execution")
	while true:		
		socket.poll()
		if socket.get_available_packet_count() > 0:
			var packet := socket.get_packet().get_string_from_utf8()			
			if packet.begins_with("{"):				
				var message
				var json = JSON.new()
				var result = json.parse(packet)
				if result == OK:
					message = json.data		
					print("Message Received: ", message)			
		#		if message["type"] == "executing" and message["data"]["node"] == null and message["data"]["prompt_id"] == prompt_id:
				if message["type"] == "progress" and message["data"]["value"] == message["data"]["max"]:
					# Execution is done
				#	print("Message Received: ", message)
					print("Execution completed for prompt_id: %s" % prompt_id)
					return true
		# Yield the function execution until the next frame
		await get_tree().process_frame
		
func queue_prompt(prompt):
	var body_data = {
		"prompt": prompt
	}
	var body = JSON.stringify(body_data)
	var headers = PackedStringArray(["Content-Type: application/json"])
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.connect("request_completed", _on_prompt_queued)
	http_request.request("http://%s/prompt" % server_address, headers, HTTPClient.METHOD_POST, body)

func _on_prompt_queued(result, response_code, headers, body):
	print("_on_prompt_queued Response Code: ", str(response_code))
	if response_code == 200:
		var json_response
		var json = JSON.new()
		var parsed_data = json.parse(body.get_string_from_utf8())		
		if parsed_data == OK:
			json_response = json.data
			print("Json_Response: " + str(json_response))
		prompt_id = json_response["prompt_id"]
		console_output.text = "PROMPT IS QUEUED: " + prompt_id
		print("PROMPT IS QUEUED: ", prompt_id)
	else:
		print("Failed to queue prompt. Response code: ", response_code)

func get_history(_prompt_id):	
	var http_request := HTTPRequest.new()
	add_child(http_request)
	print("Sending request to get history for prompt_id: ", _prompt_id)
	http_request.connect("request_completed", _on_history_received)
	var url = "http://" + server_address + "/history/" + str(_prompt_id)
	http_request.request(url)
#	http_request.request(server_address.replace("ws", "http") + "/history/" + str(prompt_id))

func _on_history_received(result, response_code, headers, body):
	print("Response body: ", body.get_string_from_utf8())
	print("Result: ", result)
	print("Response code: ", response_code)
	print("Headers: ", headers)
	print("Body: ", body.get_string_from_utf8())
	if response_code == 200:
		var json = JSON.new()
		var parse_error = json.parse(body.get_string_from_utf8())
		if parse_error == OK:
			var json_response = json.data
			print("Parsed JSON data: ", str(json_response))
			if json_response.has(prompt_id):
				print("THIS IS THE PROMPT ID: ", prompt_id)
				var history = json_response[prompt_id]
				print("History: ", history)
				var output_images := {}
				for node_id in history["outputs"]:
					var node_output = history["outputs"][node_id]
					if "images" in node_output:
						var images_output := []
						for image in node_output["images"]:
							var image_data = await get_image(image["filename"], image["subfolder"], image["type"])
							images_output.append(image_data)
						output_images[node_id] = images_output
						print("Output Images", output_images)
		else:
			print("Failed to parse JSON data. Error code: ", parse_error)
	else:
		print("Failed to get history. Response code: ", response_code)

func get_image(filename, subfolder, folder_type):
	var url_values := "filename=%s&subfolder=%s&type=%s" % [filename, subfolder, folder_type]
	var http_request := HTTPRequest.new()
	add_child(http_request)
	http_request.connect("request_completed", Callable(self, "_on_image_request_completed").bind(http_request))
	#http_request.request(server_address.replace("ws", "http") + "/view?" + url_values)
	var url = "http://%s/view?%s" % [server_address, url_values]
	var error = http_request.request(url)
	if error != OK:
		print("Failed to send image request. Error code: ", error)
		return null
	var image_data = await http_request.request_completed
	return image_data	

func _on_image_request_completed(result, response_code, headers, body, http_request):
	if response_code == 200:
		var image_data = body		
		print("Image Data: ", image_data)
		process_output_images(image_data)
		http_request.queue_free()
	else:
		print("Failed to get image. Response code: ", response_code)
		http_request.queue_free()
		
		
func process_output_images(image_data):
	if image_data is PackedByteArray:
		print("Image data: ", image_data)
		var image := Image.new()
		var image_error := image.load_png_from_buffer(image_data)
		if image_error == OK:
			var texture := ImageTexture.create_from_image(image)
			print("image_display is in the scene tree: ", image_display.is_inside_tree())
			print("image_display is visible: ", image_display.is_visible())
			print("image_display class: ", image_display.get_class())
			image_display.texture = texture
		else:
			print("Failed to load image. Error code: ", image_error)
	elif image_data is Dictionary:
		for node_id in image_data:
			for image_bytes in image_data[node_id]:
				print("Image data: ", image_bytes)
				var image := Image.new()
				var image_error := image.load_png_from_buffer(image_bytes)
				if image_error == OK:
					var texture := ImageTexture.create_from_image(image)
					print("image_display is in the scene tree: ", image_display.is_inside_tree())
					print("image_display is visible: ", image_display.is_visible())
					print("image_display class: ", image_display.get_class())
					image_display.texture = texture
				else:
					print("Failed to load image. Error code: ", image_error)
		
func _on_connect_comfy_server_button_down() -> void:	
	socket.poll()
	if socket_state != WebSocketPeer.STATE_OPEN or socket_state != WebSocketPeer.STATE_CONNECTING:
		# Connect to the WebSocket server
		var websocket_url := "ws://127.0.0.1:8188/ws?clientId=%s" % client_id			
		await socket.connect_to_url(websocket_url)
		check_socket_state()
		console_output.text = "Connected to WebSocket server: " + str(socket.get_connected_host()) + ":" + str(socket.get_connected_port()) + " SocketState: " + str(socket_state)
		print("Connected to WebSocket server: ", socket.get_connected_host() + ":" + str(socket.get_connected_port()))
		print("Successful Connection State: ", socket_state)		
	else:
		console_output.text = "Socket not open. Current Socket State: " + socket_state
		print("Socket not open. Current Socket State: ", socket_state)
	

func wait_for_socket_close():
	while socket_state != WebSocketPeer.STATE_CLOSED:
		socket.poll()
		socket_state = socket.get_ready_state()
		await get_tree().process_frame
		
		
func make_image():
	# Modify the workflow JSON as needed
	workflow_json["6"]["inputs"]["text"] = positive_prompt_input.text
	workflow_json["7"]["inputs"]["text"] = negative_prompt_input.text
	workflow_json["3"]["inputs"]["seed"] = seed_input.value     #randi() % 9999999999
	
	socket.poll()

	if socket_state == WebSocketPeer.STATE_OPEN:
		# Connection is established, send the workflow JSON data
		queue_prompt(workflow_json)
		print("Sent workflow JSON data.")
	else:
		print("WebSocket connection is not open.", str(socket_state))	
	check_socket_state()		
	# Add a delay before retrieving the history
	await get_tree().create_timer(2.0).timeout  # Adjust the delay as needed
	# Wait for the data parsing to complete using await
	var result = await wait_for_parsed_data()
	if result:
		# data parsing is done, get the history
		get_history(prompt_id)

func check_socket_state() -> void:
	## Check the connection state
	socket_state = socket.get_ready_state()
	match socket_state:
		WebSocketPeer.STATE_OPEN:
			console_output.text = "WebSocket connection established."
			print("WebSocket connection established.")
		WebSocketPeer.STATE_CONNECTING:
			console_output.text = "WebSocket connection is in the process of connecting."
			print("WebSocket connection is in the process of connecting.")
		WebSocketPeer.STATE_CLOSING:
			console_output.text = "WebSocket connection is in the process of closing."
			print("WebSocket connection is in the process of closing.")
		WebSocketPeer.STATE_CLOSED:
			console_output.text = "WebSocket connection is closed."
			print("WebSocket connection is closed.")
	
	print("Current Socket State: ", socket_state)

func _on_make_image_button_down() -> void:
	make_image()

func _on_socket_state_check_button_down() -> void:
	check_socket_state()
