#!/usr/bin/env bash
# setup-vscode-xcode.sh: one-shot setup to build, run and debug an Xcode project
# in VS Code without opening Xcode.
#
#   bash setup-vscode-xcode.sh [options] [project-folder]
#
# Safe to re-run at any time: it only installs what's missing, keeps your scheme
# and simulator choices, and keeps your own VS Code settings, tasks and launch configs.
set -eo pipefail

VERSION="1.0.0"

usage() {
  cat <<'EOF'
Set up VS Code to build, run and debug an Xcode project without opening Xcode.

Usage: setup-vscode-xcode.sh [options] [project-folder]

  project-folder           Folder containing your .xcodeproj/.xcworkspace (default: current folder)
  -s, --scheme NAME        Scheme to build (default: auto-detect, asks if unclear)
  -d, --simulator NAME     Simulator to run on, e.g. "iPhone 16 Pro" (default: newest iPhone)
  -c, --configuration NAME Build configuration (default: Debug)
  -y, --yes                Never ask; accept every default
      --skip-deps          Don't install Homebrew, VS Code, tools or extensions
      --no-build           Skip the first build (code completion fills in after your first build)
      --no-open            Don't open VS Code at the end
  -h, --help               Show this help
EOF
}

if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; D=""; N=""
fi
STEP=0
STEPS=8
step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d] %s%s\n' "$B" "$STEP" "$STEPS" "$*" "$N"; }
info() { printf '%s▸%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s! %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '\n%s✖ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

ASSUME_YES=0; DO_BUILD=1; DO_OPEN=1; SKIP_DEPS=0
PREF_SCHEME=""; PREF_SIM=""; CONFIGURATION=""; DIR=""
need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (see --help)."; }
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--scheme) need_value "$@"; PREF_SCHEME="$2"; shift 2 ;;
    -d|--simulator) need_value "$@"; PREF_SIM="$2"; shift 2 ;;
    -c|--configuration) need_value "$@"; CONFIGURATION="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --no-build) DO_BUILD=0; shift ;;
    --no-open) DO_OPEN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    -*) die "Unknown option '$1' (see --help)." ;;
    *) [ -z "$DIR" ] || die "Only one project folder, please."; DIR="$1"; shift ;;
  esac
done

can_ask() { [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; }
confirm() {
  local a
  can_ask || return 0
  read -r -p "$1 [Y/n] " a || a=""
  case "$a" in n|N*) return 1 ;; *) return 0 ;; esac
}

# ── 1. Xcode toolchain ─────────────────────────────────────────────────────────
check_xcode() {
  step "Checking Xcode"
  [ "$(uname -s)" = Darwin ] || die "This script needs macOS (Xcode only runs there)."
  command -v python3 >/dev/null 2>&1 || die "python3 is missing. Run: xcode-select --install"

  if ! xcodebuild -version >/dev/null 2>&1; then
    # Usually means only the Command Line Tools are selected.
    local app
    app="$(find /Applications -maxdepth 1 -name 'Xcode*.app' 2>/dev/null | sort | head -n 1)"
    [ -n "$app" ] || die "Xcode isn't installed. Install it from the App Store (you won't need to open it), then re-run this script."
    info "Command Line Tools are selected; switching to $app (needs your password)."
    sudo xcode-select -s "$app/Contents/Developer"
    xcodebuild -version >/dev/null 2>&1 || die "xcodebuild still doesn't work. Try: sudo xcode-select -s $app/Contents/Developer"
  fi
  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    info "Xcode needs its one-time first-launch setup (license + components; needs your password)."
    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch
  fi
  ok "$(xcodebuild -version | head -n 1) at $(xcode-select -p)"

  if command -v DevToolsSecurity >/dev/null 2>&1 && ! DevToolsSecurity -status 2>/dev/null | grep -q enabled; then
    if confirm "Enable Developer Mode for the debugger (so attaching doesn't ask for your password each time)?"; then
      if sudo DevToolsSecurity -enable >/dev/null; then ok "Developer Mode enabled."
      else warn "Couldn't enable Developer Mode; the debugger may ask for your password."; fi
    fi
  fi
}

# ── 2. Homebrew + command-line tools ───────────────────────────────────────────
load_brew() {
  local b
  for b in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -n "$b" ] && [ -x "$b" ]; then eval "$("$b" shellenv)"; return 0; fi
  done
  return 1
}

brew_install() {
  if brew list --formula "$1" >/dev/null 2>&1; then
    ok "$1 already installed"
  else
    info "Installing $1..."
    brew install "$1" >/dev/null || die "brew install $1 failed."
    ok "$1 installed"
  fi
}

