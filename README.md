**GodotByro is attempting to be a from scratch, drop in replacement for GameByro** 
*Targeting fallout new vegas (with fallout 3 and skyrim as future work)*

Why Godot? Lightweight, zero cost and easily modifiable though gdextension, source available , multi platform


**Current Status**
* Gameplay
  * Open world terrain rendering using Terrain3D sourced from LAND records, including the 7+1 layer terrain blending from gamebyro
  * Interior cell loading, Including fog, lighting and environment data
  * Script Engine (Currently very limited API support)
  * Proper cell transitions using DOOR Destination
 
* Some gameplay objects functional
  * DOOR + Anims and sounds
  * TERM - Pending proper ui, but parsing correctly
  * ACTI - Scripts attached fire correctly through the script engine
  * MISC, WEAP, ALCH - Moveable Jolt physics objects. Can be picked up into a placeholder inventory


* Internal
  * ESM Parsing, Form Data resolution into resources
  * BSA Loading
  * Multi threaded asset streaming
  * NIF Loading, Parsing into Godot Mesh format including bones, skins, weights and animations
  * Conversion factory for converting specific nif nodes into proper godot types
  * Two level LOD + Imposters + Unlimited distance clipmap terrain
  * Handling of XREF lighting pointers
