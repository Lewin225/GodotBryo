#ifndef UNITS_H
#define UNITS_H

namespace units {

// Bethesda/Gamebryo world units are not meters. Confirmed two independent
// ways: a cited GECK-modding constant (7 units per 10cm, i.e. 70 units/m)
// and Phase 1's own research (an exterior cell is 4096 units = 58.5m, i.e.
// ~70.02 units/m) — the two agree to within measurement precision. Also
// matches GECK wiki's own "average human is ~128 units" (~1.83m, ~6ft).
//
// Applied at the true source (nif_loader.cpp's vertex/translation data,
// esm_file.cpp's REFR/SCOL position data), not per-consumer — every
// position value returned by this codebase, all the way out through the
// Godot wrappers and the glTF exporter, is in meters by construction.
// Discovered late: every render before this was ~70x too large because
// raw Gamebryo units were treated as Godot meters directly.
//
// Only applies to positions/vertex coordinates. Rotation is unitless
// (radians); a REFR's XSCL / a SCOL part's scale field is already a
// relative multiplier, not a distance — neither needs this conversion.
constexpr float kGamebryoUnitsToMeters = 1.0f / 70.0f;

// Havok collision shape data (bhk* blocks) is stored in a THIRD, separate
// unit scale — not raw Gamebryo units, and not meters.
//
// A first pass at this (sourced from a single secondary description of
// nifskope's Havok operations) had the direction backwards: `havok_raw /
// 7.0` to get NIF units, composed to `havok_raw / 490.0` for meters. That
// produced collision shapes ~7x too small — caught by eye in the Godot
// editor (mesh colliders visibly tiny next to their own render mesh), then
// confirmed numerically, not by guessing again: compared every real
// triangle-mesh collision shape's own extracted AABB size against its
// sibling render mesh's AABB size (which is already known-correct) across
// several real objects, trying a few candidate conversions. `havok_raw *
// 7.0 / 70.0` (i.e. `havok_raw / 10.0`) matched the render mesh size almost
// exactly every time (e.g. one object: render size (0.343, 2.743, 0.229) m
// vs. this formula's collision size (0.343, 2.743, 0.229) m — identical to
// 3 decimal places), while the original `/490` version was ~7x too small
// and a `/70`-only version (no Havok factor at all) was ~7x too small in
// the other direction relative to that. Kept this numeric cross-check
// method in mind for any future unit-scale claim sourced from a single,
// not-independently-verified reference — see phases/1/02-collision-extraction.md.
//
// Only applies to positions/vertex coordinates. Rotation is unitless
// (radians); a REFR's XSCL / a SCOL part's scale field is already a
// relative multiplier, not a distance — neither needs this conversion.
constexpr float kHavokToMeters = kGamebryoUnitsToMeters * 7.0f;

// Same Havok-unit-scale factor as kHavokToMeters, but stopping at raw
// Gamebryo units instead of meters — needed when a Havok-unit value (e.g. a
// bhkRigidBody's own translation) must be composed with other transforms
// that are still in raw Gamebryo units, before the whole chain gets
// converted to meters once at the end (see nif_loader.cpp's
// flatten_to_root/flatten_transform split).
constexpr float kHavokUnitsToGamebryoUnits = 7.0f;

} // namespace units

#endif // UNITS_H
