import os

# import sys
from .lib.module import get_out_path, get_env
from .lib.console import Colors
from pathlib import Path
import subprocess

# TODO: add more binaries here
# expected to fail with a specific message (because they cannot be tested, but they run)
# TODO: improve ?
# brittle to changes in error string
expected_failures = {
    "escodegen": "Invalid option '--help' - perhaps you meant '-c'?",
    "esgenerate": "Invalid option '--help' - perhaps you meant '-c'?",
}
excluded_bins = [
    "browserslist-lint",
    "errno",
    "eslint-config-prettier-check",
    "is-ci",
    "is-docker",
    "json5",
    "multicast-dns",
    "node-gyp-build",
    "node-gyp-build-test",
    "node-which",
    "opener",
    "resolve",  # expects another binary
    "tree-kill",
    "tsserver",
    "webpack",  # needs webpack-cli: expected error: ? "Error: Cannot find module 'webpack-cli/package.json'"
    "webpack-dev-server",  # needs webpack-cli: expected error: "CLI for webpack must be installed."
    "which",
]


def check():
    """
    Tests all binaries in the .bin folder if it exists
    at least one of the following args must succeed
    [--help, --version, index.js, index.ts]
    e.g. "tsc --help"
    while index.js and index.ts are empty files
    """

    bin_dir = get_out_path() / Path("lib/node_modules/.bin")
    sandbox = Path("/build/bin_tests")
    args = ["--help", "--version", "index.js", "index.ts", "-h", "-v", ""]

    sandbox.mkdir(parents=True, exist_ok=True)

    old_cwd = os.getcwd()
    os.chdir(sandbox)

    failed: list[Path] = []
    if bin_dir.exists():
        print(
            f"{Colors.HEADER}Running binary tests {Colors.ENDC}\n",
            f"{Colors.HEADER}└──for all files in: {bin_dir}  {Colors.ENDC}",
        )
        for maybe_binary in sorted(bin_dir.iterdir()):
            if is_broken_symlink(maybe_binary):
                print(
                    f"{Colors.FAIL}🔴 failed: '{maybe_binary.name}' \t broken symlink: {maybe_binary} -> {maybe_binary.resolve()} {Colors.ENDC}"
                )
                failed.append(maybe_binary)

            if is_binary(maybe_binary):
                binary = maybe_binary
                if binary.name in excluded_bins:
                    print(f"{Colors.GREY}ℹ️ skipping: {binary.name}{Colors.ENDC}")
                    continue

                # some scripts process (empty) .ts or .js files
                # re-create empty test files on every testcase
                # to avoid leaking state from previous exectuables
                open(sandbox / Path("index.js"), "w").close()
                open(sandbox / Path("index.ts"), "w").close()

                success = try_args(args, binary)
                if not success:
                    print(
                        f"{Colors.FAIL}🔴 failed: '{binary.name}' \t could not run executable {Colors.ENDC}"
                    )
                    failed.append(binary)
                else:
                    print(f"{Colors.OKGREEN}✅ passed: '{binary.name}' {Colors.ENDC}")

    os.chdir(old_cwd)

    if failed:
        exit(1)


def is_broken_symlink(f: Path) -> bool:
    return f.is_symlink() and not f.exists()


def is_binary(f: Path) -> bool:
    return f.is_file() and os.access(f, os.X_OK)


def try_args(args: list[str], binary: Path) -> bool:
    success = False
    out = []
    for arg in args:
        try:

            completed_process = subprocess.run(
                f"{binary} {arg}".split(" "),
                timeout=10,
                capture_output=True,
            )
            if completed_process.returncode == 0:
                success = True
                break
            else:
                std_out = completed_process.stdout.decode()
                std_err = completed_process.stderr.decode()
                expected_error = expected_failures.get(binary.name, None)

                if expected_error:
                    if expected_error in std_out or expected_error in std_err:
                        success = True
                        break
                out.append(std_out)
                out.append(std_err)

        except subprocess.SubprocessError as error:
            print("aborted SubprocessError: ", error)

    if not success:
        print("\n".join(out))
    return success
