"""Run the addon pure-Lua suite with Lua 5.1 through optional local Lupa.

Use `lua5.1 tests/run.lua` without Python, or install Lupa into .test-deps
(`python -m pip install --target .test-deps lupa`) and run this file.
Lupa is a development dependency only; the addon has no dependencies.
"""

from pathlib import Path
import os
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".test-deps"))
try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    raise SystemExit(
        "Lua 5.1 runtime unavailable. Use lua5.1 tests/run.lua, or install the "
        "optional runner: python -m pip install --target .test-deps lupa"
    )

os.chdir(ROOT)
runtime = LuaRuntime(unpack_returned_tuples=True)
paths = sorted(
    path.relative_to(ROOT).as_posix()
    for directory in (ROOT / "ForeverDuel", ROOT / "tests")
    for path in directory.rglob("*.lua")
)
runtime.globals().TEST_LUA_FILES = runtime.table_from(paths)
runtime.execute((ROOT / "tests" / "run.lua").read_text(encoding="utf-8"))
