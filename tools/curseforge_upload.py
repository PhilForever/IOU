"""Upload a verified IOU release ZIP to the CurseForge WoW upload API."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid
from zipfile import BadZipFile, ZipFile

API = "https://wow.curseforge.com"
GAME_VERSION = "1.60.1"
TAG = r"v([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?)"


def release_version(tag: str) -> str:
    match = re.fullmatch(TAG, tag)
    if not match:
        raise ValueError("Use a version tag such as v0.2.0 or v0.3.0-alpha.2.")
    return match[1]


def release_type(version: str) -> str:
    if "-" not in version:
        return "release"
    return "beta" if version.split("-", 1)[1].lower().startswith(("beta", "rc")) else "alpha"


def inspect_release(archive: Path, checksum: Path, tag: str, project_id: int) -> tuple[str, str, str]:
    version = release_version(tag)
    if archive.name != f"IOU-{version}.zip" or not 0 < archive.stat().st_size <= 10 * 1024 * 1024:
        raise ValueError("Unexpected release ZIP name or size.")
    expected = checksum.read_text(encoding="utf-8").strip().split()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if len(expected) != 2 or expected != [digest, archive.name]:
        raise ValueError("Release SHA-256 checksum does not match its ZIP.")
    with ZipFile(archive) as package:
        entries = package.infolist()
        paths = [entry.filename for entry in entries]
        if len(paths) != len(set(paths)) or len(paths) > 32 or sum(entry.file_size for entry in entries) > 10 * 1024 * 1024:
            raise ValueError("Unexpected release archive contents.")
        for path in paths:
            parts = PurePosixPath(path).parts
            if len(parts) != 2 or parts[0] != "IOU" or parts[1] in {".", ".."} or "\\" in path or ":" in path:
                raise ValueError("Release files must be directly inside IOU/.")
        toc = package.read("IOU/IOU.toc").decode("utf-8-sig")
        if re.findall(r"^## Version:\s*(\S+)\s*$", toc, re.MULTILINE) != [version]:
            raise ValueError("Tag and packaged TOC version do not match.")
        if re.findall(r"^## Interface:\s*(\S+)\s*$", toc, re.MULTILINE) != ["16001"]:
            raise ValueError("This publisher only supports the Forever 16001 addon.")
        declared_project = re.findall(r"^## X-Curse-Project-ID:\s*(\S+)\s*$", toc, re.MULTILINE)
        if declared_project and declared_project != [str(project_id)]:
            raise ValueError("Packaged CurseForge project ID does not match the destination.")
        changelog = package.read("IOU/CHANGELOG.md").decode("utf-8-sig")
        if len(changelog.encode("utf-8")) > 128 * 1024:
            raise ValueError("Changelog is too large.")
    return version, digest, changelog


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("CurseForge redirected the authenticated request; upload stopped.")


def api(path: str, token: str, data: bytes | None = None, content_type: str | None = None):
    headers = {"X-Api-Token": token, "Accept": "application/json", "User-Agent": "PhilForever-IOU-release"}
    if content_type:
        headers["Content-Type"] = content_type
    request = Request(API + path, data=data, headers=headers, method="POST" if data is not None else "GET")
    try:
        with build_opener(NoRedirect()).open(request, timeout=45) as response:
            return json.loads(response.read(1024 * 1024))
    except HTTPError as error:
        # Never print authentication headers, a token URL, or unfiltered server text.
        detail = error.read(2048).decode("utf-8", errors="replace").replace(token, "[redacted]")
        detail = re.sub(r"[\x00-\x1f\x7f]", " ", detail)[:400]
        raise ValueError(f"CurseForge API HTTP {error.code}: {detail}") from None


def game_version_id(versions) -> int:
    if not isinstance(versions, list):
        raise ValueError("CurseForge returned an unexpected game-version response.")
    matches = {item["id"] for item in versions if isinstance(item, dict)
               and item.get("name") == GAME_VERSION and type(item.get("id")) is int and item["id"] > 0}
    if len(matches) != 1:
        raise ValueError(f"Could not unambiguously resolve Forever {GAME_VERSION} on CurseForge.")
    return matches.pop()


def multipart(metadata: dict, archive: Path) -> tuple[bytes, str]:
    boundary = "IOUUpload" + uuid.uuid4().hex
    payload = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\n'
        'Content-Type: application/json\r\n\r\n'
    ).encode() + json.dumps(metadata, ensure_ascii=False).encode("utf-8")
    payload += (
        f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{archive.name}"\r\n'
        'Content-Type: application/zip\r\n\r\n'
    ).encode() + archive.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    return payload, "multipart/form-data; boundary=" + boundary


def publish(archive: Path, checksum: Path, tag: str, project_id: int, token: str, receipt: Path, request=api):
    if type(project_id) is not int or project_id <= 0:
        raise ValueError("Configure a positive CF_PROJECT_ID Actions variable.")
    if not token or token.strip() != token or "\n" in token or "\r" in token:
        raise ValueError("Configure the CF_API_KEY Actions secret with a CurseForge upload token.")
    version, digest, changelog = inspect_release(archive, checksum, tag, project_id)
    if receipt.exists():
        previous = json.loads(receipt.read_text(encoding="utf-8"))
        if previous.get("projectId") != project_id or previous.get("tag") != tag or previous.get("sha256") != digest or type(previous.get("fileId")) is not int or previous["fileId"] <= 0:
            raise ValueError("Existing CurseForge receipt conflicts with this release; investigate before uploading again.")
        return previous
    version_id = game_version_id(request("/api/game/versions", token))
    metadata = {"changelog": changelog, "changelogType": "markdown", "displayName": "IOU " + version,
                "gameVersions": [version_id], "releaseType": release_type(version)}
    body, content_type = multipart(metadata, archive)
    # No automatic POST retry: an ambiguous response could otherwise create duplicate files.
    result = request(f"/api/projects/{project_id}/upload-file", token, body, content_type)
    if not isinstance(result, dict) or type(result.get("id")) is not int or result["id"] <= 0:
        raise ValueError("Upload returned no valid file ID; inspect CurseForge before retrying.")
    record = {"projectId": project_id, "tag": tag, "sha256": digest, "fileId": result["id"],
              "releaseType": metadata["releaseType"], "gameVersion": GAME_VERSION, "gameVersionId": version_id}
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--checksum", type=Path)
    parser.add_argument("--project-id", type=int, default=0)
    parser.add_argument("--receipt", type=Path, default=Path("artifacts/curseforge-upload.json"))
    parser.add_argument("--check-tag-only", action="store_true")
    parser.add_argument("--prepare-intent", type=Path, help="Verify the artifact and create an intent before any API upload")
    args = parser.parse_args()
    try:
        release_version(args.tag)
        if args.check_tag_only:
            return 0
        if args.archive is None or args.checksum is None:
            raise ValueError("The release archive and checksum are required.")
        if args.prepare_intent is not None:
            if args.project_id <= 0:
                raise ValueError("Configure a positive CF_PROJECT_ID Actions variable.")
            _, digest, _ = inspect_release(args.archive, args.checksum, args.tag, args.project_id)
            args.prepare_intent.parent.mkdir(parents=True, exist_ok=True)
            args.prepare_intent.write_text(json.dumps({"projectId": args.project_id, "tag": args.tag, "sha256": digest}, indent=2) + "\n", encoding="utf-8")
            print("Verified artifact; prepared upload intent without contacting CurseForge.")
            return 0
        result = publish(args.archive, args.checksum, args.tag, args.project_id,
                         os.environ.get("CF_API_KEY", ""), args.receipt)
        print(f"CurseForge accepted file {result['fileId']} for project {result['projectId']} ({result['releaseType']}, {GAME_VERSION}).")
        print("The file may still require CurseForge processing or moderation.")
    except (OSError, ValueError, KeyError, BadZipFile) as error:
        print("CurseForge publish failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
