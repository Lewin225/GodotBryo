#ifndef KF_ANIMATOR_H
#define KF_ANIMATOR_H

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <map>
#include <vector>

namespace godot {

// Plays several KF clips on one Skeleton3D at once and resolves each bone by
// the clips' controlled block priorities (Plans/Actors/animation_blending.md).
//
// A clip is a NifServer Animation: tracks whose paths are skeleton bone names,
// and `nif_track_priorities` metadata (track path -> priority). Each slot (an
// animation group section number, chosen by the caller) plays at most one
// clip, plus the clip it is fading out from. Every update, each bone channel
// (position, rotation, scale) takes the playing tracks that key it, highest
// priority first: a priority's tracks share the weight still unclaimed (their
// fade weights, at most all of it), and what is left passes to the next
// priority down; weight none claims is shared among them in proportion, so a
// clip fading out alone holds its pose. With tie_mode NEWEST only the
// most recently started clip at a priority counts.
//
// Poses are written with Skeleton3D::set_bone_pose_*, as AnimationMixer does,
// not as a SkeletonModifier3D: Skeleton3D restores every pose after its
// modifiers each frame, so the pose written here is what the skeleton's
// modifiers (IK, LookAtModifier3D) start from and it stays put on frames the
// update interval skips. Bones no clip keys are not written.
//
// Clip clocks, fades and text keys advance every frame; poses are written every
// `update_interval` frames.
//
// Root motion (root_motion_mode). Every clip played with keep_root is drawn
// without its root change since it started; the root clip's (the most recently
// started such clip outside root_motion_excluded_slot) is reported as
// get_root_motion(), in the skeleton's space,
// for the caller to move the actor by, so a clip fading out after it stays where
// the actor took it. Which part is taken is the mode, each one way of
// reading the KFs' Bip01 / Bip01 NonAccum split
// (Plans/Actors/animation_blending.md, Root bones):
//   NONE: nothing is taken.
//   BIP01: Bip01's translation.
//   BIP01_NONACCUM_YAW: Bip01's translation and NonAccum's yaw about Z.
//   NONACCUM: NonAccum's translation in the XY plane and its yaw about Z.
//   ROOT_TRANSFORM: the root as one transform, Bip01's translation then
//     NonAccum's facing (the yaw of its X axis from Bip01's +Y, the stance
//     facing), its change since the clip started composed as a transform; the
//     clip is drawn with all of it taken out (Bip01 at the origin, unrotated,
//     whether or not the clip keys it; NonAccum
//     turned to face +Y), so a clip authored away from its start (the chair
//     exit, starting on the seat) needs no move of its own.
// With hold_unkeyed_root, a root clip that keys no Bip01 has Bip01 drawn at the
// clip's origin, unrotated, rather than left where it was.
class KfAnimator : public Node {
	GDCLASS(KfAnimator, Node)

public:
	enum TieMode {
		TIE_BLEND = 0,
		TIE_NEWEST = 1,
	};

	enum RootMotionMode {
		ROOT_MOTION_NONE = 0,
		ROOT_MOTION_BIP01 = 1,
		ROOT_MOTION_BIP01_NONACCUM_YAW = 2,
		ROOT_MOTION_NONACCUM = 3,
		ROOT_MOTION_ROOT_TRANSFORM = 4,
	};

	KfAnimator() = default;

	void set_skeleton_path(const NodePath &p_path);
	NodePath get_skeleton_path() const;
	void set_update_interval(int p_frames);
	int get_update_interval() const;
	void set_paused(bool p_paused);
	bool is_paused() const;
	void set_tie_mode(int p_mode);
	int get_tie_mode() const;
	void set_root_motion_mode(int p_mode);
	int get_root_motion_mode() const;
	void set_hold_unkeyed_root(bool p_hold);
	bool is_holding_unkeyed_root() const;
	// The root clip's root change since it started, skeleton space; identity
	// with no root clip or mode NONE. Updated when the pose is written.
	Transform3D get_root_motion() const;
	// Which clip get_root_motion() is measured from (its play order), 0 for
	// none: a new value means a new clip, from whose start the motion restarts.
	int64_t get_root_clip_serial() const;
	// The slot of the clip get_root_motion() is measured from, -1 for none.
	int get_root_clip_slot() const;
	// The root clips' motion added up at each pose write since the last call,
	// and reset: a root clip that ends or is replaced between calls has its
	// motion up to then included. Clips in root_motion_excluded_slot are left
	// out (locomotion, which the controller moves).
	Transform3D consume_root_motion();
	void set_root_motion_excluded_slot(int p_slot);
	int get_root_motion_excluded_slot() const;

