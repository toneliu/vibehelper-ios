#!/usr/bin/env python3
"""Compute VibeHelper client fingerprints/versions and publish packages to the Host update directory.

Bump NATIVE_VERSION whenever native Kotlin/Swift code, AndroidManifest/Info.plist permissions,
Live Activity assets/fonts, or native plugins change so clients automatically detect that a
full APK/IPA reinstall is required instead of a hot update.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
from typing import Any

NATIVE_VERSION = 10

NATIVE_WATCH_PATHS = (
    "client-app/assets/android_overlay",
    "client-app/assets/ios_live_activity",
    "scripts/patch_android.py",
    "scripts/patch_ios.py",
    "client-app/pubspec.yaml",
)

DART_WATCH_PATHS = ("client-app/lib",)

PLATFORM_FILENAMES = {
    "android": "vibehelper-client-android.apk",
    "ios": "vibehelper-client-ios.ipa",
    "windows": "vibehelper-client-win64.zip",
}


def _hash_paths(repo_root: pathlib.Path, rel_paths: tuple[str, ...]) -> str:
    h = hashlib.sha256()
    files: list[pathlib.Path] = []
    for rel in rel_paths:
        p = repo_root / rel
        if p.is_file():
            files.append(p)
        elif p.is_dir():
            for child in sorted(p.rglob("*")):
                if child.is_file():
                    files.append(child)
    for f in sorted(set(files)):
        rel_str = f.relative_to(repo_root).as_posix()
        h.update(rel_str.encode("utf-8"))
        h.update(b"\x00")
        h.update(f.read_bytes())
        h.update(b"\x00")
    return h.hexdigest()[:12]


def _sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def read_pubspec_version(repo_root: pathlib.Path) -> tuple[str, int]:
    pubspec = repo_root / "client-app" / "pubspec.yaml"
    if pubspec.is_file():
        m = re.search(
            r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)",
            pubspec.read_text(encoding="utf-8"),
            re.M,
        )
        if m:
            return m.group(1), int(m.group(2))
    return "0.7.0", 7


def _git_short_sha(repo_root: pathlib.Path) -> str:
    try:
        res = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--short=7", "HEAD"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except Exception:
        pass
    return "local"


def compute_metadata(repo_root: pathlib.Path, *, build_id: str | None = None) -> dict[str, Any]:
    app_ver, build_num = read_pubspec_version(repo_root)
    return {
        "version": app_ver,
        "build_number": build_num,
        "native_version": NATIVE_VERSION,
        "native_fingerprint": _hash_paths(repo_root, NATIVE_WATCH_PATHS),
        "dart_fingerprint": _hash_paths(repo_root, DART_WATCH_PATHS),
        "build_id": (build_id or _git_short_sha(repo_root)).strip() or "local",
    }


def build_github_altstore_source(
    *,
    meta: dict[str, Any],
    ipa_size: int,
    download_url: str,
    updated_at: str,
    changelog: str = "",
    bundle_id: str = "com.example.vibehelperClient",
    icon_url: str = "",
) -> dict[str, Any]:
    """Build an AltStore / SideStore v2 compatible JSON source pointing to an HTTPS IPA URL."""
    ver = str(meta.get("version") or "0.7.0")
    build_num = str(meta.get("build_number") or "1")
    build_id = str(meta.get("build_id") or "").strip()
    safe_bid = re.sub(r"[^a-zA-Z0-9._-]", "", bundle_id) or "com.example.vibehelperClient"
    desc = (changelog or "").strip() or (
        f"VibeHelper iOS v{ver} ({build_id or build_num}) · 支持后台灵动岛像素宠物动画与语音协同"
    )
    clean_dl = download_url.strip()
    version_entry: dict[str, Any] = {
        "version": ver,
        "buildVersion": build_num,
        "date": updated_at,
        "localizedDescription": desc,
        "downloadURL": clean_dl,
        "size": int(ipa_size),
        "minOSVersion": "15.0",
    }
    app_entry: dict[str, Any] = {
        "name": "VibeHelper",
        "bundleIdentifier": safe_bid,
        "developerName": "VibeHelper",
        "subtitle": "远程 AI IDE 控制台与灵动岛协同",
        "localizedDescription": (
            "通过 GitHub Releases (HTTPS) 自动分发 VibeHelper iOS IPA，"
            "兼容 AltStore / SideStore，一键保活灵动岛与远程控制 AI IDE。"
        ),
        "tintColor": "#4F46E5",
        "category": "developer",
        "versions": [version_entry] if clean_dl else [],
        "appPermissions": {
            "entitlements": [],
            "privacy": {
                "NSMicrophoneUsageDescription": "VibeHelper 需要麦克风权限，用于远程语音输入与实时语音直传",
                "NSLocalNetworkUsageDescription": "VibeHelper 需要访问局域网，以连接同一 Wi-Fi 或 VPN 下的桌面宿主机与 AI IDE",
                "NSSpeechRecognitionUsageDescription": "VibeHelper 需要语音识别权限，将您的语音指令实时转为开发对话",
            },
        },
    }
    if icon_url.strip():
        app_entry["iconURL"] = icon_url.strip()
    return {
        "name": "VibeHelper (GitHub)",
        "identifier": "com.vibehelper.github.source",
        "subtitle": "VibeHelper iOS 自动构建更新源 (GitHub Releases HTTPS)",
        "tintColor": "#4F46E5",
        "apps": [app_entry],
        "news": [],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Compute VibeHelper update manifest / dart-defines")
    parser.add_argument(
        "--repo-root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
    )
    parser.add_argument("--build-id", default="", help="Override git short SHA build ID")
    parser.add_argument("--print-dart-defines", action="store_true")
    parser.add_argument("--print-json", action="store_true")
    parser.add_argument("--publish-dir", type=pathlib.Path, default=None)
    parser.add_argument("--android-apk", type=pathlib.Path, default=None)
    parser.add_argument("--ios-ipa", type=pathlib.Path, default=None)
    parser.add_argument("--windows-zip", type=pathlib.Path, default=None)
    parser.add_argument("--changelog", default="", help="Optional changelog note")
    parser.add_argument("--altstore-out", type=pathlib.Path, default=None)
    parser.add_argument("--altstore-download-url", default="")
    parser.add_argument("--bundle-id", default="com.example.vibehelperClient")
    parser.add_argument("--icon-url", default="")
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    meta = compute_metadata(repo_root, build_id=args.build_id or None)

    if args.print_dart_defines:
        flags = [
            f"--dart-define=VH_APP_VERSION={meta['version']}",
            f"--dart-define=VH_BUILD_NUMBER={meta['build_number']}",
            f"--dart-define=VH_NATIVE_VERSION={meta['native_version']}",
            f"--dart-define=VH_NATIVE_FP={meta['native_fingerprint']}",
            f"--dart-define=VH_DART_FP={meta['dart_fingerprint']}",
            f"--dart-define=VH_BUILD_ID={meta['build_id']}",
        ]
        print(" ".join(flags))
        return 0

    now_iso = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out_dir: pathlib.Path | None = None
    if args.publish_dir is not None:
        out_dir = args.publish_dir.expanduser().resolve()
        out_dir.mkdir(parents=True, exist_ok=True)
        manifest_path = out_dir / "manifest.json"
        existing: dict[str, Any] = {}
        if manifest_path.is_file():
            try:
                loaded = json.loads(manifest_path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    existing = loaded
            except Exception:
                pass

        packages = existing.get("packages") if isinstance(existing.get("packages"), dict) else {}

        artifacts = {
            "android": args.android_apk,
            "ios": args.ios_ipa,
            "windows": args.windows_zip,
        }
        for plat, src in artifacts.items():
            if src is None:
                continue
            src_resolved = src.expanduser().resolve()
            if not src_resolved.is_file():
                raise FileNotFoundError(f"Missing {plat} artifact: {src_resolved}")
            dest_name = PLATFORM_FILENAMES[plat]
            dest = out_dir / dest_name
            if src_resolved != dest:
                shutil.copy2(src_resolved, dest)
            packages[plat] = {
                "filename": dest_name,
                "version": meta["version"],
                "build_number": meta["build_number"],
                "native_version": meta["native_version"],
                "native_fingerprint": meta["native_fingerprint"],
                "dart_fingerprint": meta["dart_fingerprint"],
                "build_id": meta["build_id"],
                "sha256": _sha256_file(dest),
                "size_bytes": dest.stat().st_size,
                "updated_at": now_iso,
                "changelog": args.changelog or f"v{meta['version']} ({meta['build_id']})",
            }

        manifest = {
            "version": meta["version"],
            "build_number": meta["build_number"],
            "native_version": meta["native_version"],
            "native_fingerprint": meta["native_fingerprint"],
            "dart_fingerprint": meta["dart_fingerprint"],
            "build_id": meta["build_id"],
            "updated_at": now_iso,
            "packages": packages,
        }
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Published update manifest to {manifest_path}")

    if args.altstore_out is not None:
        ipa_candidate = args.ios_ipa.expanduser().resolve() if args.ios_ipa is not None else None
        if (ipa_candidate is None or not ipa_candidate.is_file()) and out_dir is not None:
            fallback_ipa = out_dir / PLATFORM_FILENAMES["ios"]
            if fallback_ipa.is_file():
                ipa_candidate = fallback_ipa
        ipa_size = ipa_candidate.stat().st_size if (ipa_candidate is not None and ipa_candidate.is_file()) else 0
        alt_out = args.altstore_out.expanduser().resolve()
        alt_out.parent.mkdir(parents=True, exist_ok=True)
        alt_payload = build_github_altstore_source(
            meta=meta,
            ipa_size=ipa_size,
            download_url=args.altstore_download_url,
            updated_at=now_iso,
            changelog=args.changelog,
            bundle_id=args.bundle_id,
            icon_url=args.icon_url,
        )
        alt_out.write_text(
            json.dumps(alt_payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Published AltStore source to {alt_out}")

    if args.publish_dir is not None or args.altstore_out is not None:
        if not args.print_json:
            return 0

    print(json.dumps(meta, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
