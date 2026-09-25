/gamebryo - legacy v0 implementation.

These classes do not properly handle the separation of base forms and
references. Only use them for learning how to generally do something. Any
statement in these files presented as fact must be rechecked, not believed.

Most of v0 left the Godot project on 2026-09-23 -- 41 implementation files plus
their tests, diagnostics and viewers now live in `old/` at the repo root, which
nothing loads. See `old/README.md`.

What remains here is only what `project/` still reaches:

LIVE, no v1 replacement yet
  terrain3d_bridge, terrain3d_texture_pool, terrain_builder
  game_time_manager, weather_manager, celestial_controller

IMPORTED BY THE V1 STACK -- these want homes under GodotBryo/Types/
  inventory, face_gen_data          <- GodotBryo/Servers/EsmServer/esm_server.gd
  motion_data, actor_animation_component  <- player/player_controller.gd
											 (MotionData is an @export there)

NEEDED BY LIVE TESTS
  mesh_resolver  <- 8 tests, incl. tests/servers/test_texture_server.gd, whose
					parity check is deliberately against the legacy resolver
  item_node      <- tests/test_esm_server.gd

TRANSITIVE CLOSURE of the above
  gamebryo_visual, gamebryo_object, gamebryo_reference,
  gamebryo_collision_body, gamebryo_rigid_body,
  face_gen_geometry_asset, no_lighting_falloff.gdshader

Do not move a file out of here without checking what the remaining files need
from it. The first attempt kept mesh_resolver but moved seven of its
dependencies, which broke compilation project-wide; the symptom was tests
appearing to hang rather than fail, because a parse error in a depended script
stalls a scene before it prints anything.
