@tool
@icon("res://GodotBryo/Types/Node/item.svg")
class_name EsmWeaponNode
extends EsmItemNode

## A WEAP reference's world model: on the ground, held or holstered. The
## weapon's state (loaded ammo, jammed) is on its WeaponReference, so it
## survives this node. Works with no actor holding it.
## Plan: Plans/Weapons/weapons.md.

## NIF node the shot leaves from. Present on every pistol, automatic, rifle and
## launcher model.
const MUZZLE_NODE := "ProjectileNode"
## The muzzle's name on lasergatling.nif.
const MUZZLE_NODE_PARTED := "##ProjectileNode"
## NIF node spent shells leave from. Present on 32 of the 66 pistol, automatic
## and rifle models.
const SHELL_EJECTION_NODE := "ShellCasingNode"
## NIF node the sights line up on. Present on 47 of the 66 pistol, automatic
## and rifle models; on no launcher or non-gun.
const SIGHTING_NODE := "##SightingNode"

## The model's muzzle node; null before the model loads or when it has none.
var muzzle: Node3D
## The model's shell ejection node; null before the model loads or when it has
## none.
var shell_ejection: Node3D
## The model's sighting node; null before the model loads or when it has none.
var sighting: Node3D


## The reference as a WeaponReference; null when the node holds another type.
func get_weapon_reference() -> WeaponReference:
	return reference as WeaponReference


## The reference's WEAP base; null before the reference resolves.
func get_weapon_base() -> WeaponBase:
	if reference == null:
		return null
	return reference.base as WeaponBase


func _on_nif_visual_ready(tree: Node3D) -> void:
	super._on_nif_visual_ready(tree)
	muzzle = _find_nif_node(tree, MUZZLE_NODE)
	if muzzle == null:
		muzzle = _find_nif_node(tree, MUZZLE_NODE_PARTED)
	shell_ejection = _find_nif_node(tree, SHELL_EJECTION_NODE)
	sighting = _find_nif_node(tree, SIGHTING_NODE)


func _clear_generated_children() -> void:
	muzzle = null
	shell_ejection = null
	sighting = null
	super._clear_generated_children()


## The first Node3D under `tree` whose authored NIF name is `nif_name`. The
## anchors are not always direct children of the weapon node (the Minigun's
## ProjectileNode is under ##MinigunGun), so the whole tree is searched.
func _find_nif_node(tree: Node3D, nif_name: String) -> Node3D:
	for node: Node in tree.find_children("*", "Node3D", true, false):
		if String(node.get_meta(NifNames.META_NIF_NAME, "")) == nif_name:
			return node as Node3D
	return null
