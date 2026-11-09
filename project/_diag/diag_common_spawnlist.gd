extends Node
## Spawn menu Common list: for candidate names per type, the records the
## catalog finds (EditorID, display name, picture), to choose the list from
## real data. Godot --headless --path . _diag/diag_common_spawnlist.tscn
const PROBES := [
	["WEAP", "9mm pistol"], ["WEAP", ".44 magnum"], ["WEAP", "varmint rifle"], ["WEAP", "service rifle"], ["WEAP", "hunting shotgun"],
	["WEAP", "laser rifle"], ["WEAP", "plasma rifle"], ["WEAP", "machete"], ["WEAP", "minigun"], ["WEAP", "fat man"],
	["ARMO", "leather armor"], ["ARMO", "combat armor"], ["ARMO", "t-51b"], ["ARMO", "vault 21 jumpsuit"],
	["ALCH", "stimpak"], ["ALCH", "radaway"], ["ALCH", "nuka-cola"], ["ALCH", "purified water"],
	["AMMO", "9mm round"], ["AMMO", ".44 magnum round"], ["AMMO", "5.56mm round"], ["AMMO", "microfusion cell"],
	["MISC", "bottle cap"], ["CMNY", "cap"], ["MISC", "scrap metal"],
	["CREA", "gecko"], ["CREA", "deathclaw"], ["CREA", "radscorpion"], ["CREA", "cazador"], ["CREA", "securitron"], ["CREA", "brahmin"],
	["FURN", "chair"], ["FURN", "bed"], ["CONT", "footlocker"], ["CONT", "ammo box"], ["ACTI", "workbench"], ["STAT", "crate"], ["STAT", "barrel"],
	["LIGH", "lamp"], ["TERM", "terminal"],
]
func _ready() -> void:
	var esm_server: Node = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var catalog := SpawnCatalog.new(esm_server.reader, esm_server.get_record_index(), get_node("/root/ArchiveServer"))
	for probe: Array in PROBES:
		catalog.rows_for_type(probe[0])
		var hits := catalog.search(probe[0], probe[1])
		var named := []
		for row: Dictionary in hits:
			if String(row["full_name"]).to_lower().begins_with(String(probe[1]).to_lower()):
				named.append(row)
		var shown := []
		for row: Dictionary in (named if not named.is_empty() else hits).slice(0, 4):
			var bare := String(row["shown_icon"]).is_empty() and String(row["shown_model"]).is_empty()
			shown.append("%s \"%s\"%s" % [row["editor_id"], row["full_name"], " (no picture)" if bare else ""])
		print("%s %-20s %d: %s" % [probe[0], probe[1], hits.size(), ", ".join(shown)])
	get_tree().quit()
