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
var previous_seed = null
var current_seed: int
var previous_prompt = null
var current_prompt
var previous_console_text = ""
var new_text_color: Color = Color(1, 0.5, 0) # Orange color

@onready var image_display: TextureRect = %ImageDisplay_TextureRect
@onready var positive_prompt_input: LineEdit = %PositivePrompt_Input
@onready var negative_prompt_input: LineEdit = %NegativePrompt_Input
@onready var seed_input: SpinBox = %Seed_SpinBox
@onready var console_output: Label = %Console_Label
@onready var connection_timer: Timer = %ConnectionTimer
@onready var data_parsing_timer: Timer = %DataParsingTimer
@onready var random_seed_toggle: CheckButton = %RandomSeedToggleButton


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

func _process(delta):
	if console_output.text != previous_console_text:
		previous_console_text = console_output.text
		modulate_text_color(console_output, Color(1, 0.5, 0), 3)

func wait_for_parsed_data():
	if socket_state == WebSocketPeer.STATE_OPEN:
		console_output.text = "Waiting for image generation"
	elif socket_state == WebSocketPeer.STATE_CLOSED:
		console_output.text = "WebSocket Not Open. Please Connect to ComfyUI Server"
		modulate_text_color(console_output, new_text_color, 3)
	print("Waiting for execution")	
#	var queue_remaining = -1
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
#					print("Message Received: ", message)	# Really helpful for debugging the nature of data ComfyUI sends back, but better commented out while not needed					
					print("Message Packet received")	
		#		if message["type"] == "executing" and message["data"]["node"] == null and message["data"]["prompt_id"] == prompt_id: # This did not work, the format did not fit that of message being received
				if message["type"] == "progress" and message["data"]["value"] == message["data"]["max"] or message["type"] == "status" and message["data"]["status"]["exec_info"]["queue_remaining"] == 0:
					# Execution is done
					console_output.text = "Image retrieved from sever"
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

func _on_history_received(result, response_code, headers, body):
	#print("Response body: ", body.get_string_from_utf8())
	#print("Result: ", result)
	#print("Response code: ", response_code)
	#print("Headers: ", headers)
	#print("Body: ", body.get_string_from_utf8())
	if response_code == 200:
		var json = JSON.new()
		var parse_error = json.parse(body.get_string_from_utf8())
		if parse_error == OK:
			var json_response = json.data
#			print("Parsed JSON data: ", str(json_response)) # Really helpful for confirming that the workflow JSON data is indeed parsed correctly, better commented out while not needed so console output is less verbose
			print("JSON data being parsed")
			if json_response.has(prompt_id):
				print("THIS IS THE PROMPT ID: ", prompt_id)
				var history = json_response[prompt_id]
#				print("History: ", history) # Really helpful for debugging returned history, which contains meta data on generated image(s). Better commented out while not needed so console output is less verbose
				print("History Received")
				var output_images := {}
				for node_id in history["outputs"]:
					var node_output = history["outputs"][node_id]
					if "images" in node_output:
						var images_output := []
						for image in node_output["images"]:
							var image_data = await get_image(image["filename"], image["subfolder"], image["type"])
							if image_data != null:
								images_output.append(image_data)
							else:
								print("Failed to retrieve image for prompt_id: %s" % prompt_id)
								# Handle the failure appropriately (e.g., display an error message, retry, etc.)
						output_images[node_id] = images_output
#						print("Output Images", output_images) #Helpful for confirming and seeing the output being returned for the image being retrieved and loaded in Godot. We can comment out when not needed so console output is less verbose.
						print("Output Images received successfully")
		else:
			print("Failed to parse JSON data. Error code: ", parse_error)
	else:
		print("Failed to get history. Response code: ", response_code)
		# Handle the failure appropriately (e.g., display an error message, retry, etc.)

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
#		print("Image Data: ", image_data) #Helpful for confirming and seeing the packed byte array being returned for the image being retrieved and loaded in Godot. We can comment out when not needed so console output is less verbose.
		console_output.text = "Image Data successfully retrieved. Loading new image"
		print("Image Data successfully retrieved. Image Request comleted.")
		process_output_images(image_data)
		http_request.queue_free()
	else:
		print("Failed to get image. Response code: ", response_code)
		http_request.queue_free()
		
		
func process_output_images(image_data):
	if image_data is PackedByteArray:
#		print("Image data: ", image_data) #Helpful for confirming and seeing the packed byte array being returned for the image being retrieved and loaded in Godot. We can comment out when not needed so console output is less verbose.
		print("Image Data is PackedByteArray.")
		var image := Image.new()
		var image_error := image.load_png_from_buffer(image_data)
		if image_error == OK:
			var texture := ImageTexture.create_from_image(image)
			image_display.texture = texture
			console_output.text = "Image Loading and Display Successfully Completed"
		else:
			console_output.text = "Failed to load image. Error code: " + str(image_error)
			print("Failed to load image. Error code: ", image_error)
	elif image_data is Dictionary:
		for node_id in image_data:
			for image_bytes in image_data[node_id]:
