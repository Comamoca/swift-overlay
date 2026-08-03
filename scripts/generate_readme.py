#!/usr/bin/env python3
"""Generate README.md from swift_hashes.json using Jinja2 template."""
import json
from pathlib import Path
from typing import Any

from jinja2 import Template

REPO_ROOT = Path(__file__).parent.parent


def load_swift_hashes() -> dict[str, Any]:
    """Load swift_hashes.json file."""
    with open(REPO_ROOT / "swift_hashes.json", encoding="utf-8") as f:
        return json.load(f)


def extract_versions(swift_data: dict[str, Any]) -> list[str]:
    """Extract and sort version list from swift_hashes.json."""
    versions = [v for v in swift_data if v != "latest"]

    def version_sort_key(version: str):
        if version == "nightly":
            return (0, 0, 0, -1, 0)
        if "-rc" in version:
            base_version, rc_part = version.split("-rc", 1)
            rc_num = int(rc_part) if rc_part.isdigit() else 0
            return tuple(map(int, base_version.split("."))) + (0, rc_num)
        return tuple(map(int, version.split("."))) + (1, 0)

    versions.sort(key=version_sort_key, reverse=True)
    return versions


def get_supported_platforms(swift_data: dict[str, Any]) -> list[str]:
    """Get list of supported platforms."""
    platforms = set()
    for version_data in swift_data.values():
        if isinstance(version_data, dict):
            platforms.update(version_data)
    return sorted(platforms)


def generate_platform_version_matrix(
    swift_data: dict[str, Any], versions: list[str], platforms: list[str]
) -> str:
    """Generate markdown table showing platform support for each version."""
    lines = ["| Version |" + "".join(f" {p} |" for p in platforms)]
    lines.append("|---------|" + "---------|" * len(platforms))
    for version in versions:
        row = [f"| `{version}` |"]
        version_data = swift_data.get(version, {})
        row.extend(" ✅ |" if p in version_data else " ❌ |" for p in platforms)
        lines.append("".join(row))
    return "\n".join(lines)


def generate_platforms_list(platforms: list[str]) -> str:
    """Generate markdown list for platforms."""
    return "\n".join(f"- `{p}`" for p in platforms)


def generate_readme_content(
    swift_data: dict[str, Any], versions: list[str], platforms: list[str]
) -> str:
    """Generate README.md content using template."""
    with open(REPO_ROOT / "doc_templates" / "README.md.j2", encoding="utf-8") as f:
        template = Template(f.read())

    return template.render(
        platforms_list=generate_platforms_list(platforms),
        platform_version_matrix=generate_platform_version_matrix(swift_data, versions, platforms),
    )


def main() -> None:
    try:
        swift_data = load_swift_hashes()
        versions = extract_versions(swift_data)
        platforms = get_supported_platforms(swift_data)

        readme_path = REPO_ROOT / "README.md"
        readme_path.write_text(
            generate_readme_content(swift_data, versions, platforms), encoding="utf-8"
        )

        print(f"Generated README.md with {len(versions)} versions and {len(platforms)} platforms")

    except Exception as e:
        print(f"Error generating README: {e}")
        raise


if __name__ == "__main__":
    main()
