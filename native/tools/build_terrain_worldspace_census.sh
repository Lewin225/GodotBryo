#!/usr/bin/env bash
# Build the finite per-worldspace LAND queue-domain census for issue #19.
set -euo pipefail
cd "$(dirname "$0")"

g++ -std=c++17 -O2 \
	-I../src \
	terrain_worldspace_census.cpp \
	../src/esm/esm_file.cpp \
	-lz \
	-o terrain_worldspace_census

echo "Built native/tools/terrain_worldspace_census"
