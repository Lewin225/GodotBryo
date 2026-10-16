@tool
extends RefCounted
class_name NifMaterialContext

## What a material path receives for one shape: the shape's NifSource node, its
## textures by role, and the path's stock material.
##
## An override either adjusts default_material() or ignores it and returns a
## Material of its own. NifMaterialBuilder stamps the `nif_*` metadata onto
## whatever comes back, so an override never has to.

## The material path this shape was dispatched to (NifMaterialBuilder.PATH_*).
var path: StringName
## The shape's NifSource node dictionary: shader_type (the block), bs_shader_type,
## shader_flags1/2, texture_slots, texture_convention, alpha fields,
## shader_file_name and falloff. Shared with the parsed document; read only.
var node: Dictionary
## Whether the mesh carries per-vertex colour (ARRAY_COLOR).
var has_vertex_colors := false

var _textures := {}       # role -> ImageTexture, or null when not resolved
var _texture_paths := {}  # role -> authored path
var _default_builder: Callable


func _init(material_path: StringName, shape: Dictionary, vertex_colors: bool,
		textures: Dictionary, texture_paths: Dictionary, default_builder: Callable) -> void:
	path = material_path
	node = shape
	has_vertex_colors = vertex_colors
	_textures = textures
	_texture_paths = texture_paths
	_default_builder = default_builder


## The resolved texture for a role (NifMaterialBuilder.ROLE_*), or null when the
## shape has none in that role or it did not resolve.
func texture(role: StringName) -> Texture2D:
	return _textures.get(role)


## The authored path behind a role, or "" when the shape has none.
func texture_path(role: StringName) -> String:
	return String(_texture_paths.get(role, ""))


## The roles this shape has a texture path for, in slot order.
func roles() -> Array:
	return _texture_paths.keys()


## A new copy of the path's stock material, built as if no override existed.
func default_material() -> Material:
	return _default_builder.call(self)
