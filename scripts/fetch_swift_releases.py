#!/usr/bin/env python3
"""
Fetch Swift releases from swift.org and compute SHA256 hashes.

This script:
1. Fetches stable release info from swift.org/download/
2. Constructs download URLs for each platform
3. Computes SHA256 hashes using `nix store prefetch-file`
4. Writes swift_hashes.json
"""
import json
import re
import subprocess
import sys
from typing import Dict, List, Optional

import requests


def get_sha256_hash(url: str) -> str:
    """Calculate SHA256 hash using nix store prefetch-file."""
    result = subprocess.run(
        ["nix", "store", "prefetch-file", "--json", "--hash-type", "sha256", url],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise Exception(f"Failed to fetch {url}: {result.stderr}")

    try:
        output_data = json.loads(result.stdout.strip())
        return output_data["hash"]
    except (json.JSONDecodeError, KeyError) as e:
        raise Exception(f"Could not parse JSON output: {e}")


def fetch_releases_from_swift_org() -> List[Dict]:
    """
    Fetch Swift releases by scraping swift.org/download/.
    Returns list of dicts with version info.
    """
    url = "https://swift.org/download/"
    headers = {"User-Agent": "swift-overlay-fetch-script/1.0"}

    response = requests.get(url, headers=headers, timeout=30)
    response.raise_for_status()

    html = response.text
    releases = []

    # Match release entries in the download page
    # Pattern: look for swift-X.Y.Z-RELEASE links
    pattern = r'swift-(\d+\.\d+(?:\.\d+)?)-RELEASE'
    matches = re.findall(pattern, html)

    seen = set()
    for version in matches:
        if version not in seen:
            seen.add(version)
            releases.append({
                "version": version,
                "tag": f"swift-{version}-RELEASE",
            })

    # Sort by version descending
    releases.sort(
        key=lambda x: tuple(int(n) for n in x["version"].split(".")),
        reverse=True,
    )

    return releases


def construct_url(version: str, platform_code: str, arch: str = "x86_64") -> str:
    """
    Construct Swift binary download URL.

    Args:
        version: Swift version (e.g. "6.3.3")
        platform_code: Platform code (e.g. "ubuntu2204", "ubuntu2404")
        arch: Architecture ("x86_64" or "aarch64")

    Returns:
        Full download URL
    """
    release_tag = f"swift-{version}-RELEASE"
    arch_suffix = "-aarch64" if arch == "aarch64" else ""

    # Platform name for filename (ubuntu22.04 vs ubuntu2204)
    platform_name_map = {
        "ubuntu2204": "ubuntu22.04",
        "ubuntu2404": "ubuntu24.04",
    }

    dir_platform = platform_code
    file_platform = platform_name_map.get(platform_code, platform_code)
    arch_file_suffix = "-aarch64" if arch == "aarch64" else ""

    return (
        f"https://download.swift.org/{release_tag.lower()}/"
        f"{dir_platform}{arch_suffix}/"
        f"{release_tag}/"
        f"{release_tag}-{file_platform}{arch_file_suffix}.tar.gz"
    )


def fetch_dev_snapshots(branch: str) -> Dict[str, Dict[str, str]]:
    """
    Fetch development snapshots for a given branch from the Swift API.

    Args:
        branch: Swift branch (e.g. "6.3", "main")

    Returns:
        Dict mapping architecture to {url, sha256}
    """
    platforms = ["ubuntu2204", "ubuntu2404"]
    assets = {}

    headers = {"User-Agent": "swift-overlay-fetch-script/1.0"}

    for platform in platforms:
        url = f"https://swift.org/api/v1/install/dev/{branch}/{platform}.json"
        try:
            response = requests.get(url, headers=headers, timeout=15)
            response.raise_for_status()
            data = response.json()

            for arch_key, arch_name in [("x86_64", "x86_64-linux"),
                                         ("aarch64", "aarch64-linux")]:
                if arch_key in data and len(data[arch_key]) > 0:
                    latest = data[arch_key][0]
                    download_url = latest.get("download")
                    if download_url:
                        try:
                            sha256_hash = get_sha256_hash(download_url)
                            assets[arch_name] = {
                                "url": download_url,
                                "sha256": sha256_hash,
                            }
                        except Exception as e:
                            print(f"  Failed to get hash for {arch_name}: {e}")
        except Exception as e:
            print(f"  Failed to fetch dev snapshots for {branch}/{platform}: {e}")

    return assets


def main():
    try:
        # Fetch stable releases from swift.org
        print("Fetching stable releases from swift.org...")
        releases = fetch_releases_from_swift_org()
        print(f"Found {len(releases)} releases")

        # Platforms to check
        linux_platforms = [
            ("ubuntu2204", "x86_64"),
            ("ubuntu2204", "aarch64"),
            ("ubuntu2404", "x86_64"),
            ("ubuntu2404", "aarch64"),
        ]

        darwin_url = (
            "https://download.swift.org/swift-{version}-release/"
            "xcode/swift-{version}-RELEASE/"
            "swift-{version}-RELEASE-osx.pkg"
        )

        assets_data = {}

        # Limit to latest 10 releases for efficiency
        for release in releases[:10]:
            version = release["version"]
            print(f"Processing Swift {version}...")
            version_assets = {}

            # Linux URLs
            for platform_code, arch in linux_platforms:
                try:
                    url = construct_url(version, platform_code, arch)
                    # Check if URL exists (HEAD request)
                    resp = requests.head(
                        url,
                        headers={"User-Agent": "swift-overlay-fetch-script/1.0"},
                        timeout=10,
                        allow_redirects=True,
                    )
                    if resp.status_code == 200:
                        arch_key = f"{arch}-linux"
                        sha256_hash = get_sha256_hash(url)
                        version_assets[arch_key] = {
                            "url": url,
                            "sha256": sha256_hash,
                        }
                        print(f"  {arch_key}: OK")
                    else:
                        print(f"  {platform_code}/{arch}: Not found")
                except Exception as e:
                    print(f"  {platform_code}/{arch}: Error - {e}")

            # macOS URL
            try:
                url = darwin_url.format(version=version)
                resp = requests.head(
                    url,
                    headers={"User-Agent": "swift-overlay-fetch-script/1.0"},
                    timeout=10,
                    allow_redirects=True,
                )
                if resp.status_code == 200:
                    sha256_hash = get_sha256_hash(url)
                    version_assets["x86_64-darwin"] = {
                        "url": url,
                        "sha256": sha256_hash,
                    }
                    version_assets["aarch64-darwin"] = {
                        "url": url,
                        "sha256": sha256_hash,
                    }
                    print(f"  darwin: OK (universal)")
                else:
                    print(f"  darwin: Not found")
            except Exception as e:
                print(f"  darwin: Error - {e}")

            if version_assets:
                assets_data[version] = version_assets

        # Try to fetch dev snapshots
        print("Fetching development snapshots...")
        try:
            nightly_assets = {}
            for branch in ["main", "6.3", "6.2"]:
                branch_assets = fetch_dev_snapshots(branch)
                if branch_assets:
                    nightly_assets.update(branch_assets)

            if nightly_assets:
                assets_data["nightly"] = nightly_assets
                print(f"Nightly assets found for {len(nightly_assets)} platforms")
        except Exception as e:
            print(f"Warning: Failed to process nightly builds: {e}")
            print("Continuing with regular releases only...")

        # Write output
        output_file = "swift_hashes.json"
        with open(output_file, "w") as f:
            json.dump(assets_data, f, indent=2)

        version_count = len([k for k in assets_data if k != "nightly"])
        print(f"\nDone! Wrote {version_count} versions to {output_file}")

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
