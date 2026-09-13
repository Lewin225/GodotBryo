#!/usr/bin/env bash
#
# Run the project's self-checking Godot test scenes from any working directory.
#
# A zero Godot exit status alone is insufficient: Godot reports GDScript runtime
# errors without changing that status. This runner therefore requires each test
# to exit cleanly, emit no SCRIPT ERROR, and print its explicit success marker.

set -u -o pipefail

readonly REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="${REPO_DIR}/project"
readonly TEST_DIR="${PROJECT_DIR}/tests"
readonly PREFLIGHT_SCENE="test_scene_preflight.tscn"
readonly DEFAULT_GODOT="${REPO_DIR}/tools/Godot_v4.7.1-stable_linux.x86_64"
readonly GODOT="${GODOT:-${DEFAULT_GODOT}}"
readonly TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-150}"

declare -a TEST_SCENES=()

usage() {
	cat <<'EOF'
Usage: ./run_tests.sh [test scene ...]

Run all self-checking test scenes, or only the named scenes. Test paths may be
relative to project/ (tests/test_bsa.tscn) or tests/ (test_bsa.tscn).

Environment:
  GODOT            Godot executable to use.
  TIMEOUT_SECONDS  Per-scene timeout in seconds (default: 150).
EOF
}

skip_reason() {
	case "$1" in
		tests/test_exterior_cell.tscn)
			printf '%s' "interactive visual viewer"
			;;
		tests/servers/test_texture_corpus_sweep.tscn)
			printf '%s' "throughput measurement, not a pass/fail gate"
			;;
		tests/test_script_corpus_survey.tscn)
			printf '%s' "real-data survey, not a pass/fail gate"
			;;
		tests/test_facial_animation_data.tscn)
			printf '%s' "diagnostic data listing, not a pass/fail gate"
			;;
		*)
			return 1
			;;
	esac
}

add_scene() {
	local scene_path="$1"
	local relative_scene
	local reason

	if [[ -f "${PROJECT_DIR}/${scene_path}" ]]; then
		scene_path="${PROJECT_DIR}/${scene_path}"
	elif [[ -f "${TEST_DIR}/${scene_path}" ]]; then
		scene_path="${TEST_DIR}/${scene_path}"
	fi

	if [[ ! -f "${scene_path}" ]]; then
		printf 'Unknown test scene: %s\n' "$1" >&2
		return 1
	fi

	# Nested too: the server gates live in tests/servers/. A single-segment
	# pattern silently dropped all eight of them.
	case "${scene_path}" in
		"${TEST_DIR}"/test_*.tscn | "${TEST_DIR}"/*/test_*.tscn)
			relative_scene="${scene_path#"${PROJECT_DIR}/"}"
			;;
		*)
			printf 'Not a test scene under %s: %s\n' "${TEST_DIR}" "$1" >&2
			return 1
			;;
	esac

	if reason="$(skip_reason "${relative_scene}")"; then
		printf 'Not run by this self-checking test runner: %s (%s)\n' "${relative_scene}" "${reason}" >&2
		return 1
	fi

	TEST_SCENES+=("${relative_scene}")
}

if (( $# == 1 )) && [[ "$1" == "--help" || "$1" == "-h" ]]; then
	usage
	exit 0
fi

if [[ ! -x "${GODOT}" ]]; then
	printf 'Godot executable is not available: %s\n' "${GODOT}" >&2
	exit 2
fi

if ! [[ "${TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
	printf 'TIMEOUT_SECONDS must be a positive integer: %s\n' "${TIMEOUT_SECONDS}" >&2
	exit 2
fi

if (( $# == 0 )); then
	while IFS= read -r -d '' scene_path; do
		relative_scene="${scene_path#"${PROJECT_DIR}/"}"
		if skip_reason "${relative_scene}" >/dev/null; then
			printf 'SKIP %s (%s)\n' "${relative_scene}" "$(skip_reason "${relative_scene}")"
			continue
		fi
		# Not silent: a scene find offered but add_scene refused is a runner
		# bug, and dropping it quietly is how eight gates went unnoticed.
		add_scene "${scene_path}" || exit 2
	done < <(find "${TEST_DIR}" -name 'test_*.tscn' -print0 | sort -z)
	else
	for scene_path in "$@"; do
		add_scene "${scene_path}" || exit 2
	done
fi

if (( ${#TEST_SCENES[@]} == 0 )); then
	printf 'No self-checking test scenes selected.\n' >&2
	exit 2
fi

readonly LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nv-test-run.XXXXXX")"
trap 'rm -rf "${LOG_DIR}"' EXIT

run_and_capture() {
	local log_path="$1"
	shift
	"$@" >"${log_path}" 2>&1
}

preflight_log="${LOG_DIR}/preflight.log"
printf 'Preflighting %d test scene(s) with project autoloads...\n' "${#TEST_SCENES[@]}"
run_and_capture "${preflight_log}" timeout "${TIMEOUT_SECONDS}" "${GODOT}" --headless --path "${PROJECT_DIR}" "${PREFLIGHT_SCENE}" -- "${TEST_SCENES[@]}"
preflight_status=$?
if (( preflight_status != 0 )); then
	if (( preflight_status == 124 )); then
		printf 'PARSE FAILURE: preflight timed out after %ss\n' "${TIMEOUT_SECONDS}" >&2
	else
		printf 'PARSE FAILURE: Godot exited with status %d\n' "${preflight_status}" >&2
	fi
	cat "${preflight_log}" >&2
	exit 1
fi

if grep -Fq 'SCRIPT ERROR:' "${preflight_log}"; then
	printf 'PARSE FAILURE: Godot reported a SCRIPT ERROR during scene loading\n' >&2
	cat "${preflight_log}" >&2
	exit 1
fi

if ! grep -Fq 'ALL TEST SCENES PARSED' "${preflight_log}"; then
	printf 'PARSE FAILURE: preflight exited 0 without its completion marker\n' >&2
	cat "${preflight_log}" >&2
	exit 1
fi

failures=0
printf 'Running %d self-checking test scene(s)...\n' "${#TEST_SCENES[@]}"
for scene_path in "${TEST_SCENES[@]}"; do
	log_path="${LOG_DIR}/run-${scene_path//\//_}.log"
	printf '### %s ###\n' "${scene_path}"

	run_and_capture "${log_path}" timeout "${TIMEOUT_SECONDS}" "${GODOT}" --headless --path "${PROJECT_DIR}" "${scene_path}"
	status=$?
	if (( status != 0 )); then
		if (( status == 124 )); then
			printf 'FAIL: timed out after %ss\n' "${TIMEOUT_SECONDS}" >&2
		else
			printf 'FAIL: Godot exited with status %d\n' "${status}" >&2
		fi
		cat "${log_path}" >&2
		((failures += 1))
		continue
	fi

	if grep -Fq 'SCRIPT ERROR:' "${log_path}"; then
		printf 'FAIL: Godot reported a SCRIPT ERROR\n' >&2
		cat "${log_path}" >&2
		((failures += 1))
		continue
	fi

	if ! grep -Fq 'ALL CHECKS PASSED' "${log_path}"; then
		printf 'FAIL: test exited 0 without ALL CHECKS PASSED\n' >&2
		cat "${log_path}" >&2
		((failures += 1))
		continue
	fi

	grep -F 'ALL CHECKS PASSED' "${log_path}"
done

if (( failures > 0 )); then
	printf 'FAILURES: %d test scene(s) failed.\n' "${failures}" >&2
	exit 1
fi

printf 'ALL CHECKS PASSED (%d test scenes).\n' "${#TEST_SCENES[@]}"
