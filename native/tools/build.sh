#!/usr/bin/env bash
# Builds the dump_object CLI (phases/0/05-integration-tool.md). Deliberately
# not part of the GDExtension SCons build — this tool has no Godot
# dependency at all, so a plain g++ invocation is simpler than wiring a
# second target into native/SConstruct.
set -euo pipefail
cd "$(dirname "$0")"

g++ -std=c++17 -O2 \
	-I../src \
	-I../nifly/include -I../nifly/external \
	dump_object.cpp \
	../src/bsa/bsa_archive.cpp \
	../src/esm/esm_file.cpp \
	../src/nif/nif_loader.cpp \
	../src/nif/gltf_export.cpp \
	../nifly/src/*.cpp \
	-lz \
	-o dump_object

echo "Built native/tools/dump_object"
