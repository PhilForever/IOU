"""Build a reproducible installable IOU ZIP using only the Python standard library."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import sys
import xml.etree.ElementTree as ET
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_FILES = frozenset({
    "IOU.toc", "ledger.lua", "codec.lua", "core.lua", "ui.lua",
    "launcher.lua", "Bindings.xml",
})
DOCUMENT_FILES = frozenset({"README.md", "CHANGELOG.md", "LICENSE"})
PACKAGE_FILES = RUNTIME_FILES | DOCUMENT_FILES
VERSION_PATTERN = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?"


def safe_reference(reference: str, parent: str = "") -> str:
    """Resolve an addon-relative dependency without admitting external paths."""
    normalized = reference.replace("\\", "/")
    path = PurePosixPath(normalized)
    if path.is_absolute() or not normalized or ":" in normalized or ".." in path.parts:
        raise ValueError(f"Unsafe addon file reference: {reference!r}")
    result = str(PurePosixPath(parent) / path)
    if result not in RUNTIME_FILES:
        raise ValueError(f"Dependency is outside the release file list: {result}")
    return result


def inspect_addon(root: Path) -> str:
    """Check the manifest and every TOC/XML dependency before packaging."""
    for name in sorted(PACKAGE_FILES):
        path = root / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Required release file is missing or is a symlink: {name}")
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"Release file is outside the source directory: {name}")

    toc = (root / "IOU.toc").read_text(encoding="utf-8-sig")
    versions = re.findall(r"^##\s*Version:\s*(\S+)\s*$", toc, re.MULTILINE)
    if len(versions) != 1 or not re.fullmatch(VERSION_PATTERN, versions[0]):
        raise ValueError("IOU.toc must declare one semantic Version (for example 0.2.0)")
    if not re.search(r"^##\s*SavedVariables:\s*IOUDB\s*$", toc, re.MULTILINE):
        raise ValueError("IOU.toc must preserve the IOUDB SavedVariables declaration")

    loaded: set[str] = set()
    pending = [
        safe_reference(line.strip())
        for line in toc.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    # WoW loads Bindings.xml by convention, including when it is absent from the TOC.
    pending.append("Bindings.xml")
    while pending:
        name = pending.pop()
        if name in loaded:
            continue
        loaded.add(name)
        if name.lower().endswith(".xml"):
            try:
                tree = ET.parse(root / name)
            except ET.ParseError as exc:
                raise ValueError(f"Invalid XML in {name}: {exc}") from exc
            for element in tree.iter():
                if element.tag.rsplit("}", 1)[-1] in {"Script", "Include"}:
                    reference = element.attrib.get("file")
                    if reference:
                        pending.append(safe_reference(reference, str(PurePosixPath(name).parent)))
    missing = RUNTIME_FILES - loaded - {"IOU.toc"}
    if missing:
        raise ValueError("Runtime files are not loaded by the TOC/XML: " + ", ".join(sorted(missing)))
    bindings = ET.parse(root / "Bindings.xml")
    toggles = [
        element for element in bindings.iter()
        if element.tag.rsplit("}", 1)[-1] == "Binding"
        and element.attrib.get("name") == "IOU_TOGGLE"
    ]
    if len(toggles) != 1 or "IOU_ToggleLedger" not in "".join(toggles[0].itertext()):
        raise ValueError("Bindings.xml must declare the IOU_TOGGLE ledger binding")
    launcher = (root / "launcher.lua").read_text(encoding="utf-8-sig")
    if not re.search(r"(?:function\s+IOU_ToggleLedger\s*\(|IOU_ToggleLedger\s*=\s*function\s*\()", launcher):
        raise ValueError("launcher.lua must provide the global IOU_ToggleLedger function")
    return versions[0]


def build(root: Path, output_dir: Path, expected_version: str | None = None) -> Path:
    version = inspect_addon(root)
    if expected_version is not None and version != expected_version.removeprefix("v"):
        raise ValueError(f"Tag version {expected_version!r} does not match IOU.toc version {version!r}")
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / f"IOU-{version}.zip"
    with ZipFile(destination, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(PACKAGE_FILES):
            entry = ZipInfo(f"IOU/{name}", date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.compress_type = ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, (root / name).read_bytes(), compresslevel=9)
    checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(".zip.sha256").write_text(
        f"{checksum}  {destination.name}\n", encoding="utf-8", newline="\n"
    )
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--expected-version", help="Require this version or v-prefixed tag")
    arguments = parser.parse_args()
    try:
        destination = build(ROOT, arguments.output_dir, arguments.expected_version)
    except (OSError, ValueError) as exc:
        print(f"Package failed: {exc}", file=sys.stderr)
        return 1
    print(f"Built {destination.name} ({len(PACKAGE_FILES)} files under IOU/)")
    print(f"SHA256 {hashlib.sha256(destination.read_bytes()).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