install_tools() {
  step "Installing command-line tools"
  if [ "$SKIP_DEPS" = 1 ]; then
    load_brew || true
    info "Skipped (--skip-deps)."
    return 0
  fi
  if ! load_brew; then
    confirm "Homebrew isn't installed. Install it now (needs your password)?" \
      || die "Homebrew is needed to install xcode-build-server and xcbeautify. Install it from https://brew.sh and re-run."
    NONINTERACTIVE=$([ "$ASSUME_YES" = 1 ] && echo 1 || echo "") \
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    load_brew || die "Homebrew installed but 'brew' wasn't found. Open a new terminal and re-run."
  fi
  brew_install xcode-build-server   # lets SourceKit-LSP understand .xcodeproj (code completion, jump to definition)
  brew_install xcbeautify           # readable build logs + clickable errors
  if [ -f project.yml ] && ! ls -d ./*.xcodeproj >/dev/null 2>&1; then brew_install xcodegen; fi
  if [ -f Podfile ] && ! command -v pod >/dev/null 2>&1; then brew_install cocoapods; fi
}

# ── 3. VS Code ─────────────────────────────────────────────────────────────────
find_code() {
  local c
  for c in "${CODE_BIN:-}" "$(command -v code 2>/dev/null || true)" \
           "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
           "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
    if [ -n "$c" ] && [ -x "$c" ]; then CODE="$c"; return 0; fi
  done
  return 1
}

install_vscode() {
  step "Checking VS Code"
  CODE=""
  if ! find_code; then
    if [ "$SKIP_DEPS" = 1 ]; then warn "VS Code not found; skipping."; return 0; fi
    confirm "VS Code isn't installed. Install it with Homebrew now?" || die "Install VS Code from https://code.visualstudio.com and re-run."
    brew install --cask visual-studio-code >/dev/null || die "Installing VS Code failed."
    find_code || die "VS Code installed but its 'code' command wasn't found."
  fi
  ok "VS Code found ($CODE)"
}

# ── 4. Find the project ────────────────────────────────────────────────────────
list_bundles() {  # list_bundles <extension>
  find . -maxdepth 3 \( -name Pods -o -name DerivedData -o -name .build -o -name .swiftpm -o -name node_modules \
    -o -name '*.xcodeproj' -o -name '*.xcworkspace' -o -name '.git' \) -prune -name "*.$1" -print 2>/dev/null \
    | sed 's|^\./||' | sort
}

pick_from() {  # pick_from <question> <items...>; sets PICKED
  local q="$1" i=1 item ans
  shift
  if [ $# -eq 1 ] || ! can_ask; then PICKED="$1"; return 0; fi
  echo "$q"
  for item in "$@"; do printf '  %d) %s\n' "$i" "$item"; i=$((i + 1)); done
  while :; do
    read -r -p "Choose 1-$# (Enter = 1): " ans || ans=""
    [ -z "$ans" ] && ans=1
    case "$ans" in *[!0-9]*) ;; *) if [ "$ans" -ge 1 ] && [ "$ans" -le $# ]; then eval "PICKED=\${$ans}"; return 0; fi ;; esac
    echo "Please type a number from 1 to $#."
  done
}

find_project() {
  step "Finding your Xcode project"
  # Generated projects: create them first if they don't exist yet.
  if [ -f project.yml ] && [ -z "$(list_bundles xcodeproj)" ]; then
    command -v xcodegen >/dev/null 2>&1 || die "Found project.yml but XcodeGen isn't installed (brew install xcodegen)."
    info "Generating the Xcode project with XcodeGen..."
    xcodegen generate
  fi
  if { [ -f Project.swift ] || [ -f Workspace.swift ]; } && [ -z "$(list_bundles xcworkspace)$(list_bundles xcodeproj)" ]; then
    command -v tuist >/dev/null 2>&1 || die "Found a Tuist project. Install Tuist (https://tuist.dev), run 'tuist generate --no-open', then re-run this script."
    info "Generating the project with Tuist..."
    tuist install >/dev/null 2>&1 || true
    tuist generate --no-open
  fi
  if [ -f Podfile ] && { [ ! -d Pods ] || [ -z "$(list_bundles xcworkspace)" ]; }; then
    if command -v pod >/dev/null 2>&1; then
      info "Installing CocoaPods dependencies..."
      pod install
    else
      warn "Found a Podfile but CocoaPods isn't installed; skipping 'pod install'."
    fi
  fi

  local workspaces=() projects=() line
  while IFS= read -r line; do [ -n "$line" ] && workspaces+=("$line"); done <<< "$(list_bundles xcworkspace)"
  while IFS= read -r line; do [ -n "$line" ] && projects+=("$line"); done <<< "$(list_bundles xcodeproj)"

  CONTAINER=""; CONTAINER_KIND=""
  if [ ${#workspaces[@]} -gt 0 ]; then
    pick_from "Found several workspaces. Which one?" "${workspaces[@]}"
    CONTAINER="$PICKED"; CONTAINER_KIND=workspace
  elif [ ${#projects[@]} -gt 0 ]; then
    pick_from "Found several Xcode projects. Which one?" "${projects[@]}"
    CONTAINER="$PICKED"; CONTAINER_KIND=project
  elif [ -f Package.swift ]; then
    die "This is a Swift package without an Xcode project. VS Code's Swift extension handles packages on its own; this script is for .xcodeproj/.xcworkspace apps."
  else
    die "No .xcodeproj or .xcworkspace found in $(pwd). Run this from your project folder or pass it as an argument."
  fi
  ok "Using $CONTAINER_KIND $CONTAINER"
}

# ── 5. Helper + scheme + simulator ─────────────────────────────────────────────
write_helper() {
  mkdir -p .vscode/xcode
  cat > .vscode/xcode/xc.sh <<'XCSH_EOF'
#!/usr/bin/env bash
# xc.sh: build, run and debug an Xcode project from VS Code without opening Xcode.
# Generated by setup-vscode-xcode.sh. Re-running the setup regenerates this file.
#
# Usage: .vscode/xcode/xc.sh <command>
#   build            Build the selected scheme for the selected simulator (or macOS)
#   run              Build, install, launch and stream the app's console output
#   test             Run the scheme's tests
#   clean            Clean build products and cached settings
#   debug-prepare    Build, launch paused, and hand off to the debugger (used by F5)
#   stop             Terminate the running app
#   logs             Follow the app's console output from the last debug session
#   select-scheme    Pick the scheme (add --prompt to always ask)
#   select-sim       Pick the simulator (add --prompt to always ask)
#   refresh-index    Regenerate buildServer.json for code completion
#   open-sim         Boot the selected simulator and bring Simulator.app forward
#   info             Show the current configuration
set -eo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CONFIG="$HERE/config.env"
STATE="$HERE/.state"
mkdir -p "$STATE"
cd "$ROOT"

XC_WORKSPACE=""; XC_PROJECT=""; XC_SCHEME=""; XC_CONFIGURATION="Debug"
XC_PLATFORM=""; XC_SIM_UDID=""; XC_SIM_NAME=""; XC_TARGET=""; XC_EXTRA_BUILD_ARGS=""
# shellcheck source=/dev/null
if [ -f "$CONFIG" ]; then . "$CONFIG"; fi

if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi
info() { printf '%s▸%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s! %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '%s✖ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

interactive() { [ -t 0 ] && [ "${XC_AUTO:-0}" != 1 ]; }

# choose <default-index> <question> <items...>; sets CHOICE to the picked index.
choose() {
  local def="$1" question="$2" i=0 item ans
  shift 2
  echo "$question"
  for item in "$@"; do
    if [ "$i" -eq "$def" ]; then
      printf '  %s%2d) %s  (default)%s\n' "$B" $((i + 1)) "$item" "$N"
    else
      printf '  %2d) %s\n' $((i + 1)) "$item"
    fi
    i=$((i + 1))
  done
  while :; do
    read -r -p "Choose 1-$# (Enter = $((def + 1))): " ans || ans=""
    if [ -z "$ans" ]; then CHOICE=$def; return 0; fi
    case "$ans" in
      *[!0-9]*) ;;
      *) if [ "$ans" -ge 1 ] && [ "$ans" -le $# ]; then CHOICE=$((ans - 1)); return 0; fi ;;
    esac
    echo "Please type a number from 1 to $#."
  done
}

save_config() {
  local v
  {
    echo "# Used by .vscode/xcode/xc.sh. Change with the 'Xcode: Select Scheme' and"
    echo "# 'Xcode: Select Simulator' tasks, or edit by hand."
    echo "# XC_TARGET: app target to launch when a scheme builds several apps (optional)."
    echo "# XC_EXTRA_BUILD_ARGS: extra xcodebuild arguments, e.g. \"-quiet\" (optional)."
    for v in XC_WORKSPACE XC_PROJECT XC_SCHEME XC_CONFIGURATION XC_PLATFORM XC_SIM_UDID XC_SIM_NAME XC_TARGET XC_EXTRA_BUILD_ARGS; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$CONFIG"
  rm -f "$STATE/settings.env"
}

container_args() {
  if [ -n "$XC_WORKSPACE" ]; then CARGS=(-workspace "$XC_WORKSPACE")
  elif [ -n "$XC_PROJECT" ]; then CARGS=(-project "$XC_PROJECT")
  else die "No .xcworkspace or .xcodeproj configured. Re-run setup-vscode-xcode.sh."
  fi
}

sim_family() {
  case "$XC_PLATFORM" in
    ios) echo iOS ;; tvos) echo tvOS ;; watchos) echo watchOS ;; visionos) echo xrOS ;; *) echo "" ;;
  esac
}
download_name() {
  case "$XC_PLATFORM" in
    ios) echo iOS ;; tvos) echo tvOS ;; watchos) echo watchOS ;; visionos) echo visionOS ;;
  esac
}
is_sim() { [ -n "$(sim_family)" ]; }
dest_label() { if is_sim; then echo "$XC_SIM_NAME"; else echo "macOS"; fi; }
re_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }

# Force the terminal renderer: on CI, xcbeautify would otherwise switch to GitHub annotations.
pretty() {
  if command -v xcbeautify >/dev/null 2>&1; then xcbeautify --renderer terminal --disable-colored-output; else cat; fi
}

# Picks the app target from `xcodebuild -showBuildSettings -json` and prints shell assignments.
PY_PICK='
import json, shlex, sys
want = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not data:
    sys.exit(1)
def matches(t):
    if want:
        return t.get("target") == want
    return t.get("buildSettings", {}).get("WRAPPER_EXTENSION") == "app"
pick = next((t for t in data if matches(t)), data[0])
s = pick.get("buildSettings", {})
d = s.get("TARGET_BUILD_DIR", "")
vals = {
    "APP_PATH": d + "/" + s.get("FULL_PRODUCT_NAME", ""),
    "EXEC_PATH": d + "/" + s.get("EXECUTABLE_PATH", ""),
    "BUNDLE_ID": s.get("PRODUCT_BUNDLE_IDENTIFIER", ""),
    "PRODUCT_NAME": s.get("FULL_PRODUCT_NAME", ""),
    "TARGET_NAME": pick.get("target", ""),
    "SUPPORTED_PLATFORMS": s.get("SUPPORTED_PLATFORMS", ""),
}
for k in sorted(vals):
    print("%s=%s" % (k, shlex.quote(vals[k])))
'

PY_SCHEMES='
import json, sys
d = json.load(sys.stdin)
o = d.get("workspace") or d.get("project") or {}
for s in o.get("schemes", []):
    print(s)
'

# Lists available simulators of one family. First line: "<default index>\t<exact match 0|1>",
# then one "<udid>\t<label>\t<name>" line per simulator, newest runtime first.
# Runs a command in a pseudo-terminal and copies its output, unbuffered, to a file ("-" = stdout).
# simctl holds its output back when writing to a file or pipe; a terminal makes it stream.
PY_PTY='
import os, pty, sys
out = sys.stdout.buffer if sys.argv[1] == "-" else open(sys.argv[1], "ab", buffering=0)
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out.write(data)
    out.flush()
_, status = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
'
run_in_pty() { local dest="$1"; shift; python3 -I -c "$PY_PTY" "$dest" "$@"; }

PY_SIMS='
import json, re, sys
fam, pref, cur_udid, cur_name = (sys.argv[1:] + ["", "", "", ""])[:4]
devices = json.load(sys.stdin).get("devices", {})
rows = []
for rt, devs in devices.items():
    m = re.search(r"SimRuntime\.%s-(\d+)-(\d+)(?:-(\d+))?$" % re.escape(fam), rt)
    if not m:
        continue
    ver = tuple(int(x or 0) for x in m.groups())
    label_ver = "%d.%d" % ver[:2] + (".%d" % ver[2] if ver[2] else "")
    for d in devs:
        if d.get("isAvailable", True) is False:
            continue
        rows.append({"ver": ver, "name": d["name"], "udid": d["udid"], "state": d.get("state", ""),
                     "label": "%s (%s %s)%s" % (d["name"], fam.replace("xrOS", "visionOS"), label_ver,
                                                 ", booted" if d.get("state") == "Booted" else "")})
if not rows:
    sys.exit(0)
rows.sort(key=lambda r: r["ver"], reverse=True)
def newest(pred):
    for i, r in enumerate(rows):
        if pred(r):
            return i
    return None
exact = 0
idx = None
if pref:
    idx = newest(lambda r: r["name"] == pref or r["udid"] == pref)
elif cur_udid:
    idx = newest(lambda r: r["udid"] == cur_udid)
    if idx is None and cur_name:
        idx = newest(lambda r: r["name"] == cur_name)
if idx is not None:
    exact = 1
else:
    def score(r):
        s = 0
        if r["state"] == "Booted":
            s += 1000
        if fam == "iOS":
            m = re.match(r"iPhone (\d+)( Pro)?$", r["name"])
            if m:
                s += 100 + int(m.group(1)) + (5 if m.group(2) else 0)
            elif r["name"].startswith("iPhone"):
                s += 50
        return (s, r["ver"])
    idx = max(range(len(rows)), key=lambda i: score(rows[i]))
print("%d\t%d" % (idx, exact))
for r in rows:
    print("%s\t%s\t%s" % (r["udid"], r["label"], r["name"]))
'

detect_platform() {
  container_args
  info "Detecting the platform of scheme '$XC_SCHEME'..."
  # shellcheck disable=SC2034  # set by eval
  local SUPPORTED_PLATFORMS="" APP_PATH EXEC_PATH BUNDLE_ID PRODUCT_NAME TARGET_NAME assignments
  assignments="$(xcodebuild "${CARGS[@]}" -scheme "$XC_SCHEME" -showBuildSettings -json 2>/dev/null | python3 -I -c "$PY_PICK" "$XC_TARGET")" || assignments=""
  eval "$assignments"
  case " $SUPPORTED_PLATFORMS " in
    *" iphonesimulator "*) XC_PLATFORM=ios ;;
    *" xrsimulator "*) XC_PLATFORM=visionos ;;
    *" appletvsimulator "*) XC_PLATFORM=tvos ;;
    *" watchsimulator "*) XC_PLATFORM=watchos ;;
    *" macosx "*) XC_PLATFORM=macos ;;
    *) warn "Couldn't detect the platform (got '$SUPPORTED_PLATFORMS'); assuming iOS."; XC_PLATFORM=ios ;;
  esac
}

ensure_sim() {
  is_sim || return 0
  if [ -n "$XC_SIM_UDID" ] && xcrun simctl list devices available 2>/dev/null | grep -q "$XC_SIM_UDID"; then
    return 0
  fi
  [ -z "$XC_SIM_UDID" ] || warn "Simulator '$XC_SIM_NAME' is no longer installed; picking another one."
  XC_AUTO=1 cmd_select_sim
}

build_args() {
  container_args
  [ -n "$XC_SCHEME" ] || die "No scheme selected. Run the task 'Xcode: Select Scheme'."
  if [ -z "$XC_PLATFORM" ]; then detect_platform; save_config; fi
  ensure_sim
  local dest
  if is_sim; then dest="id=$XC_SIM_UDID"; else dest="platform=macOS,arch=$(uname -m)"; fi
  BARGS=("${CARGS[@]}" -scheme "$XC_SCHEME" -configuration "$XC_CONFIGURATION" -destination "$dest")
}

# Resolves APP_PATH, EXEC_PATH, BUNDLE_ID, PRODUCT_NAME for the current build (cached).
load_settings() {
  local cache="$STATE/settings.env" key assignments
  key="# $(printf '%s|' "${BARGS[@]}" "$XC_TARGET")"
  if [ -f "$cache" ] && [ "$(head -n 1 "$cache")" = "$key" ]; then
    # shellcheck source=/dev/null
    . "$cache"
    return 0
  fi
  assignments="$(xcodebuild "${BARGS[@]}" -showBuildSettings -json 2>/dev/null | python3 -I -c "$PY_PICK" "$XC_TARGET")" \
    || die "Couldn't read build settings for scheme '$XC_SCHEME'."
  printf '%s\n%s\n' "$key" "$assignments" > "$cache"
  eval "$assignments"
}

boot_sim() {
  info "Booting $XC_SIM_NAME..."
  xcrun simctl bootstatus "$XC_SIM_UDID" -b >/dev/null 2>&1 \
    || die "Couldn't boot simulator '$XC_SIM_NAME' ($XC_SIM_UDID)."
  open "$(xcode-select -p)/Applications/Simulator.app" >/dev/null 2>&1 || open -a Simulator >/dev/null 2>&1 || true
}

install_app() {
  [ -d "$APP_PATH" ] || die "Built app not found at $APP_PATH. Set XC_TARGET in .vscode/xcode/config.env if the scheme builds several apps."
  info "Installing $PRODUCT_NAME on $XC_SIM_NAME..."
  xcrun simctl install "$XC_SIM_UDID" "$APP_PATH" || die "Install failed."
}

cmd_build() {
  build_args
  info "Building ${B}$XC_SCHEME${N} ($XC_CONFIGURATION) for $(dest_label)..."
  local t0=$SECONDS
  # shellcheck disable=SC2086
  if xcodebuild "${BARGS[@]}" -skipMacroValidation -skipPackagePluginValidation $XC_EXTRA_BUILD_ARGS build 2>&1 | pretty; then
    ok "Build succeeded in $((SECONDS - t0))s."
  else
    die "Build failed. Errors are listed in the Problems panel (Shift+Cmd+M)."
  fi
}

cmd_run() {
  cmd_build
  load_settings
  if ! is_sim; then
    pkill -f -- "$(re_escape "$EXEC_PATH")" 2>/dev/null || true
    info "Running $PRODUCT_NAME (stop with Ctrl+C or the 'Xcode: Stop App' task)."
    exec "$EXEC_PATH"
  fi
  boot_sim
  install_app
  info "Launching $BUNDLE_ID. App output follows; Ctrl+C or 'Xcode: Stop App' stops it."
  if [ -t 1 ]; then
    exec xcrun simctl launch --console-pty --terminate-running-process "$XC_SIM_UDID" "$BUNDLE_ID"
  fi
  run_in_pty - xcrun simctl launch --console-pty --terminate-running-process "$XC_SIM_UDID" "$BUNDLE_ID"
}

BG_PIDS=""
# shellcheck disable=SC2086  # BG_PIDS is a space-separated pid list
stop_bg() { if [ -n "$BG_PIDS" ]; then kill $BG_PIDS 2>/dev/null || true; BG_PIDS=""; fi; }

cmd_debug_prepare() {
  echo "XC_DEBUG_PREPARE_BEGIN"
  cmd_build
  load_settings
  local line="" pid="" i launcher
  rm -f "$STATE/app.pid"
  printf 'target create "%s"\n' "$EXEC_PATH" > "$STATE/target.lldb"
  if ! is_sim; then
    # LLDB launches the app itself; its output shows in VS Code's Debug Console.
    pkill -f -- "$(re_escape "$EXEC_PATH")" 2>/dev/null || true
    printf 'process launch\n' > "$STATE/process.lldb"
    ok "Ready. Launching under the debugger; app output appears in the Debug Console."
    echo "XC_DEBUG_READY"
    return 0
  fi

  boot_sim
  install_app
  info "Launching $BUNDLE_ID paused, waiting for the debugger..."
  # --console-pty gives the app a terminal, so print() output isn't held back by buffering.
  : > "$STATE/console.log"
  trap stop_bg EXIT INT TERM HUP
  run_in_pty "$STATE/console.log" xcrun simctl launch --console-pty --wait-for-debugger \
    --terminate-running-process "$XC_SIM_UDID" "$BUNDLE_ID" </dev/null >/dev/null 2>&1 &
  launcher=$!
  BG_PIDS="$launcher"
  for i in $(seq 1 120); do
    line="$(grep -m 1 -E "^$(re_escape "$BUNDLE_ID"): [0-9]+" "$STATE/console.log" 2>/dev/null || true)"
    [ -n "$line" ] && break
    kill -0 "$launcher" 2>/dev/null || die "Launch failed: $(cat "$STATE/console.log")"
    sleep 0.25
  done
  pid="${line##*: }"
  pid="${pid%%[!0-9]*}"
  [ -n "$pid" ] || die "Couldn't read the app's process id. simctl said: $(cat "$STATE/console.log")"
  echo "$pid" > "$STATE/app.pid"
  printf 'process attach --pid %s\n' "$pid" > "$STATE/process.lldb"
  ok "Ready. Attaching the debugger to process $pid..."
  echo "XC_DEBUG_READY"
  echo "──────── app output ────────"
  tail -n +2 -f "$STATE/console.log" &
  BG_PIDS="$BG_PIDS $!"
  while kill -0 "$pid" 2>/dev/null; do sleep 1; done
  sleep 0.5
  stop_bg
  echo "──────── app exited ────────"
}

cmd_stop() {
  build_args
  load_settings
  if is_sim; then
    xcrun simctl terminate "$XC_SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  else
    pkill -f -- "$(re_escape "$EXEC_PATH")" 2>/dev/null || true
  fi
  ok "Stopped $PRODUCT_NAME."
}

cmd_test() {
  build_args
  info "Testing ${B}$XC_SCHEME${N} on $(dest_label)..."
  # shellcheck disable=SC2086
  if xcodebuild "${BARGS[@]}" -skipMacroValidation -skipPackagePluginValidation $XC_EXTRA_BUILD_ARGS test 2>&1 | pretty; then
    ok "Tests passed."
  else
    die "Tests failed (or the scheme has no test action)."
  fi
}

cmd_clean() {
  build_args
  xcodebuild "${BARGS[@]}" clean 2>&1 | pretty
  rm -rf "$STATE"
  ok "Cleaned."
}

cmd_select_scheme() {
  local force=0 list s i def=-1 found=0 base want new old_platform
  [ "$1" = "--prompt" ] && force=1
  container_args
  info "Reading schemes from ${XC_WORKSPACE:-$XC_PROJECT}..."
  list="$(xcodebuild "${CARGS[@]}" -list -json 2>/dev/null | python3 -I -c "$PY_SCHEMES")" \
    || die "Couldn't list schemes. Try running: xcodebuild ${CARGS[*]} -list"
  local schemes=()
  while IFS= read -r s; do [ -n "$s" ] && schemes+=("$s"); done <<< "$list"
  [ ${#schemes[@]} -gt 0 ] || die "No schemes found in ${XC_WORKSPACE:-$XC_PROJECT}."

  base="$(basename "${XC_WORKSPACE:-$XC_PROJECT}")"; base="${base%.*}"
  for i in "${!schemes[@]}"; do [ "${schemes[$i]}" = "$base" ] && def=$i; done
  if [ "$def" -lt 0 ]; then
    for i in "${!schemes[@]}"; do
      case "${schemes[$i]}" in Pods-*) ;; *) def=$i; break ;; esac
    done
  fi
  [ "$def" -ge 0 ] || def=0
  want="${XC_PREF_SCHEME:-$XC_SCHEME}"
  if [ -n "$want" ]; then
    for i in "${!schemes[@]}"; do
      if [ "${schemes[$i]}" = "$want" ]; then def=$i; found=1; fi
    done
    [ "$found" = 1 ] || warn "Scheme '$want' not found."
  fi
  if [ ${#schemes[@]} -gt 1 ] && interactive; then
    # Ask when forced, or when nothing obviously matches the project name.
    if [ "$force" = 1 ] || { [ "$found" = 0 ] && [ "${schemes[$def]}" != "$base" ]; }; then
      choose "$def" "Which scheme should VS Code build?" "${schemes[@]}"
      def=$CHOICE
    fi
  fi
  new="${schemes[$def]}"
  XC_SCHEME="$new"
  ok "Scheme: $XC_SCHEME"
  old_platform="$XC_PLATFORM"
  detect_platform
  ok "Platform: $XC_PLATFORM"
  [ "$old_platform" = "$XC_PLATFORM" ] || { XC_SIM_UDID=""; XC_SIM_NAME=""; }
  save_config
  if is_sim && [ -z "$XC_SIM_UDID" ]; then cmd_select_sim; fi
  cmd_refresh_index
}

cmd_select_sim() {
  local force=0 rows fam first=1 a b c def=0 exact=0
  [ "$1" = "--prompt" ] && force=1
  if [ -z "$XC_PLATFORM" ] && [ -n "$XC_SCHEME" ]; then detect_platform; fi
  if ! is_sim; then ok "This scheme runs on macOS, so no simulator is needed."; return 0; fi
  fam="$(sim_family)"
  rows="$(xcrun simctl list devices available -j 2>/dev/null \
    | python3 -I -c "$PY_SIMS" "$fam" "${XC_PREF_SIM:-}" "$XC_SIM_UDID" "$XC_SIM_NAME")" || rows=""
  if [ -z "$rows" ]; then
    warn "No $(download_name) simulators are installed."
    if interactive; then
      read -r -p "Download the $(download_name) simulator runtime now (several GB)? [Y/n] " a || a=""
      case "$a" in n|N*) die "Install one with: xcodebuild -downloadPlatform $(download_name)" ;; esac
      xcodebuild -downloadPlatform "$(download_name)" || die "Download failed."
      rows="$(xcrun simctl list devices available -j 2>/dev/null \
        | python3 -I -c "$PY_SIMS" "$fam" "${XC_PREF_SIM:-}" "$XC_SIM_UDID" "$XC_SIM_NAME")" || rows=""
    fi
    [ -n "$rows" ] || die "Install a runtime with: xcodebuild -downloadPlatform $(download_name)"
  fi
  local udids=() labels=() names=()
  while IFS=$'\t' read -r a b c; do
    if [ "$first" = 1 ]; then def="$a"; exact="$b"; first=0; continue; fi
    udids+=("$a"); labels+=("$b"); names+=("$c")
  done <<< "$rows"
  [ -z "${XC_PREF_SIM:-}" ] || [ "$exact" = 1 ] || warn "Simulator '$XC_PREF_SIM' not found."
  if [ "$force" = 1 ] && [ ${#udids[@]} -gt 1 ] && interactive; then
    choose "$def" "Which simulator should apps run on?" "${labels[@]}"
    def=$CHOICE
  fi
  XC_SIM_UDID="${udids[$def]}"
  XC_SIM_NAME="${names[$def]}"
  save_config
  ok "Simulator: ${labels[$def]}"
}

cmd_refresh_index() {
  container_args
  [ -n "$XC_SCHEME" ] || die "No scheme selected."
  if ! command -v xcode-build-server >/dev/null 2>&1; then
    warn "xcode-build-server isn't installed (brew install xcode-build-server); code completion won't see your Xcode project."
    return 0
  fi
  if xcode-build-server config "${CARGS[@]}" -scheme "$XC_SCHEME" >/dev/null 2>&1; then
    ok "Code completion set up for '$XC_SCHEME' (buildServer.json). After a build, run 'Swift: Restart LSP Server' if completions look stale."
  else
    warn "xcode-build-server config failed; code completion may be limited."
  fi
}

cmd_info() {
  build_args
  load_settings
  echo "Container:     ${XC_WORKSPACE:-$XC_PROJECT}"
  echo "Scheme:        $XC_SCHEME ($XC_CONFIGURATION)"
  echo "Destination:   $(dest_label) ${XC_SIM_UDID:+($XC_SIM_UDID)}"
  echo "App:           $APP_PATH"
  echo "Bundle id:     $BUNDLE_ID"
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift
case "$cmd" in
  build) cmd_build ;;
  run) cmd_run ;;
  test) cmd_test ;;
  clean) cmd_clean ;;
  debug-prepare) cmd_debug_prepare ;;
  stop) cmd_stop ;;
  logs) tail -n +1 -f "$STATE/console.log" ;;
  select-scheme) cmd_select_scheme "$@" ;;
  select-sim) cmd_select_sim "$@" ;;
  refresh-index) cmd_refresh_index ;;
  open-sim) build_args; is_sim && boot_sim ;;
  info) cmd_info ;;
  help|-h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "Unknown command '$cmd'. Run: $0 help" ;;
esac
XCSH_EOF
  chmod +x .vscode/xcode/xc.sh
}

# shellcheck disable=SC2034  # variables are written out via ${!v}
write_config() {
  local cfg=.vscode/xcode/config.env prev v
  XC_WORKSPACE=""; XC_PROJECT=""; XC_SCHEME=""; XC_CONFIGURATION="Debug"; XC_PLATFORM=""
  XC_SIM_UDID=""; XC_SIM_NAME=""; XC_TARGET=""; XC_EXTRA_BUILD_ARGS=""
  # shellcheck source=/dev/null
  if [ -f "$cfg" ]; then . "$cfg"; fi
  prev="${XC_WORKSPACE:-$XC_PROJECT}"
  if [ "$CONTAINER_KIND" = workspace ]; then XC_WORKSPACE="$CONTAINER"; XC_PROJECT=""
  else XC_PROJECT="$CONTAINER"; XC_WORKSPACE=""; fi
  if [ "$prev" != "$CONTAINER" ]; then XC_SCHEME=""; XC_PLATFORM=""; fi
  [ -z "$CONFIGURATION" ] || XC_CONFIGURATION="$CONFIGURATION"
  {
    echo "# Written by setup-vscode-xcode.sh"
    for v in XC_WORKSPACE XC_PROJECT XC_SCHEME XC_CONFIGURATION XC_PLATFORM XC_SIM_UDID XC_SIM_NAME XC_TARGET XC_EXTRA_BUILD_ARGS; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$cfg"
}

configure_project() {
  step "Choosing scheme and simulator"
  write_helper
  write_config
  local auto=0
  can_ask || auto=1
  XC_AUTO=$auto XC_PREF_SCHEME="$PREF_SCHEME" bash .vscode/xcode/xc.sh select-scheme
  if [ -n "$PREF_SIM" ]; then XC_AUTO=$auto XC_PREF_SIM="$PREF_SIM" bash .vscode/xcode/xc.sh select-sim; fi
}

# ── 6. VS Code workspace files ─────────────────────────────────────────────────
write_vscode_files() {
  step "Writing VS Code tasks, debugger and settings"
  local lldb_lib gen
  lldb_lib="$(dirname "$(xcode-select -p)")/SharedFrameworks/LLDB.framework/Versions/A/LLDB"
  [ -f "$lldb_lib" ] || { warn "Xcode's LLDB not found at $lldb_lib; Swift variables may not show in the debugger."; lldb_lib=""; }
  gen="$(mktemp "${TMPDIR:-/tmp}/xcvscode.XXXXXX")"
  cat > "$gen" <<'GENPY_EOF'
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
GENPY_EOF
  LLDB_LIB="$lldb_lib" python3 "$gen" || { rm -f "$gen"; die "Writing the .vscode files failed."; }
  rm -f "$gen"

  if [ -d .git ] || [ -f .gitignore ] || git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local line added=0
    touch .gitignore
    for line in ".vscode/xcode/.state/" ".vscode/xcode/config.env" "buildServer.json"; do
      if ! grep -qxF "$line" .gitignore; then
        [ "$added" = 1 ] || printf '\n# VS Code + Xcode (machine-specific, from setup-vscode-xcode.sh)\n' >> .gitignore
        echo "$line" >> .gitignore
        added=1
      fi
    done
    [ "$added" = 0 ] || ok "Added machine-specific files to .gitignore"
  fi
}

# ── 7. Extensions ──────────────────────────────────────────────────────────────
install_extension() {  # The marketplace (and the extensions' own dependencies) can fail transiently; retry.
  local id="$1" attempt out=""
  for attempt in 1 2 3; do
    if out="$("$CODE" --install-extension "$1" 2>&1)"; then ok "$id installed"; return 0; fi
    [ "$attempt" = 3 ] || { info "Installing $id failed, retrying..."; sleep $((attempt * 5)); }
  done
  warn "Couldn't install $id. Install it from the Extensions view. VS Code said:"
  printf '%s\n' "$out" | tail -n 5 >&2
}

install_extensions() {
  step "Installing VS Code extensions"
  if [ "$SKIP_DEPS" = 1 ] || [ -z "$CODE" ]; then info "Skipped."; return 0; fi
  local installed id
  installed="$("$CODE" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  for id in swiftlang.swift-vscode vadimcn.vscode-lldb; do
    if printf '%s\n' "$installed" | grep -qx "$id"; then
      ok "$id already installed"
    else
      install_extension "$id"
    fi
  done
}

# ── 8. First build ─────────────────────────────────────────────────────────────
first_build() {
  step "First build (feeds code completion)"
  if [ "$DO_BUILD" = 0 ]; then info "Skipped (--no-build)."; return 0; fi
  if bash .vscode/xcode/xc.sh build; then
    bash .vscode/xcode/xc.sh refresh-index >/dev/null 2>&1 || true
  else
    warn "The first build failed. Setup is still complete: fix the errors in VS Code and press Shift+Cmd+B."
  fi
}

main() {
  if [ -n "$DIR" ]; then cd "$DIR" || die "Can't open folder '$DIR'."; fi
  printf '%sVS Code setup for Xcode projects%s %sv%s · %s%s\n' "$B" "$N" "$D" "$VERSION" "$(pwd)" "$N"
  check_xcode
  install_tools
  install_vscode
  find_project
  configure_project
  write_vscode_files
  install_extensions
  first_build

  printf '\n%s✔ All set.%s In VS Code:\n' "$G$B" "$N"
  echo "   • Shift+Cmd+B          build"
  echo "   • F5                   build, launch on the simulator and debug (breakpoints work)"
  echo "   • Cmd+Shift+P → Tasks: Run Task → Xcode: Run      run without the debugger"
  echo "   • Xcode: Select Scheme / Xcode: Select Simulator   change targets any time"
  echo "   Re-run this script whenever you like; it's safe."
  if [ "$DO_OPEN" = 1 ] && [ -n "$CODE" ]; then "$CODE" . >/dev/null 2>&1 || true; fi
}

main
