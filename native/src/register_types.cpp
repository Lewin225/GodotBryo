#include "register_types.h"

#include "bsa/archive_catalog_gd.h"
#include "bsa/bsa_reader_gd.h"
#include "esm/esm_reader_gd.h"
#include "facegen/egm_reader_gd.h"
#include "gamebryo/direct_geometry_batch.h"
#include "nav/navmesh_reader_gd.h"
#include "nif/nif_reader_gd.h"
#include "nif/nif_source_gd.h"
#include "tri/tri_reader_gd.h"
#include "ping.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_nv_engine_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<NVPing>();
	ClassDB::register_class<ArchiveCatalog>();
	ClassDB::register_class<BsaReader>();
	ClassDB::register_class<EsmReader>();
	ClassDB::register_class<EgmReader>();
	ClassDB::register_class<NavmeshReader>();
	ClassDB::register_class<NifReader>();
	ClassDB::register_class<NifSource>();
	ClassDB::register_class<TriReader>();
	ClassDB::register_class<DirectGeometryBatch>();
}

void uninitialize_nv_engine_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
// Entry symbol referenced by the .gdextension file.
GDExtensionBool GDE_EXPORT nv_engine_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_nv_engine_module);
	init_obj.register_terminator(uninitialize_nv_engine_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
