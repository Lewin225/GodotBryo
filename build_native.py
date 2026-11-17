#!/usr/bin/env python3
"""Builds every native extension and puts the results where the project loads them.

    python build_native.py                      # debug build for this OS
    python build_native.py --target release
    python build_native.py --only nv_engine terrain_streamer

Steps (each is a separate SCons build):
  nv_engine         native/            -> project/bin/
  terrain_streamer  native/terrain_streamer/  -> project/addons/terrain_streamer/bin/
  terrain3d         native/terrain3d/  -> its own demo project, then copied to
                                          project/addons/terrain_3d/bin/

Needs Python 3, SCons, a C++17 compiler (MSVC or MinGW on Windows) and the
submodules (git submodule update --init --recursive). zlib is built from the
native/zlib submodule; no system zlib is needed.
Anything after `--` is passed to every scons invocation.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.join(REPO, "native")
STEPS = ["nv_engine", "terrain_streamer", "terrain3d"]


def host_platform():
	if sys.platform.startswith("win"):
		return "windows"
	if sys.platform == "darwin":
		return "macos"
	return "linux"


def link_sunshine_clouds():
	"""project/addons/SunshineClouds2 is a git symlink into the submodule.

	Git for Windows checks a symlink out as a plain text file unless symlinks
	are enabled, and Godot then reports the addon as missing. Replace it with a
	directory junction, which needs no special privileges.
	"""
	if host_platform() != "windows":
		return
	link = os.path.join(REPO, "project", "addons", "SunshineClouds2")
	target = os.path.join(NATIVE, "SunshineClouds2", "addons", "SunshineClouds2")
	if not os.path.isdir(target):
		print("warning: native/SunshineClouds2 is empty; run git submodule update --init")
		return
	if os.path.isdir(link):
		return
	if os.path.exists(link):
		os.remove(link)
	subprocess.check_call(["cmd", "/c", "mklink", "/J", link, target])


def run_scons(cwd, args):
	command = [sys.executable, "-m", "SCons"] + args
	print("\n==> (%s) scons %s" % (os.path.relpath(cwd, REPO), " ".join(args)), flush=True)
	if subprocess.call(command, cwd=cwd) != 0:
		sys.exit("build failed in %s" % cwd)


def main():
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	parser.add_argument("--platform", default=host_platform(), choices=["linux", "windows", "macos"])
	parser.add_argument("--target", default="debug", choices=["debug", "release"])
	parser.add_argument("--jobs", "-j", type=int, default=os.cpu_count() or 1)
	parser.add_argument("--only", nargs="+", choices=STEPS, help="build just these steps")
	parser.add_argument("scons_args", nargs="*", help="extra scons arguments (after --)")
	args = parser.parse_args()

	steps = args.only or STEPS
	template = "template_" + args.target
	common = ["platform=" + args.platform, "-j%d" % args.jobs] + args.scons_args

	ours = ["target=" + template, "api_version=4.7", "disable_exceptions=no"]
	if args.platform == "linux":
		ours.append("use_static_cpp=no")

	if "nv_engine" in steps:
		run_scons(NATIVE, ours + common)
	if "terrain_streamer" in steps:
		run_scons(os.path.join(NATIVE, "terrain_streamer"), ours + common)
	if "terrain3d" in steps:
		# Terrain3D pins its own older godot-cpp: no api_version, and its target
		# names are plain debug/release rather than template_*.
		terrain_dir = os.path.join(NATIVE, "terrain3d")
		run_scons(terrain_dir, ["target=" + template] + common)
		built = os.path.join(terrain_dir, "project", "addons", "terrain_3d", "bin")
		dest = os.path.join(REPO, "project", "addons", "terrain_3d", "bin")
		os.makedirs(dest, exist_ok=True)
		pattern = "libterrain.%s.%s.*" % (args.platform, args.target)
		copied = 0
		for source in glob.glob(os.path.join(built, pattern)):
			if os.path.isdir(source):
				shutil.copytree(source, os.path.join(dest, os.path.basename(source)), dirs_exist_ok=True)
			else:
				shutil.copy2(source, dest)
			print("copied", os.path.basename(source), "->", os.path.relpath(dest, REPO))
			copied += 1
		if copied == 0:
			sys.exit("Terrain3D built but no %s found in %s" % (pattern, built))

	link_sunshine_clouds()
	print("\nDone.")


if __name__ == "__main__":
	main()
