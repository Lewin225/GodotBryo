class_name ActorAICodes
extends RefCounted

## The codes GetCurrentAIPackage and GetCurrentAIProcedure return, from the
## GECK's pages for them (`enginedocs/Geck/Packages/Commands/
## GetCurrentAIPackage - GECK.html`, `enginedocs/Geck/GetCurrentAIProcedure -
## GECK.html`, the latter written for Fallout 3). Which code applies is derived
## from what the actor is doing here; the mapping is inferred from the names
## (Plans/Completed Plans/Actors/stage_f.md).

## GetCurrentAIPackage codes.
const PACKAGE_DIALOGUE_RUNNING := 6
## PackageBase.PackageType -> GetCurrentAIPackage code, by name. FIND has no
## namesake (-1). DIALOGUE is the package type (34); 6, also DIALOGUE in the
## GECK's list, is an actor in dialogue (PACKAGE_DIALOGUE_RUNNING).
const PACKAGE_CODES := {
	PackageBase.PackageType.FOLLOW: 1,
	PackageBase.PackageType.ESCORT: 2,
	PackageBase.PackageType.EAT: 3,
	PackageBase.PackageType.SLEEP: 4,
	PackageBase.PackageType.WANDER: 13,
	PackageBase.PackageType.TRAVEL: 14,
	PackageBase.PackageType.ACCOMPANY: 15,
	PackageBase.PackageType.USE_ITEM_AT: 16,
	PackageBase.PackageType.AMBUSH: 17,
	PackageBase.PackageType.FLEE_NOT_COMBAT: 18,
	PackageBase.PackageType.CAST_MAGIC: 19,
	PackageBase.PackageType.USE_WEAPON: 33,
	PackageBase.PackageType.DIALOGUE: 34,
	PackageBase.PackageType.GUARD: 35,
	PackageBase.PackageType.SANDBOX: 36,
	PackageBase.PackageType.PATROL: 37,
}

## GetCurrentAIProcedure codes.
const PROCEDURE_TRAVEL := 0
const PROCEDURE_WAIT := 3
const PROCEDURE_DIALOGUE := 4
const PROCEDURE_GREET := 5
const PROCEDURE_DO_NOTHING := 24
const PROCEDURE_SITTING := 48
## PackageBase.PackageType -> the procedure it runs while working (moving, for
## Travel and Follow), by name. A package not listed waits.
const PROCEDURE_CODES := {
	PackageBase.PackageType.WANDER: 7,
	PackageBase.PackageType.SLEEP: 8,
	PackageBase.PackageType.EAT: 10,
	PackageBase.PackageType.FOLLOW: 11,
	PackageBase.PackageType.ESCORT: 12,
	PackageBase.PackageType.ACCOMPANY: 27,
	PackageBase.PackageType.USE_ITEM_AT: 28,
	PackageBase.PackageType.FLEE_NOT_COMBAT: 34,
	PackageBase.PackageType.PATROL: 41,
	PackageBase.PackageType.USE_WEAPON: 42,
	PackageBase.PackageType.GUARD: 44,
	PackageBase.PackageType.SANDBOX: 45,
}

## GetCurrentAIPackage: 6 while the actor says or hears a line or is in a
## conversation, else its active package's type's code; -1 with none.
static func package_code(actor: ActorReference) -> int:
	if actor == null:
		return -1
	if in_dialogue(actor):
		return PACKAGE_DIALOGUE_RUNNING
	if actor.active_package == null:
		return -1
	return int(PACKAGE_CODES.get(actor.active_package.package_type, -1))

## GetCurrentAIProcedure: DIALOGUE while the actor says or hears a line or is
## in a conversation; SITTING while it uses furniture; else from its active
## package: Travel travels while it has somewhere to go and waits once there
## (the GECK's own example), a Dialogue package greets until done, the others
## by name; DO_NOTHING with no package.
static func procedure_code(actor: ActorReference) -> int:
	if actor == null:
		return PROCEDURE_DO_NOTHING
	if in_dialogue(actor):
		return PROCEDURE_DIALOGUE
	if actor.sit_state != FurnitureSeating.NOT_SITTING:
		return PROCEDURE_SITTING
	var package := actor.active_package
	if package == null:
		return PROCEDURE_DO_NOTHING
	match package.package_type:
		PackageBase.PackageType.TRAVEL:
			return PROCEDURE_TRAVEL if actor.has_move_target else PROCEDURE_WAIT
		PackageBase.PackageType.DIALOGUE:
			return PROCEDURE_WAIT if actor.package_completed else PROCEDURE_GREET
	if actor.package_completed:
		return PROCEDURE_WAIT
	return int(PROCEDURE_CODES.get(package.package_type, PROCEDURE_WAIT))

## Whether `actor` is saying or hearing a line, or is in a conversation.
static func in_dialogue(actor: ActorReference) -> bool:
	if DialogueServer.get_line(actor) != null or DialogueServer.get_line_heard_by(actor) != null:
		return true
	return DialogueServer.get_conversation_speaker() == actor or DialogueServer.get_conversation_listener() == actor
