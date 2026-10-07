@tool
class_name IdleBase
extends EsmBase

## IDLE (Idle Animation). Named by PACK idle lists and events, ACHR / ACRE
## Patrol Data INAM and PlayIdle, and arranged in a tree (ANAM) that IdleTree
## picks from. EsmBase holds EDID. Layout from xEdit's FNV definition; the
## Animation Group Section byte's bits from `Plans/Actors/census.md` A5.

## DATA byte 0, low six bits: the animation group section (0 Idle, 1 Movement,
## 7 Special Idle, 20 Whole Body, 21 Upper Body and others; census A5).
const SECTION_MASK := 0x3F
## DATA byte 0 bit 0x40: a loose idle, played by name outside the tree.
const SECTION_FLAG_LOOSE := 0x40
## DATA byte 0 bit 0x80: when clear, the idle must return a file, so the tree
## skips it when it has no KF (GECK "Idle Animations": Must Return File).
const SECTION_FLAG_NOT_MUST_RETURN_FILE := 0x80
## DATA Flags bit 0x01, No attacking (xEdit).
const FLAG_NO_ATTACKING := 0x01

@export_group("Animation")
## MODL: the KF, relative to meshes (`Characters\_Male\IdleAnims\X.kf`), or
## only a folder for an item that groups others (394 of 1,597 IDLE). Read; used
## by IdleTree (has_kf) and, through it, the animation of furniture use.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## CTDA: the conditions an actor must meet for this item, in authored order.
## Read; used by IdleTree.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ConditionSubrecord", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var conditions: Array[ConditionSubrecord] = []

@export_group("Tree")
## ANAM offset 0: the parent item, 0 at the top of the tree. Read; resolved
## into `parent`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var parent_form_id: int = 0
## Read from ANAM; used by IdleTree to find each item's children.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "IdleBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var parent: IdleBase
## ANAM offset 4: the previous sibling, 0 for the first child. Read; resolved
## into `previous`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var previous_form_id: int = 0
## Read from ANAM; used by IdleTree to order siblings.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "IdleBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var previous: IdleBase

@export_group("Data")
## DATA offset 0: Animation Group Section, with the bits above. Read; used by
## IdleTree (must_return_file).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var animation_group_section: int = 0
## DATA offset 1: Looping min, how many times the KF's StartLoop - EndLoop
## section plays at least; 255 (with max 255, on 85 IDLEs) loops forever.
## Read; used by ActorAnimator, which plays the section a random count between
## min and max (at least once; the count's meaning is inferred,
## Plans/Actors/stage_f.md).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var loop_minimum: int = 0
## DATA offset 2: Looping max, as loop_minimum. Read; used by ActorAnimator.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var loop_maximum: int = 0
## DATA offset 4: Replay Delay, seconds between replays (GECK); 0 on 1,556 of
## 1,597 IDLEs. Read; not used yet (idles picked from the tree, stage F step 5).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var replay_delay: int = 0
## DATA offset 6: Flags; absent from a short DATA. Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "No Attacking:1", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0

## Whether MODL names a KF rather than only a folder.
func has_kf() -> bool:
	return model_path.to_lower().ends_with(".kf")

## Whether the tree skips this item when it has no KF.
func must_return_file() -> bool:
	return (animation_group_section & SECTION_FLAG_NOT_MUST_RETURN_FILE) == 0
