@tool
class_name FirstPersonViewPitch
extends SkeletonModifier3D

## Fits the first-person body to the view. The first-person clips pose the
## arms for a spine bent back under the eye (mtidle.kf: Spine1 23, Spine2 26
## degrees from rest) and the whole skeleton turned with the view. This keeps
## that framing for the arms and neck while the body below stands straight:
## 1. each bone in `bones` (and everything below it) takes its world pose from
##    the animated pose, spine bend included, turned by `pitch` about the pivot
##    bone (the eye), around `axis`;
## 2. each bone in `straightened_bones` is put back to its rest pose.
## The pelvis and legs keep their pose and the skin between the straight spine
## and the shoulders stretches. FirstPersonRig adds it to its skeleton and sets
## `pitch` and `axis` each frame. As a SkeletonModifier3D it applies after
## KfAnimator writes the pose and is undone by Skeleton3D after rendering, so it
## never accumulates.

## The bones that keep the clips' framing and turn with the view: the roots of
## the arm chains and the neck.
@export var bones := PackedStringArray(["Bip01 L Clavicle", "Bip01 R Clavicle", "Bip01 Neck"])
## The bones put back to their rest pose under them: the spine, which the
## first-person clips bend back.
@export var straightened_bones := PackedStringArray(["Bip01 Spine", "Bip01 Spine1", "Bip01 Spine2"])
## The bone whose position the bones turn about: the eye.
@export var pivot_bone := "Camera1st"
## The view's pitch, radians, up positive.
var pitch := 0.0
## The axis of the pitch in the skeleton's space (the view's right).
var axis := Vector3.RIGHT


func _process_modification_with_delta(_delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	var pivot := skeleton.find_bone(pivot_bone)
	if pivot == -1:
		return
	var centre := skeleton.get_bone_global_pose(pivot).origin
	var turn := Basis(axis.normalized(), pitch)
	var about_pivot := Transform3D(turn, centre - turn * centre)
	# Every world pose is read from the animated pose before anything is set.
	var framed := {}
	for bone_name in bones:
		var bone := skeleton.find_bone(bone_name)
		if bone != -1:
			framed[bone] = about_pivot * skeleton.get_bone_global_pose(bone)
	for bone_name in straightened_bones:
		var bone := skeleton.find_bone(bone_name)
		if bone != -1:
			skeleton.set_bone_pose(bone, skeleton.get_bone_rest(bone))
	# Parents first (a parent's index is below its children's): setting a
	# parent after its child would move the child again.
	var order: Array = framed.keys()
	order.sort()
	for bone: int in order:
		skeleton.set_bone_global_pose(bone, framed[bone])
