import json
import os
import pathlib
import sys


dependenciesJsonPath = os.environ.get('dependenciesJsonPath')
with open(dependenciesJsonPath) as f:
  print("fix-package.py: dependenciesJsonPath", dependenciesJsonPath)
  available_deps = json.load(f)


with open('package.json', encoding="utf-8-sig") as f:
  package_json = json.load(f)

changed: bool = False

# fail if platform incompatible
# we can do that in nix?
if 'os' in package_json:
  platform = sys.platform
  if platform not in package_json['os']\
      or f"!{platform}" in package_json['os']:
    print(
      f"Package is not compatible with current platform '{platform}'",
      file=sys.stderr
    )
    exit(3)

# replace version
# If it is a github dependency referred by revision,
# we can not rely on the version inside the package.json.
# In case of an 'unknown' version coming from the dream lock,
# do not override the version from package.json
version = os.environ.get("version")
if version not in ["unknown", package_json.get('version')]:
  print(
    "WARNING: The version of this package defined by its package.json "
    "doesn't match the version expected by dream2nix."
    "\n  -> Replacing version in package.json: "
    f"{package_json.get('version')} -> {version}",
    file=sys.stderr
  )
  changed = True
  package_json['version'] = version

# write changes to package.json
if changed:
  with open('package.json', 'w') as f:
    json.dump(package_json, f, indent=2)


# {
    # name: ""
    # version: ""
#   dependencies: {
#     "prettier": "^1.4.1"
#   }
#   #or
#   dependencies: [
#     "prettier"
#   ]
# }