	// Starts `animation` in `slot`, fading in over `fade_seconds` (in an empty
	// slot too) while the slot's current clip fades out. Bip01 and Bip01 NonAccum tracks play
	// only with `keep_root`.
	void play(int p_slot, const Ref<Animation> &p_animation, float p_fade_seconds, bool p_keep_root, float p_speed);
	// Fades the slot's clip out over `fade_seconds`; the slot is then empty.
	void stop(int p_slot, float p_fade_seconds);
	void stop_all();
	// Moves the slot's current clip to `time` seconds.
	void seek(int p_slot, float p_time);
	// Loops the slot's current clip between `start` and `end` seconds (its
	// StartLoop and EndLoop keys) `count` times in all, then lets it play on
	// to its end; a negative `count` loops forever and a negative `end`
	// clears the section.
	void set_loop_section(int p_slot, float p_start, float p_end, int p_count);
	Ref<Animation> get_animation(int p_slot) const;
	float get_time(int p_slot) const;
	PackedInt32Array get_slots() const;
	// Writes the pose now, whatever the update interval.
	void update_pose();

protected:
	static void _bind_methods();
	void _notification(int p_what);

private:
	// One track of a clip bound to a skeleton bone.
	struct BoundTrack {
		int bone = -1;
		int track = -1;
		Animation::TrackType type = Animation::TYPE_POSITION_3D;
		int priority = 0;
	};

	// A clip playing in a slot.
	struct Clip {
		Ref<Animation> animation;
		std::vector<BoundTrack> tracks;
		float time = 0.0f;
		float speed = 1.0f;
		float length = 0.0f;
		bool loops = false;
		// Fade weight, 0 to 1, and its change per second.
		float weight = 1.0f;
		float weight_rate = 0.0f;
		// Order of play: higher started later.
		uint64_t serial = 0;
		bool keep_root = false;
		// The root tracks, -1 when the clip has none, and their values at the
		// clip's start.
		int root_position_track = -1;
		int non_accum_position_track = -1;
		int non_accum_rotation_track = -1;
		Vector3 root_position_start;
		Vector3 non_accum_position_start;
		Quaternion non_accum_rotation_start;
		float loop_start = -1.0f;
		float loop_end = -1.0f;
		// Passes of the loop section still to start after the current one;
		// negative loops forever.
		int loops_left = -1;
		bool finished = false;
	};

	struct Slot {
		Clip current;
		bool has_current = false;
		std::vector<Clip> fading;
	};

	// A signal raised while advancing, emitted once every slot has advanced:
	// a handler may play or stop clips, which must not happen mid-iteration.
	struct Event {
		int slot = 0;
		bool finished = false;
		Ref<Animation> animation;
		String key;
		float time = 0.0f;
	};

	// One clip's sample for one bone channel.
	struct Sample {
		int priority = 0;
		float weight = 0.0f;
		uint64_t serial = 0;
		Vector3 vector;
		Quaternion rotation;
	};

	Skeleton3D *_skeleton() const;
	bool _bind(Clip &r_clip, bool p_keep_root) const;
	void _advance(float p_delta);
	void _advance_clip(int p_slot, Clip &r_clip, float p_delta, bool p_is_current);
	void _emit_text_keys(int p_slot, const Clip &p_clip, float p_from, float p_to);
	void _write_pose();
	void _resolve(std::vector<Sample> &r_samples) const;
	const Clip *_root_clip() const;
	void _measure_root_motion(const Clip &p_clip, Vector3 &r_translation, float &r_yaw) const;
	Transform3D _root_transform(const Clip &p_clip, double p_time) const;
	Transform3D _clip_root_motion(const Clip &p_clip) const;
	const Clip *_clip_by_serial(uint64_t p_serial) const;
	void _accumulate_root_motion(const Clip *p_root_clip, int p_root_slot);

	std::vector<Event> _events;
	NodePath _skeleton_path;
	int _update_interval = 1;
	bool _paused = false;
	int _tie_mode = TIE_BLEND;
	int _root_motion_mode = ROOT_MOTION_NONE;
	bool _hold_unkeyed_root = false;
	Transform3D _root_motion;
	uint64_t _root_serial = 0;
	// consume_root_motion(): the motion added up, the clip and slot last
	// measured and its root motion then.
	Transform3D _pending_root_motion;
	uint64_t _measured_serial = 0;
	int _measured_slot = -1;
	Transform3D _measured_motion;
	int _root_motion_excluded_slot = -1;
	std::map<int, Slot> _slots;
	uint64_t _next_serial = 1;
	uint64_t _frame = 0;
};

} // namespace godot

VARIANT_ENUM_CAST(KfAnimator::TieMode);
VARIANT_ENUM_CAST(KfAnimator::RootMotionMode);

#endif // KF_ANIMATOR_H
