#!/usr/bin/env bash
# Builds the terrain_census research tool (phases/2/13-terrain3d-integration.md).
# No Godot dependency, same standalone-CLI pattern as dump_object.sh's build.sh.
set -euo pipefail
cd "$(dirname "$0")"

g++ -std=c++17 -O2 \
	-I../src \
	terrain_census.cpp \
	../src/esm/esm_file.cpp \
	-lz \
	-o terrain_census

echo "Built native/tools/terrain_census"
