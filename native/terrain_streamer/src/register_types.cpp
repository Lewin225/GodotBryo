#include "terrain_region_stager.h"

#include <gdextension_interface.h>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_terrain_streamer_module(ModuleInitializationLevel level) {
	if (level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		ClassDB::register_class<TerrainRegionStager>();
	}
}

static void uninitialize_terrain_streamer_module(ModuleInitializationLevel) {}

extern "C" {
GDExtensionBool GDE_EXPORT terrain_streamer_library_init(
		GDExtensionInterfaceGetProcAddress get_proc_address,
		GDExtensionClassLibraryPtr library,
		GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(initialize_terrain_streamer_module);
	init.register_terminator(uninitialize_terrain_streamer_module);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
}
