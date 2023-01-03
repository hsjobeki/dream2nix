import json
import os
import pathlib
import sys


with open(os.environ.get("dependenciesJsonPath")) as f:
    available_deps = json.load(f)

with open("package.json", encoding="utf-8-sig") as f:
    package_json = json.load(f)

changed = False

# fail if platform incompatible
if "os" in package_json:
    platform = sys.platform
    if platform not in package_json["os"] or f"!{platform}" in package_json["os"]:
        print(
            f"Package is not compatible with current platform '{platform}'",
            file=sys.stderr,
        )
        exit(3)

# replace version
# If it is a github dependency referred by revision,
# we can not rely on the version inside the package.json.
# In case of an 'unknown' version coming from the dream lock,
# do not override the version from package.json
version = os.environ.get("version")
if version not in ["unknown", package_json.get("version")]:
    print(
        "WARNING: The version of this package defined by its package.json "
        "doesn't match the version expected by dream2nix."
        "\n  -> Replacing version in package.json: "
        f"{package_json.get('version')} -> {version}",
        file=sys.stderr,
    )
    changed = True
    package_json["version"] = version


# pinpoint exact versions
# This is mostly needed to replace git references with exact versions,
# as NPM install will otherwise re-fetch these
if "dependencies" in package_json:
    dependencies = package_json["dependencies"]
    # dependencies can be a list or dict
    for pname in dependencies:
        if (
            "bundledDependencies" in package_json
            and pname in package_json["bundledDependencies"]
        ):
            continue
        if pname not in available_deps:
            print(
                f"WARNING: Dependency {pname} wanted but not available. Ignoring.",
                file=sys.stderr,
            )
            continue
        version = "unknown" if isinstance(dependencies, list) else dependencies[pname]
        if available_deps[pname] != version:
            version = available_deps[pname]
            changed = True
            print(
                f"package.json: Pinning version '{version}' to '{available_deps[pname]}'"
                f" for dependency '{pname}'",
                file=sys.stderr,
            )

# write changes to package.json
if changed:
    with open("package.json", "w") as f:
        json.dump(package_json, f, indent=2)
