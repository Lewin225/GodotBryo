class_name SaveFields
extends RefCounted

## Turns a resource's saved fields into plain values for a save file, and
## plain values back into a resource's fields. A saved field is a script
## property with PROPERTY_USAGE_STORAGE, the rule ResourceSaver uses.
##
## Values are written by the property's declared type, so a file read back
## with JSON.parse_string() (numbers all floats, keys all strings) is turned
## back into the right types from the property, never from the file:
## - an int named `*_form_id` is a record, written `<file>:<local id>` (null
##   for 0);
## - an EsmBase is its record, an EsmReference its instance_id;
## - any other Resource is a Dictionary of its own saved fields;
## - a Vector3 is [x, y, z];
## - a Dictionary's keys become strings and come back as its typed key type;
##   ActorValues' dictionaries are keyed by actor value name; a number in an
##   untyped value slot (a script local) is a float.
## The output holds no Object.

## Fields never written: the dirty flag is the save's reason to write a
## reference, not part of its state.
const ALWAYS_SKIPPED := ["dirty"]


## `resource`'s saved fields as plain values, leaving out `skipped` (an
## entry's key, such as a reference's instance_id).
static func write(resource: Resource, skipped: Array = []) -> Dictionary:
	var result := {}
	for property: Dictionary in resource.get_script().get_script_property_list():
		var name := String(property["name"])
		if not _is_saved(property) or skipped.has(name):
			continue
		result[name] = _write_value(resource.get(name), name, resource)
	return result


## Sets `resource`'s saved fields from `data`, as write() produced it and
## JSON.parse_string() returned it. A field `data` lacks keeps its value.
## Calls the resource's `_after_fields_read()` when it has one.
static func read(resource: Resource, data: Dictionary, skipped: Array = []) -> void:
	for property: Dictionary in resource.get_script().get_script_property_list():
		var name := String(property["name"])
		if not _is_saved(property) or skipped.has(name) or not data.has(name):
			continue
		resource.set(name, _read_value(data[name], property, resource))
	if resource.has_method("_after_fields_read"):
		resource.call("_after_fields_read")


## Whether `value` holds an Object anywhere, for checking write()'s output.
static func holds_object(value: Variant) -> bool:
	if value is Object:
		return true
	if value is Array:
		for item: Variant in value:
			if holds_object(item):
				return true
	if value is Dictionary:
		for key: Variant in value:
			if holds_object(key) or holds_object(value[key]):
				return true
	return false


static func _is_saved(property: Dictionary) -> bool:
	if (int(property["usage"]) & PROPERTY_USAGE_STORAGE) == 0:
		return false
	return not ALWAYS_SKIPPED.has(String(property["name"]))


static func _write_value(value: Variant, name: String, owner: Resource) -> Variant:
	if value is int and name.ends_with("_form_id"):
		return _record_text(value)
	if value is StringName:
		return String(value)
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is EsmBase:
		return _record_text((value as EsmBase).form_id)
	if value is EsmReference:
		return String((value as EsmReference).instance_id)
	if value is Resource:
		return write(value)
	if value is Dictionary:
		return _write_dictionary(value, owner)
	if value is Array:
		var items := []
		for item: Variant in value:
			items.append(_write_value(item, "", owner))
		return items
	if value is Object:
		push_error("SaveFields: %s.%s holds an Object that cannot be saved" % [owner.get_script().get_global_name(), name])
		return null
	return value


## A Dictionary with string keys. A number in an untyped value slot (a script
## local) is written as a float: JSON reads every number back as one, and the
## script interpreter uses locals as floats.
static func _write_dictionary(value: Dictionary, owner: Resource) -> Dictionary:
	var result := {}
	var untyped_values := value.get_typed_value_builtin() == TYPE_NIL
	for key: Variant in value:
		var text := str(key)
		if owner is ActorValues:
			text = String(ActorValue.NAMES[int(key)])
		var entry: Variant = value[key]
		if untyped_values and entry is int:
			entry = float(entry)
		result[text] = _write_value(entry, "", owner)
	return result


