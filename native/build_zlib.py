"""zlib and MSVC setup shared by the nv_engine and terrain_streamer builds."""
import os


def configure(env, arguments):
	"""Adds zlib to `env` and the compiler flags Windows builds need.

	Linux and macOS use the system zlib (-lz). Windows has none, so point the
	build at one with `zlib_path=<dir>` (a directory holding include/ and lib/,
	for example a vcpkg installed/x64-windows tree) or the ZLIB_PATH environment
	variable. MSVC links `zlib.lib`; MinGW links `-lz`.
	"""
	is_msvc = bool(env.get("is_msvc", False))

	if is_msvc:
		# Sources contain UTF-8 text (comments); without this MSVC reads them as ANSI.
		env.Append(CCFLAGS=["/utf-8"])
		env.Append(CPPDEFINES=["NOMINMAX", "WIN32_LEAN_AND_MEAN", "_CRT_SECURE_NO_WARNINGS"])
	elif env["platform"] == "windows":
		env.Append(CPPDEFINES=["NOMINMAX", "WIN32_LEAN_AND_MEAN"])

	if env["platform"] != "windows":
		env.Append(LIBS=["z"])
		return

	zlib_path = arguments.get("zlib_path", os.environ.get("ZLIB_PATH", ""))
	if zlib_path:
		env.Append(CPPPATH=[os.path.join(zlib_path, "include")])
		env.Append(LIBPATH=[os.path.join(zlib_path, "lib")])
	env.Append(LIBS=["zlib" if is_msvc else "z"])
