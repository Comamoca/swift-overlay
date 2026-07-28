#!/usr/bin/env python3
"""Generate README.md from swift_hashes.json using Jinja2 template."""
import json
from pathlib import Path
from typing import Dict, List

from jinja2 import Template


def load_swift_hashes() -> Dict:
    """Load swift_hashes.json file."""
    file_path = Path(__file__).parent.parent / "swift_hashes.json"
    with open(file_path, "r") as f:
        return json.load(f)


def extract_versions(swift_data: Dict) -> List[str]:
    """Extract and sort version list from swift_hashes.json."""
    versions = []

    for version in swift_data.keys():
        if version == "latest":
            continue
        versions.append(version)

    def version_sort_key(version: str):
        if version == "nightly":
            return (0, 0, 0, -1, 0)
        if "-rc" in version:
            base_version, rc_part = version.split("-rc", 1)
            rc_num = int(rc_part) if rc_part.isdigit() else 0
            return tuple(map(int, base_version.split("."))) + (0, rc_num)
        else:
            return tuple(map(int, version.split("."))) + (1, 0)

    versions.sort(key=version_sort_key, reverse=True)
    return versions


def get_supported_platforms(swift_data: Dict) -> List[str]:
    """Get list of supported platforms."""
    platforms = set()
    for version_data in swift_data.values():
        if isinstance(version_data, dict):
            platforms.update(version_data.keys())
    return sorted(list(platforms))


def generate_platform_version_matrix(swift_data: Dict, versions: List[str], platforms: List[str]) -> str:
    """Generate markdown table showing platform support for each version."""
    table = "| Version |"
    for platform in platforms:
        table += f" {platform} |"
    table += "\n"

    table += "|---------|"
    for _ in platforms:
        table += "---------|"
    table += "\n"

    for version in versions:
        table += f"| `{version}` |"
        version_data = swift_data.get(version, {})
        for platform in platforms:
            if platform in version_data:
                table += " ✅ |"
            else:
                table += " ❌ |"
        table += "\n"

    return table


def generate_platforms_list(platforms: List[str]) -> str:
    """Generate markdown list for platforms."""
    return "\n".join(f"- `{p}`" for p in platforms)


def generate_readme_content(swift_data: Dict, versions: List[str], platforms: List[str]) -> str:
    """Generate README.md content using template."""
    template_path = Path(__file__).parent.parent / "doc_templates" / "README.md.j2"
    with open(template_path, "r") as f:
        template_content = f.read()

    template = Template(template_content)

    platforms_list = generate_platforms_list(platforms)
    platform_version_matrix = generate_platform_version_matrix(swift_data, versions, platforms)

    return template.render(
        platforms_list=platforms_list,
        platform_version_matrix=platform_version_matrix,
    )


def main():
    try:
        swift_data = load_swift_hashes()
        versions = extract_versions(swift_data)
        platforms = get_supported_platforms(swift_data)

        readme_content = generate_readme_content(swift_data, versions, platforms)

        readme_path = Path(__file__).parent.parent / "README.md"
        with open(readme_path, "w") as f:
            f.write(readme_content)

        print(f"Generated README.md with {len(versions)} versions and {len(platforms)} platforms")

    except Exception as e:
        print(f"Error generating README: {e}")
        raise


if __name__ == "__main__":
    main()