static func _read_value(value: Variant, property: Dictionary, owner: Resource) -> Variant:
	var name := String(property["name"])
	var type := int(property["type"])
	if type == TYPE_INT and name.ends_with("_form_id"):
		return _record_form_id(value)
	if value == null:
		return null if type == TYPE_OBJECT else owner.get(name)
	match type:
		TYPE_BOOL:
			return bool(value)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_STRING:
			return String(value)
		TYPE_STRING_NAME:
			return StringName(value)
		TYPE_VECTOR3:
			return Vector3(value[0], value[1], value[2])
		TYPE_OBJECT:
			return _read_object(value, _declared_class(property))
		TYPE_DICTIONARY:
			return _read_dictionary(value, owner.get(name), owner)
		TYPE_ARRAY:
			return _read_array(value, owner.get(name))
	return value


static func _read_object(value: Variant, class_title: String) -> Variant:
	var server := EsmReference.get_esm_server()
	if _inherits(class_title, "EsmBase"):
		return server.get_base(_record_form_id(value)) if server != null else null
	if _inherits(class_title, "EsmReference"):
		return server.get_reference(StringName(value)) if server != null else null
	var instance := _new_instance(class_title)
	if instance == null:
		push_error("SaveFields: no class %s to read a saved field into" % class_title)
		return null
	read(instance, value)
	return instance


## A new Dictionary typed as `current` is, holding `value`'s entries with their
## keys and values turned back into those types.
static func _read_dictionary(value: Dictionary, current: Dictionary, owner: Resource) -> Dictionary:
	var result := current.duplicate()
	result.clear()
	for text: String in value:
		var key: Variant = text
		if owner is ActorValues:
			key = ActorValue.from_name(text)
		elif current.get_typed_key_builtin() == TYPE_INT:
			key = int(text)
		result[key] = _read_plain(value[text], current.get_typed_value_builtin())
	return result


## A new Array typed as `current` is. An Array of Resources reads each entry
## into a new instance of its typed class.
static func _read_array(value: Array, current: Array) -> Array:
	var result := current.duplicate()
	result.clear()
	var item_script: Script = current.get_typed_script()
	for item: Variant in value:
		if item_script != null and item is Dictionary:
			var instance: Resource = item_script.new()
			read(instance, item)
			result.append(instance)
		else:
			result.append(_read_plain(item, current.get_typed_builtin()))
	return result


static func _read_plain(value: Variant, type: int) -> Variant:
	match type:
		TYPE_BOOL:
			return bool(value)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
	return value


## `<file>:<local id>` for a load-order FormID; null for 0.
static func _record_text(form_id: int) -> Variant:
	if form_id == 0:
		return null
	var server := EsmReference.get_esm_server()
	return String(server.instance_id_for_form_id(form_id)) if server != null else "%08X" % form_id


## The load-order FormID `<file>:<local id>` names; 0 for null.
static func _record_form_id(value: Variant) -> int:
	if value == null:
		return 0
	var server := EsmReference.get_esm_server()
	return server.form_id_for_instance_id(String(value)) if server != null else 0


static func _declared_class(property: Dictionary) -> String:
	var declared := String(property["class_name"])
	if declared.is_empty():
		declared = String(property["hint_string"])
	return declared


static func _inherits(class_title: String, ancestor: String) -> bool:
	var current := class_title
	while not current.is_empty():
		if current == ancestor:
			return true
		current = _global_class_base(current)
	return false


static func _global_class_base(class_title: String) -> String:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if String(entry["class"]) == class_title:
			return String(entry["base"])
	return ""


static func _new_instance(class_title: String) -> Resource:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if String(entry["class"]) == class_title:
			return (load(String(entry["path"])) as Script).new()
	return null
