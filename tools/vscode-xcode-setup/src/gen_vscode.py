# Writes/merges .vscode/{tasks,launch,settings,extensions}.json. Entries this script owns
# (tasks and launch configs named "Xcode: ...", and a few settings keys) are replaced on every
# run; everything else already in those files is kept.
import json, os, re, shutil, time

VS = ".vscode"
LLDB_LIB = os.environ.get("LLDB_LIB", "")
MARK = "// Managed by setup-vscode-xcode.sh"
XC = "${workspaceFolder}/.vscode/xcode/xc.sh"
STATE = "${workspaceFolder}/.vscode/xcode/.state"


def strip_jsonc(text):
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def load(name):
    path = os.path.join(VS, name)
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    if not raw.startswith(MARK):
        bak = path + ".before-xcode-setup"
        if not os.path.exists(bak):
            shutil.copyfile(path, bak)
            print("  Saved a copy of your original %s as %s" % (path, bak))
    if not raw.strip():
        return {}
    try:
        data = json.loads(strip_jsonc(raw))
        return data if isinstance(data, dict) else {}
    except ValueError:
        bak = path + ".unparseable-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copyfile(path, bak)
        print("  Couldn't parse %s, so it was rebuilt (old copy: %s)" % (path, bak))
        return {}


def save(name, obj, note):
    path = os.path.join(VS, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write("%s. %s\n" % (MARK, note))
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("  Wrote %s" % path)


# xcbeautify marks errors with ❌ / warnings with ⚠️, or [x] / [!] when colors are off.
ERR = {
    "owner": "xcode", "source": "xcode", "fileLocation": "absolute", "severity": "error",
    "pattern": {
        "regexp": r"^(?:(?:❌|\[x\])\s+|(?=/.+:\d+:\d+: error: ))(/.+?):(\d+):(\d+):\s+(?:error:\s+)?(.*)$",
        "file": 1, "line": 2, "column": 3, "message": 4,
    },
}
WARN = {
    "owner": "xcode", "source": "xcode", "fileLocation": "absolute", "severity": "warning",
    "pattern": {
        "regexp": r"^(?:(?:⚠️?|\[!\])\s+|(?=/.+:\d+:\d+: warning: ))(/.+?):(\d+):(\d+):\s+(?:warning:\s+)?(.*)$",
        "file": 1, "line": 2, "column": 3, "message": 4,
    },
}
DEBUG_MATCHER = dict(ERR, background={
    "activeBegin": True,
    "beginsPattern": "XC_DEBUG_PREPARE_BEGIN",
    "endsPattern": "XC_DEBUG_READY",
})


def task(label, args, detail, matchers=None, group=None, reveal="always", focus=False, background=False):
    t = {
        "label": label,
        "detail": detail,
        "type": "process",
        "command": "/bin/bash",
        "args": [XC] + args,
        "options": {"cwd": "${workspaceFolder}"},
        "problemMatcher": matchers if matchers is not None else [],
        "presentation": {"reveal": reveal, "panel": "dedicated", "focus": focus, "clear": True,
                         "showReuseMessage": False},
    }
    if group:
        t["group"] = group
    if background:
        t["isBackground"] = True
    return t


OUR_TASKS = [
    task("Xcode: Build", ["build"], "Build the selected scheme (Shift+Cmd+B)", [ERR, WARN],
         group={"kind": "build", "isDefault": True}),
    task("Xcode: Run", ["run"], "Build, launch on the simulator and show app output (no debugger)", [ERR, WARN]),
    task("Xcode: Prepare Debug", ["debug-prepare"], "Used by F5: build, launch paused, show app output",
         [DEBUG_MATCHER], background=True),
    task("Xcode: Stop App", ["stop"], "Terminate the running app", reveal="silent"),
    task("Xcode: Test", ["test"], "Run the scheme's tests", [ERR, WARN],
         group={"kind": "test", "isDefault": True}),
    task("Xcode: Clean", ["clean"], "Clean build products"),
    task("Xcode: Select Scheme", ["select-scheme", "--prompt"], "Choose which scheme to build", focus=True),
    task("Xcode: Select Simulator", ["select-sim", "--prompt"], "Choose which simulator to run on", focus=True),
    task("Xcode: Refresh Code Completion", ["refresh-index"], "Regenerate buildServer.json for SourceKit-LSP"),
    task("Xcode: Open Simulator", ["open-sim"], "Boot the selected simulator", reveal="silent"),
    task("Xcode: Show Info", ["info"], "Print the scheme, simulator and app paths in use"),
]

OUR_LAUNCH = [{
    "name": "Xcode: Debug",
    "type": "lldb",
    "request": "custom",
    "targetCreateCommands": ['command source -s 1 "%s/target.lldb"' % STATE],
    "processCreateCommands": ['command source -s 1 "%s/process.lldb"' % STATE],
    "preLaunchTask": "Xcode: Prepare Debug",
    "postDebugTask": "Xcode: Stop App",
    "sourceLanguages": ["swift"],
}]


def ours(label):
    return isinstance(label, str) and label.startswith("Xcode: ")


os.makedirs(VS, exist_ok=True)

tasks = load("tasks.json")
tasks["version"] = "2.0.0"
tasks["tasks"] = OUR_TASKS + [t for t in tasks.get("tasks", []) if not ours(t.get("label"))]
save("tasks.json", tasks, 'Tasks named "Xcode: ..." are regenerated on every run; your own tasks are kept.')

launch = load("launch.json")
launch["version"] = "0.2.0"
launch["configurations"] = OUR_LAUNCH + [c for c in launch.get("configurations", []) if not ours(c.get("name"))]
save("launch.json", launch, 'Configurations named "Xcode: ..." are regenerated on every run; your own are kept.')

settings = load("settings.json")
if LLDB_LIB:
    # CodeLLDB's bundled LLDB doesn't understand Swift; use the one that ships with Xcode.
    settings["lldb.library"] = LLDB_LIB
settings["lldb.launch.expressions"] = "native"
settings["swift.autoGenerateLaunchConfigurations"] = False
for key, extra in (
    ("search.exclude", {"**/DerivedData": True, "**/Pods": True, "**/.vscode/xcode/.state": True}),
    ("files.watcherExclude", {"**/DerivedData/**": True, "**/Pods/**": True, "**/.vscode/xcode/.state/**": True}),
):
    cur = settings.get(key) if isinstance(settings.get(key), dict) else {}
    for k, v in extra.items():
        cur.setdefault(k, v)
    settings[key] = cur
save("settings.json", settings, "Xcode-related keys are updated on every run; your other settings are kept.")

ext = load("extensions.json")
recs = [r for r in ext.get("recommendations", []) if isinstance(r, str)]
for r in ("swiftlang.swift-vscode", "vadimcn.vscode-lldb"):
    if r.lower() not in [x.lower() for x in recs]:
        recs.append(r)
ext["recommendations"] = recs
save("extensions.json", ext, "Recommended extensions for Swift + Xcode projects.")
