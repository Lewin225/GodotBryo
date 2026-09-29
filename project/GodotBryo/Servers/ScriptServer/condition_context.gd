class_name ConditionContext
extends RefCounted

## Who a list of conditions is evaluated for: what Run On Subject and Target
## name, and whose linked reference Run On Linked Reference follows.

## The reference the conditions are about: a speaker, a package's actor, the
## actor using a terminal.
var subject: EsmReference = null
## The reference the subject addresses or acts on.
var target: EsmReference = null
## The reference whose XLKR Run On Linked Reference follows; the subject when
## null. A terminal's conditions follow the placed terminal's link.
var linked_from: EsmReference = null
## What owns the conditions, for warnings: "TERM Lucky38MrHouseTerminal05".
var owner_label: String = ""

func _init(subject_reference: EsmReference = null, target_reference: EsmReference = null) -> void:
	subject = subject_reference
	target = target_reference