#				print("Image data: ", image_bytes) #Helpful for confirming and seeing the packed byte array being returned for the image being retrieved and loaded in Godot. We can comment out when not needed so console output is less verbose.
				var image := Image.new()
				var image_error := image.load_png_from_buffer(image_bytes)
				if image_error == OK:
					var texture := ImageTexture.create_from_image(image)
					image_display.texture = texture
					console_output.text = "Image Loading and Display Successfully Completed"
				else:
					console_output.text = "Failed to load image. Error code: " + str(image_error)
					print("Failed to load image. Error code: ", image_error)
		
func _on_connect_comfy_server_button_down() -> void:
	socket.poll()
	if socket_state != WebSocketPeer.STATE_OPEN and socket_state != WebSocketPeer.STATE_CONNECTING:
		# Close any existing connection
		if socket_state != WebSocketPeer.STATE_CLOSED:
			socket.close()
			await wait_for_socket_close()
		
		# Connect to the WebSocket server
		var websocket_url := "ws://127.0.0.1:8188/ws?clientId=%s" % client_id
		print("Attempting to connect to WebSocket server: ", websocket_url)
		var err = socket.connect_to_url(websocket_url)
		if err != OK:
			print("Unable to connect to WebSocket server. Error code: ", err)
			return
		
		# Start the connection timer
		connection_timer.start(10.0)  # Set the timeout duration to 10 seconds
		
		# Wait for the connection to be established or timeout
		while socket_state != WebSocketPeer.STATE_OPEN:
			socket.poll()
			socket_state = socket.get_ready_state()
			await get_tree().process_frame
			
			# Check if the timer has timed out
			if connection_timer.time_left == 0:
				print("Connection seems to have either failed or is taking too long. Please confirm the server is running and try again.")
				console_output.text = "Connection seems to have either failed or is taking too long. Please confirm the server is running and try again."
				socket.close()  # Close the socket if the connection times out
				return
		
		if socket_state == WebSocketPeer.STATE_OPEN:
			print("Connected to WebSocket server: ", socket.get_connected_host() + ":" + str(socket.get_connected_port()) + " SocketState: " + str(socket_state))
			console_output.text = "Connected to WebSocket server: " + str(socket.get_connected_host()) + ":" + str(socket.get_connected_port()) + " SocketState: " + str(socket_state)
			connection_timer.stop()  # Stop the timer if the connection is successful
		elif socket_state == WebSocketPeer.STATE_CLOSED:
			var socket_closed_reason = socket.get_close_reason()
			print("The Socket is Closed Because: " + socket_closed_reason)
	else:
		console_output.text = "Websocket is open. Current Socket State: " + str(socket_state)
		print("Websocket is open. Current Socket State: ", str(socket_state))

func wait_for_socket_close():
	while socket_state != WebSocketPeer.STATE_CLOSED:
		socket.poll()
		socket_state = socket.get_ready_state()
		await get_tree().process_frame

func _on_connection_timeout():
	print("Connection timeout reached. Please confirm the server is running and try again.")
	console_output.text = "Connection timeout reached. Please confirm the server is running and try again."
	socket.close()  # Close the socket if the connection times out

func make_image():
	prompt_id = ""
	console_output.text = "Generating new image..."	
	socket.poll()

	if socket_state == WebSocketPeer.STATE_OPEN:
		# Connection is established, send the workflow JSON data
		queue_prompt(current_prompt)
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
	else:
		# Execution completed but may have failed
		console_output.text = "Image generation failed for prompt_id: %s" % prompt_id
		print("Image generation failed for prompt_id: %s" % prompt_id)
		# Handle the failure appropriately (e.g., display an error message, retry, etc.)		

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
	current_prompt = null
	
	if random_seed_toggle.button_pressed:
		current_seed = randi_range(1, 10000000000)
		seed_input.value = current_seed
	else:
		current_seed = seed_input.value
		
	print("Current SEED: ", current_seed)

# 	Modify the workflow JSON as needed
	workflow_json["6"]["inputs"]["text"] = positive_prompt_input.text
	workflow_json["7"]["inputs"]["text"] = negative_prompt_input.text
	workflow_json["3"]["inputs"]["seed"] = current_seed
	
	current_prompt = workflow_json.duplicate(true) # Create a deep copy of workflow_json
	print("Current Prompt: ", current_prompt)
	print("Previous Prompt: ", previous_prompt)

	if current_prompt != previous_prompt:
		make_image()
	elif current_prompt == previous_prompt:
		console_output.text = "Repeated prompt / seed detected. Skipping generation. Change seed / prompt to get a new image."
		print("Repeated seed / prompt detected. Skipping generation.")
		return
	previous_prompt = current_prompt.duplicate(true)  # Create a deep copy of current_prompt	
	previous_seed = current_seed


func modulate_text_color(target_text: Label, _new_color: Color, wait_time: float)-> void:
	var original_text_color = Color(0.718, 0.718, 0.718, 0.694)
	if target_text.get_theme_color("font_color") != original_text_color:
		target_text.add_theme_color_override("font_color", original_text_color)	
	await get_tree().create_timer(wait_time).timeout
	target_text.add_theme_color_override("font_color", _new_color)
	await get_tree().create_timer(wait_time).timeout
	target_text.add_theme_color_override("font_color", original_text_color)
	

func _on_socket_state_check_button_down() -> void:
	check_socket_state()


