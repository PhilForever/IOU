"""Lua 5.1 ledger/UI, diagnostic transport and shared agreement checks.

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
                 ("test_iou.lua", "test_transport.lua", "test_shared.lua",
                  "test_shared_wire.lua", "test_shared_service.lua",
                  "test_shared_payment_codec.lua", "test_shared_payments.lua",
                  "test_shared_payment_integration.lua", "test_shared_backup_codec.lua", "test_shared_recovery.lua",
                  "test_shared_backup_ui.lua", "test_shared_view.lua", "test_shared_workflow.lua",
                  "test_player_summary.lua", "test_player_context.lua",
                  "test_compact_ui.lua", "test_compact_shared_ui.lua", "test_trade_matching.lua",
                  "test_trade_service.lua", "test_trade_observer.lua", "test_trade_ui.lua",
                  "test_mail_activity.lua", "test_mail_sent.lua", "test_mail_received.lua",
                  "test_mail_integration.lua", "test_capture_edges.lua", "test_shared_items.lua",
                  "test_linked_matching.lua", "test_crafting.lua", "test_requests_100.lua",
                  "test_sharing_100.lua", "test_shared_background.lua", "test_sync_hint.lua",
                  "test_shared_inbox.lua", "test_bundle_activity.lua", "test_100_review.lua", "test_item_context.lua",
                  "test_item_links_101.lua", "test_ui_101.lua")]
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
    for label, count in zip(("Ledger/UI", "Transport", "Shared agreement",
                             "Shared wire", "Shared service", "Shared payment codec",
                             "Shared payments", "Shared payment integration", "Shared backup codec", "Shared recovery",
                             "Shared backup UI", "Shared view", "Shared workflow", "Player summary", "Player context",
                             "Compact UI", "Compact Shared UI", "Trade matching", "Trade service", "Trade observer", "Trade UI",
                             "Mail activity", "Mail sent", "Mail received", "Mail integration", "Capture edges",
                             "Shared items", "Linked matching", "Crafting", "Requests 1.0", "Sharing 1.0", "Shared background",
                             "Sync hints", "Shared inbox", "Activity bundles", "Mixed repayment histories", "Item link context",
                             "Native item links", "UI clarity 1.0.1"), counts,
                            strict=True):
        print(f"{label} checks: {count} passed.")
    print(f"Checks: {sum(counts)} passed.")
    print("Limit: mocks cannot validate the actual WoW client, taint, rendering, "
          "event delivery, or SavedVariables persistence across relogs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
