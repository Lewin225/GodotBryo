extends NVPing

func _ready() -> void:
	var response := ping()
	print("NVPing.ping() -> ", response)
	if response != "nv-engine-native-ok":
		print("FAILURES: 1")
		get_tree().quit(1)
		return
	print("ALL CHECKS PASSED")
	get_tree().quit(0)
