"""Lua 5.1 domain, isolated mocked-UI and two-client transport checks.

Run with Python and lupa 2.8. An optional tools/vendor installation is supported.
Only IOU source and this harness are executed. Real client compatibility and
SavedVariables persistence still require the documented in-game checks.
"""

from pathlib import Path
import sys
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "tools" / "vendor"
try:
    from lupa.lua51 import LuaRuntime  # noqa: E402
except ImportError:
    if VENDOR.is_dir():
        # Prefer the active interpreter's installed wheel; a local vendor
        # directory may contain a wheel built for a different Python version.
        sys.path.insert(0, str(VENDOR))
        for name in list(sys.modules):
            if name == "lupa" or name.startswith("lupa."):
                del sys.modules[name]
    try:
        from lupa.lua51 import LuaRuntime  # noqa: E402
    except ImportError as exc:
        raise SystemExit(
            "Lua 5.1 tests require lupa 2.8. Install it with: "
            "python -m pip install -r requirements-dev.txt"
        ) from exc


def main() -> int:
    lua = LuaRuntime(unpack_returned_tuples=True)
    compile_only = lua.eval(
        "function(source, name) local fn, err = loadstring(source, name); "
        "if not fn then error(err) end; return true end"
    )
    addon = ROOT / "IOU" if (ROOT / "IOU" / "IOU.toc").is_file() else ROOT
    files = sorted(addon.glob("*.lua"))
    if not files:
        raise RuntimeError(f"No IOU Lua files found in {addon}")
    harnesses = [ROOT / "tools" / name for name in
                 ("test_iou.lua", "test_transport.lua")]
    for path in [*files, *harnesses]:
        compile_only(path.read_text(encoding="utf-8-sig"), "@" + path.name)
    lua.globals().IOU_SOURCES = lua.table_from(
        {path.name: path.read_text(encoding="utf-8-sig") for path in files}
    )
    bindings_xml = ElementTree.parse(addon / "Bindings.xml").getroot()
    if bindings_xml.tag != "Bindings":
        raise RuntimeError("Bindings.xml must have a Bindings root element")
    bindings = {}
    for element in bindings_xml.findall("Binding"):
        name = element.attrib["name"]
        if name in bindings:
            raise RuntimeError(f"Duplicate key binding: {name}")
        body = element.text or ""
        compile_only(body, "@Bindings.xml:" + name)
        bindings[name] = body
    lua.globals().IOU_BINDINGS = lua.table_from(bindings)
    counts = []
    for harness in harnesses:
        results = lua.execute(harness.read_text(encoding="utf-8-sig"))
        counts.append(len(results))
        for name in results.values():
            print("PASS", name)
    print(f"Lua 5.1 syntax: {len(files)} addon files plus {len(harnesses)} test harnesses.")
    print(f"Ledger/UI checks: {counts[0]} passed.")
    print(f"Transport checks: {counts[1]} passed.")
    print(f"Checks: {sum(counts)} passed.")
    print("Limit: mocks cannot validate the actual WoW client, taint, rendering, "
          "event delivery, or SavedVariables persistence across relogs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
