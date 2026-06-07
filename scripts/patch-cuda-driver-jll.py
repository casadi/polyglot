#!/usr/bin/env python3
"""Default JULIA_CUDA_USE_COMPAT to "false" in CUDA_Driver_jll wrappers.

Without this, CUDA_Driver_jll's __init__ falls into a Threads.@spawn'd
`inspect_driver` subprocess that tries to exec a julia binary — fails inside
an AOT-compiled libMad bundle. LocalPreferences.toml's
`[CUDA_Driver_jll] compat = "false"` is supposed to cover this but doesn't
always bake reliably into the AOT image. Patching the wrapper's default makes
the behaviour stick regardless of preferences or env.

Run after `Pkg.instantiate()` (which downloads CUDA_Driver_jll) and before
juliac compiles the final shared library. Idempotent.
"""
# NB: don't add `from __future__ import annotations` here — manylinux_2_28
# base image's `/usr/bin/python3` is 3.6.8, which predates that feature.
# The script doesn't use PEP-563 annotations anyway.
import glob, os, re, sys

depot = os.environ.get("JULIA_DEPOT_PATH")
if not depot:
    sys.exit("JULIA_DEPOT_PATH not set")

files = sorted(
    glob.glob(f"{depot}/packages/CUDA_Driver_jll/*/src/wrappers/x86_64-linux-gnu.jl")
    + glob.glob(f"{depot}/packages/CUDA_Driver_jll/*/src/wrappers/aarch64-linux-gnu.jl")
)
if not files:
    sys.exit("no CUDA_Driver_jll wrapper found — did Pkg.instantiate run?")

# The default branch ("missing") of the env-var fallback. The preceding two
# branches (preferences, ENV) keep their existing behaviour — we only change
# what happens when neither is set.
pattern = re.compile(
    r'(elseif haskey\(ENV, "JULIA_CUDA_USE_COMPAT"\)\s*\n'
    r'\s*parse_preference\(ENV\["JULIA_CUDA_USE_COMPAT"\]\)\s*\n'
    r'\s*else\s*\n'
    r'\s*)missing(\s*\n\s*end)'
)

for path in files:
    src = open(path).read()
    new, n = pattern.subn(
        r'\1false  # polyglot default: skip forward-compat CUDA driver lookup\2',
        src,
    )
    if n:
        open(path, "w").write(new)
        print(f"patched {path}")
    else:
        # Either already patched, or upstream CUDA_Driver_jll restructured.
        print(f"skipped {path} (pattern not matched — already patched?)")
