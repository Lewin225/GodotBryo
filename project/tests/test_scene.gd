extends NVPing

func _ready() -> void:
	print("NVPing.ping() -> ", ping())
	get_tree().quit()
