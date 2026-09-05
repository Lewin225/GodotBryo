**GodotByro is attempting to be a from scratch, drop in replacement for GameByro** 

[57.webm](https://github.com/user-attachments/assets/acd63b62-cdd3-4947-a576-eafb900f62df)


*Targeting fallout new vegas (with fallout 3 and skyrim as future work)*

Why Godot? Lightweight, existing renderer, zero cost and easily modifiable though gdextension, source available , multi platform


<img width="1141" height="636" alt="56" src="https://github.com/user-attachments/assets/0e071226-0fae-4177-9dc6-979726d76cc6" />


**Current Status**
* Gameplay
  * Walk around only at the moment
  * Open world terrain rendering using Terrain3D sourced from LAND records, including the 7+1 layer terrain blending from gamebyro
  * Interior cell loading, Including fog, lighting and environment data
  * Script Engine (Currently very limited API support)
  * Proper cell transitions using DOOR Destination
  * Cell caching for fast renter/exit

 
* Some gameplay objects functional
  * DOOR + Anims and sounds
  * TERM - Pending proper ui, but parsing correctly
  * ACTI - Scripts attached fire correctly through the script engine, but api is very basic as is
  * MISC, WEAP, ALCH - Moveable Jolt physics objects. Can be picked up into a placeholder inventory

<img width="1143" height="643" alt="54" src="https://github.com/user-attachments/assets/37bc0e0c-f5d5-4c56-870e-20bcefe2a0ab" />

* Internal
  * ESM Parsing, Form Data resolution into resources
  * BSA Loading
  * Multi threaded asset streaming
  * NIF Loading, Parsing into Godot Mesh format including bones, skins, weights and animations
  * Conversion factory for converting specific nif nodes into proper godot types
  * Two level LOD + Imposters + Unlimited distance clipmap terrain
  * Handling of XEMI lighting pointers
