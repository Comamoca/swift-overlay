#!/usr/bin/env python3
"""
Fetch Swift releases from swift.org and compute SHA256 hashes.

This script:
1. Fetches stable release info from the swift.org releases API
2. Constructs download URLs for each platform
3. Computes SHA256 hashes using `nix store prefetch-file`
4. Writes swift_hashes.json
"""
import json
import subprocess
import sys
from typing import Any

import requests

USER_AGENT = "swift-overlay-fetch-script/2.0"
HASHES_FILE = "swift_hashes.json"

RELEASES_API = "https://www.swift.org/api/v1/install/releases.json"
DEV_API = "https://www.swift.org/api/v1/install/dev/{branch}/{platform}.json"
DOWNLOAD_ROOT = "https://download.swift.org"

# Only releases with a UBI9 tarball are usable on Linux (the overlay's FHS
# packaging is built around the Red Hat Universal Base Image 9 layout).
LINUX_ARCHES = {
    "x86_64": "x86_64-linux",
    "aarch64": "aarch64-linux",
}


def get_sha256_hash(url: str) -> str:
    """Calculate SHA256 hash using nix store prefetch-file."""
    result = subprocess.run(
        ["nix", "store", "prefetch-file", "--json", "--hash-type", "sha256", url],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to fetch {url}: {result.stderr}")

    try:
        return json.loads(result.stdout)["hash"]
    except (json.JSONDecodeError, KeyError) as e:
        raise RuntimeError(f"Could not parse JSON output: {e}") from e


def fetch_stable_releases() -> list[dict[str, str]]:
    """Fetch the list of stable Swift releases from the swift.org API.

    Returns releases that ship a UBI9 tarball, newest first.
    """
    response = requests.get(
        RELEASES_API,
        headers={"User-Agent": USER_AGENT},
        timeout=30,
    )
    response.raise_for_status()

    releases = []
    for entry in response.json():
        name = entry.get("name", "")
        tag = entry.get("tag", "")
        # Only keep releases that provide the UBI9 (Red Hat Universal Base
        # Image 9) tarball the overlay packages.
        has_ubi9 = any(p.get("dir") == "ubi9" for p in entry.get("platforms", []))
        if name and tag and has_ubi9:
            releases.append({"version": name, "tag": tag})

    # Newest first.
    releases.sort(
        key=lambda r: tuple(int(n) for n in r["version"].split(".")),
        reverse=True,
    )
    return releases


def construct_url(version: str, platform_code: str, arch: str = "x86_64") -> str:
    """
    Construct Swift binary download URL.

    Layout (verified against apple/swift-docker rhel-ubi/9 Dockerfile):
      {webroot}/{branch}/{platform}{arch_suffix}/{tag}/{tag}-{platform}{arch_suffix}.tar.gz
    For Linux, platform is "ubi9"; arch_suffix is "" (x86_64) or "-aarch64".

    Args:
        version: Swift version (e.g. "6.3.3")
        platform_code: Platform code (e.g. "ubi9")
        arch: Architecture ("x86_64" or "aarch64")

    Returns:
        Full download URL
    """
    release_tag = f"swift-{version}-RELEASE"
    arch_suffix = "-aarch64" if arch == "aarch64" else ""

    return (
        f"{DOWNLOAD_ROOT}/{release_tag.lower()}/"
        f"{platform_code}{arch_suffix}/"
        f"{release_tag}/"
        f"{release_tag}-{platform_code}{arch_suffix}.tar.gz"
    )


def fetch_dev_snapshots(branch: str) -> dict[str, dict[str, str]]:
    """
    Fetch development snapshots for a given branch from the Swift API.

    Args:
        branch: Swift branch (e.g. "6.3", "main")

    Returns:
        Dict mapping architecture to {url, sha256}
    """
    assets: dict[str, dict[str, str]] = {}
    url = DEV_API.format(branch=branch, platform="ubi9")
    try:
        response = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=15)
        response.raise_for_status()
        data = response.json()
    except (requests.RequestException, ValueError) as e:
        print(f"  Failed to fetch dev snapshots for {branch}: {e}")
        return assets

    # The API reports `dir` (snapshot directory) and `download` (file name)
    # relative to download.swift.org. The branch maps to a path prefix:
    #   main -> development, 6.3 -> swift-6.3-branch, ...
    branch_path = "development" if branch == "main" else f"swift-{branch}-branch"

    for arch_key, arch_name in LINUX_ARCHES.items():
        entries = data.get(arch_key) or []
        if not entries:
            continue
        snapshot = entries[0]
        snapshot_dir = snapshot.get("dir")
        download_name = snapshot.get("download")
        if not snapshot_dir or not download_name:
            continue
        # Layout: {root}/{branch_path}/ubi9[-aarch64]/{dir}/{download}
        arch_suffix = "" if arch_key == "x86_64" else "-aarch64"
        download_url = (
            f"{DOWNLOAD_ROOT}/{branch_path}/ubi9{arch_suffix}/"
            f"{snapshot_dir}/{download_name}"
        )
        try:
            assets[arch_name] = {
                "url": download_url,
                "sha256": get_sha256_hash(download_url),
            }
        except Exception as e:
            print(f"  Failed to get hash for {arch_name}: {e}")

    return assets


