@tool
extends Node

## Central home for GodotBryo-specific tunables, starting with LOD range
## config. Values are editor-tunable (select the autoload node in the
## Inspector) and are the single source of truth consumed by
## WorldStreamer, CellLoader, GamebryoMeshResolver and DirectGeometryBatch.

@export_group("LOD")

## Distance (meters) where LOD0 (full detail) hands off to LOD1.
@export var lod0_crossover_distance_m: float = 100.0

## Fade-band width (meters) around the LOD0/LOD1 handoff. Shared by both
## edges (LOD0's end/end_margin and LOD1's begin/begin_margin) so the
## crossfade is seamless by construction.
@export var lod0_crossover_margin_m: float = 5.0

## Distance (meters) where LOD1 itself disappears. 0.0 = infinite (never
## disappears), matching Godot's own end==0.0 "unbounded" convention.
@export var lod1_max_range_m: float = 0.0

## Distance (meters) where persistent-cell distant/skyline LOD tiles
## (e.g. Strip wall, McCarran building blocks) fade IN as the camera
## moves away. There is no far bound - these tiles are meant to stay
## visible indefinitely, like terrain.
@export var distant_lod_near_cutoff_m: float = 300.0

## Fade-band width (meters) for the distant-tile near cutoff.
@export var distant_lod_near_margin_m: float = 20.0
