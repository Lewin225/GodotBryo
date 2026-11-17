"""zlib and MSVC setup shared by the nv_engine and terrain_streamer builds."""
import os
import sys

# The decompression half of zlib, which is all the BSA and ESM readers use
# (inflate, inflateEnd, inflateInit, uncompress).
ZLIB_SOURCES = ["adler32", "crc32", "inffast", "inflate", "inftrees", "uncompr", "zutil"]


def configure(env, arguments):
	"""Adds the compiler flags Windows builds need and the zlib include path.

	Returns the zlib object files to append to the library's sources. zlib is
	built from the native/zlib submodule on every platform, so no system zlib is
	needed. Its symbols are prefixed (Z_PREFIX) so they cannot collide with the
	zlib inside the Godot executable.
	"""
	native_dir = os.path.dirname(os.path.abspath(__file__))
	zlib_dir = os.path.join(native_dir, "zlib")
	if not os.path.isfile(os.path.join(zlib_dir, "zlib.h")):
		print("ERROR: native/zlib is not checked out. Run: git submodule update --init")
		sys.exit(1)

	if env.get("is_msvc", False):
		# Sources contain UTF-8 text (comments); without this MSVC reads them as ANSI.
		env.Append(CCFLAGS=["/utf-8"])
		env.Append(CPPDEFINES=["NOMINMAX", "WIN32_LEAN_AND_MEAN", "_CRT_SECURE_NO_WARNINGS"])
	elif env["platform"] == "windows":
		env.Append(CPPDEFINES=["NOMINMAX", "WIN32_LEAN_AND_MEAN"])

	env.Append(CPPPATH=[zlib_dir])
	env.Append(CPPDEFINES=["Z_PREFIX"])

	# C sources built with this environment: the C++-only flags (-std=c++17 etc.)
	# live in CXXFLAGS, so they do not reach the C compiler.
	zlib_env = env.Clone()
	zlib_env.Append(CPPDEFINES=["Z_HAVE_UNISTD_H"] if env["platform"] != "windows" else [])
	build_dir = os.path.join(native_dir, "bin", "zlib")
	objects = []
	for name in ZLIB_SOURCES:
		target = os.path.join(build_dir, name + env["suffix"] + env["SHOBJSUFFIX"])
		objects.append(zlib_env.SharedObject(target=target, source=os.path.join(zlib_dir, name + ".c")))
	return objects