def url_is_available(url: str) -> bool:
    """Check whether a download URL exists (HEAD request)."""
    response = requests.head(
        url,
        headers={"User-Agent": USER_AGENT},
        timeout=10,
        allow_redirects=True,
    )
    return response.status_code == 200


def collect_release_assets(release: dict[str, str]) -> dict[str, dict[str, str]]:
    """Collect download URLs + hashes for every platform of one release."""
    version = release["version"]
    assets: dict[str, dict[str, str]] = {}

    for arch, arch_key in LINUX_ARCHES.items():
        url = construct_url(version, "ubi9", arch)
        try:
            if not url_is_available(url):
                print(f"  ubi9/{arch}: Not found")
                continue
            assets[arch_key] = {"url": url, "sha256": get_sha256_hash(url)}
            print(f"  {arch_key}: OK")
        except Exception as e:
            print(f"  ubi9/{arch}: Error - {e}")

    # The official -osx.pkg is a universal binary, but we only expose
    # aarch64-darwin because nixpkgs 26.11+ no longer supports x86_64-darwin.
    darwin_url = (
        f"{DOWNLOAD_ROOT}/swift-{version}-release/"
        f"xcode/swift-{version}-RELEASE/"
        f"swift-{version}-RELEASE-osx.pkg"
    )
    try:
        if not url_is_available(darwin_url):
            print("  darwin: Not found")
            return assets
        assets["aarch64-darwin"] = {"url": darwin_url, "sha256": get_sha256_hash(darwin_url)}
        print("  darwin: OK (aarch64 only)")
    except Exception as e:
        print(f"  darwin: Error - {e}")

    return assets


def main() -> None:
    try:
        # Fetch stable releases from swift.org
        print("Fetching stable releases from swift.org...")
        releases = fetch_stable_releases()
        print(f"Found {len(releases)} releases")

        assets_data: dict[str, Any] = {}

        # Limit to latest 10 releases for efficiency
        for release in releases[:10]:
            print(f"Processing Swift {release['version']}...")
            version_assets = collect_release_assets(release)
            if version_assets:
                assets_data[release["version"]] = version_assets

        # Try to fetch dev snapshots
        print("Fetching development snapshots...")
        nightly_assets: dict[str, dict[str, str]] = {}
        for branch in ["main", "6.3", "6.2"]:
            nightly_assets.update(fetch_dev_snapshots(branch))

        if nightly_assets:
            assets_data["nightly"] = nightly_assets
            print(f"Nightly assets found for {len(nightly_assets)} platforms")

        # Write output
        with open(HASHES_FILE, "w", encoding="utf-8") as f:
            json.dump(assets_data, f, indent=2)

        version_count = len([k for k in assets_data if k != "nightly"])
        print(f"\nDone! Wrote {version_count} versions to {HASHES_FILE}")

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
