#!/bin/bash
# End-to-end test for setup-vscode-xcode.sh on a real Mac (GitHub Actions macOS runner).
# Runs under /bin/bash on purpose: that's the bash 3.2 every Mac ships with.
#
#   /bin/bash tools/vscode-xcode-setup/test/ci-test.sh ios     # sample iOS app (XcodeGen), Simulator, LLDB + CodeLLDB
#   /bin/bash tools/vscode-xcode-setup/test/ci-test.sh macos   # this repo's own Mac app
set -eo pipefail

MODE="${1:-ios}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$TOOL/../.." && pwd)"
SETUP="$TOOL/setup-vscode-xcode.sh"
WORK="${RUNNER_TEMP:-$(mktemp -d)}/vscode-setup-$MODE"
LOGS="${RUNNER_TEMP:-/tmp}/vscode-setup-logs"
mkdir -p "$LOGS"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1

STEP_NAME=""
step() { STEP_NAME="$*"; printf '\n::group::%s\n' "$*"; }
end_step() { echo "::endgroup::"; echo "PASS: $STEP_NAME"; }
fail() { echo "::endgroup::"; echo "::error::$STEP_NAME: $*"; exit 1; }
assert() { local msg="$1"; shift; "$@" || fail "$msg"; }

# wait_for <text> <file> <seconds>
wait_for() {

  for _ in $(seq 1 "$3"); do
    if grep -qF -- "$1" "$2" 2>/dev/null; then return 0; fi
    sleep 1
  done
  echo "---- $2 ----"; cat "$2" 2>/dev/null || true
  return 1
}
# wait_exit <pid> <seconds>
wait_exit() {
  for _ in $(seq 1 "$2"); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
  return 1
}
# with_timeout <seconds> <cmd...> (macOS has no `timeout`)
with_timeout() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"; }
json_ok() { node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").replace(/^\/\/.*\n/,""))' "$1"; }
XC() { /bin/bash .vscode/xcode/xc.sh "$@"; }

echo "bash: $BASH_VERSION"
xcodebuild -version
rm -rf "$WORK"

if [ "$MODE" = ios ]; then
  cp -R "$TOOL/test/fixtures/SampleApp" "$WORK"
  cd "$WORK"
  git init -q .
else
  mkdir -p "$WORK"
  (cd "$REPO" && tar --exclude ./.git -cf - .) | (cd "$WORK" && tar xf -)
  cd "$WORK"
  git init -q .
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Setup, first run (installs tools, VS Code, extensions; builds)"
/bin/bash "$SETUP" --yes --no-open 2>&1 | tee "$LOGS/setup-$MODE.log"
for f in .vscode/tasks.json .vscode/launch.json .vscode/settings.json .vscode/extensions.json; do
  assert "$f missing or not valid JSON" json_ok "$f"
done
assert "helper missing" test -x .vscode/xcode/xc.sh
assert "buildServer.json missing" test -f buildServer.json
assert ".gitignore not updated" grep -qxF "buildServer.json" .gitignore
# shellcheck source=/dev/null
. .vscode/xcode/config.env
echo "scheme=$XC_SCHEME platform=$XC_PLATFORM sim=$XC_SIM_NAME ($XC_SIM_UDID)"
if [ "$MODE" = ios ]; then
  assert "XcodeGen project not generated" test -d SampleApp.xcodeproj
  assert "wrong scheme '$XC_SCHEME'" test "$XC_SCHEME" = SampleApp
  assert "wrong platform '$XC_PLATFORM'" test "$XC_PLATFORM" = ios
  assert "no simulator picked" test -n "$XC_SIM_UDID"
else
  assert "wrong scheme '$XC_SCHEME'" test "$XC_SCHEME" = AppleDevToolbox
  assert "wrong platform '$XC_PLATFORM'" test "$XC_PLATFORM" = macos
fi
LLDB_LIB="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(".vscode/settings.json","utf8").replace(/^\/\/.*\n/,""))["lldb.library"]||"")')"
assert "lldb.library not set to an existing file ($LLDB_LIB)" test -f "$LLDB_LIB"
code --list-extensions | tee "$LOGS/extensions.txt"
assert "Swift extension not installed" grep -qi '^swiftlang.swift-vscode$' "$LOGS/extensions.txt"
assert "CodeLLDB not installed" grep -qi '^vadimcn.vscode-lldb$' "$LOGS/extensions.txt"
end_step

# ─────────────────────────────────────────────────────────────────────────────
step "Setup, second run changes nothing"
before="$(cat .vscode/*.json .vscode/xcode/config.env .gitignore | shasum)"
/bin/bash "$SETUP" --yes --no-open --no-build > "$LOGS/setup-rerun-$MODE.log" 2>&1 || { cat "$LOGS/setup-rerun-$MODE.log"; fail "re-run failed"; }
after="$(cat .vscode/*.json .vscode/xcode/config.env .gitignore | shasum)"
assert "re-running changed the generated files" test "$before" = "$after"
end_step

# ─────────────────────────────────────────────────────────────────────────────
step "Build errors are picked up by the Problems panel matcher"
src="Sources/Greeter.swift"
[ "$MODE" = ios ] || src="App/Sources/Tool.swift"
cp "$src" "$LOGS/original.swift"
printf '\nlet ciBrokenValue: Int = "not an int"\n' >> "$src"
if XC build > "$LOGS/broken-build.log" 2>&1; then cp "$LOGS/original.swift" "$src"; fail "build with a type error succeeded"; fi
cp "$LOGS/original.swift" "$src"
node -e '
const fs = require("fs");
const tasks = JSON.parse(fs.readFileSync(".vscode/tasks.json","utf8").replace(/^\/\/.*\n/,""));
const err = new RegExp(tasks.tasks.find(t => t.label === "Xcode: Build").problemMatcher[0].pattern.regexp);
const hits = fs.readFileSync(process.argv[1],"utf8").split("\n").map(l => l.match(err)).filter(Boolean);
hits.forEach(m => console.log("matched:", m[1] + ":" + m[2] + ":" + m[3], "-", m[4]));
if (!hits.some(m => m[1].endsWith(process.argv[2]))) { console.log(fs.readFileSync(process.argv[1],"utf8")); process.exit(1); }
' "$LOGS/broken-build.log" "$src" || fail "the error matcher didn't find the error in $src"
XC build > "$LOGS/rebuild.log" 2>&1 || { cat "$LOGS/rebuild.log"; fail "rebuild after fixing failed"; }
end_step

STATE=.vscode/xcode/.state

if [ "$MODE" = ios ]; then
  # ───────────────────────────────────────────────────────────────────────────
  step "Xcode: Run launches on the Simulator and streams output"
  XC run > "$LOGS/run.log" 2>&1 &
  run_pid=$!
  wait_for "hello-from-sample-app" "$LOGS/run.log" 300 || fail "app output never appeared"
  wait_for "tick 2" "$LOGS/run.log" 30 || fail "output stopped streaming"
  XC stop
  wait_exit "$run_pid" 20 || fail "run task didn't end after Stop App"
  end_step

  LINE="$(grep -n CI_BREAKPOINT Sources/Greeter.swift | cut -d: -f1)"

  # ───────────────────────────────────────────────────────────────────────────
  step "F5 hand-off works with Xcode's LLDB (attach, breakpoint, variables)"
  XC debug-prepare > "$LOGS/prepare-lldb.log" 2>&1 &
  prep_pid=$!
  wait_for "XC_DEBUG_READY" "$LOGS/prepare-lldb.log" 300 || fail "debug-prepare never got ready"
  cat "$STATE/target.lldb" "$STATE/process.lldb"
  cat > "$LOGS/cmds.lldb" <<EOF
command source "$PWD/$STATE/target.lldb"
breakpoint set --file Greeter.swift --line $LINE
command source "$PWD/$STATE/process.lldb"
process continue
frame variable message
thread backtrace 3
process detach
EOF
  with_timeout 180 xcrun lldb --batch -s "$LOGS/cmds.lldb" > "$LOGS/lldb.log" 2>&1 || true
  cat "$LOGS/lldb.log"
  grep -q "stop reason = breakpoint" "$LOGS/lldb.log" || fail "breakpoint at Greeter.swift:$LINE was not hit"
  grep -q '"hello-from-sample-app"' "$LOGS/lldb.log" || fail "couldn't read the Swift local 'message'"
  wait_for "tick" "$LOGS/prepare-lldb.log" 30 || fail "app output didn't stream into the debug task"
  XC stop
  wait_exit "$prep_pid" 20 || fail "debug task didn't end after Stop App"
  end_step

  # ───────────────────────────────────────────────────────────────────────────
  step "F5 hand-off works with CodeLLDB (the VS Code debugger), driven over DAP"
  ADAPTER="$(find "$HOME/.vscode/extensions" -maxdepth 3 -path "*vadimcn.vscode-lldb-*/adapter/codelldb" 2>/dev/null | sort | tail -n 1)"
  assert "CodeLLDB adapter binary not found" test -x "$ADAPTER"
  echo "adapter: $ADAPTER"
  XC debug-prepare > "$LOGS/prepare-dap.log" 2>&1 &
  prep_pid=$!
  wait_for "XC_DEBUG_READY" "$LOGS/prepare-dap.log" 300 || fail "debug-prepare never got ready"
  node "$HERE/dap-test.mjs" --adapter "$ADAPTER" --liblldb "$LLDB_LIB" --workspace "$PWD" \
    --file "$PWD/Sources/Greeter.swift" --line "$LINE" --var "message=hello-from-sample-app" \
    --console "$STATE/console.log" --expect "hello-from-sample-app" 2>&1 | tee "$LOGS/dap.log" \
    || fail "CodeLLDB session failed (see log above)"
  XC stop
  wait_exit "$prep_pid" 20 || fail "debug task didn't end after Stop App"
  end_step
else
  # ───────────────────────────────────────────────────────────────────────────
  step "Xcode: Run launches the Mac app"
  XC run > "$LOGS/run-mac.log" 2>&1 &
  run_pid=$!
  wait_for "Running" "$LOGS/run-mac.log" 300 || fail "app didn't start"
  sleep 8
  kill -0 "$run_pid" 2>/dev/null || { cat "$LOGS/run-mac.log"; fail "app exited right away"; }
  XC stop
  wait_exit "$run_pid" 20 || fail "app still running after Stop App"
  end_step

  # ───────────────────────────────────────────────────────────────────────────
  step "F5 hand-off works with Xcode's LLDB (launch, stop in main)"
  XC debug-prepare > "$LOGS/prepare-mac.log" 2>&1 || { cat "$LOGS/prepare-mac.log"; fail "debug-prepare failed"; }
  grep -q XC_DEBUG_READY "$LOGS/prepare-mac.log" || fail "debug-prepare didn't signal ready"
  cat > "$LOGS/cmds.lldb" <<EOF
command source "$PWD/$STATE/target.lldb"
breakpoint set --name main
command source "$PWD/$STATE/process.lldb"
thread backtrace 1
process kill
EOF
  with_timeout 120 xcrun lldb --batch -s "$LOGS/cmds.lldb" > "$LOGS/lldb-mac.log" 2>&1 || true
  cat "$LOGS/lldb-mac.log"
  grep -q "stop reason = breakpoint" "$LOGS/lldb-mac.log" || fail "didn't stop in main"
  end_step
fi

echo
echo "All $MODE checks passed."
