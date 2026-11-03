#!/usr/bin/env python3
"""Assembles setup-vscode-xcode.sh from src/ (the helper and generator are embedded so the
setup stays a single file people can download). Run after editing anything in src/.
`python3 build.py --check` fails if the committed script is out of date (used by CI)."""
import os, sys

here = os.path.dirname(os.path.abspath(__file__))
src = lambda name: open(os.path.join(here, "src", name), encoding="utf-8").read()
xc, gen = src("xc.sh").rstrip("\n"), src("gen_vscode.py").rstrip("\n")
assert "XCSH_EOF" not in xc and "GENPY_EOF" not in gen
out = src("setup.sh.in").replace("@@XC_SH@@", xc).replace("@@GEN_PY@@", gen)
target = os.path.join(here, "setup-vscode-xcode.sh")

if "--check" in sys.argv:
    current = open(target, encoding="utf-8").read() if os.path.exists(target) else ""
    if current != out:
        sys.exit("setup-vscode-xcode.sh is out of date; run: python3 tools/vscode-xcode-setup/build.py")
    print("setup-vscode-xcode.sh is up to date")
else:
    with open(target, "w", encoding="utf-8") as f:
        f.write(out)
    os.chmod(target, 0o755)
    print("wrote", target)
