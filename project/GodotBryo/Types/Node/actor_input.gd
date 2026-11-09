class_name ActorInput
extends RefCounted

## One frame of what a controller asks its actor to do: the input packet a
## controller (PlayerController, NpcController) fills and hands to
## EsmActorNode.apply_input() every frame. Each bool is whether the input is
## held this frame; the actor acts on reload, draw and holster when they turn on
## and passes fire to its drawn weapon as the trigger.

## The trigger: held fires the drawn weapon (repeating when automatic); with
## nothing drawn, turning on draws the weapon drawn last.
var fire := false
## Turning on reloads the drawn weapon, or draws the weapon drawn last.
var reload := false
## Turning on draws the weapon drawn last.
var draw := false
## Turning on holsters the drawn weapon.
var holster := false
## The weapon slot to draw this frame (EsmActorNode.WEAPON_SLOTS_BY_INDEX), -1
## for none.
var equip_slot := -1
## Where the controller aims (Godot world): the player's camera ray's hit, or
## a far point along it; an NPC's target. Used while has_aim_point.
var aim_point := Vector3.ZERO
var has_aim_point := false
