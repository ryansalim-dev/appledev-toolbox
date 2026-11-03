# VS Code for Xcode projects, in one step

`setup-vscode-xcode.sh` turns any `.xcodeproj` / `.xcworkspace` folder into a VS Code project
that can **build, run on the Simulator and debug with breakpoints** without ever opening Xcode.
Xcode still has to be *installed* (it provides the compiler, SDKs and simulators); it just never
has to be launched.

## Use it

Pick one:

- **Double-click**: put `setup-vscode-xcode.sh` and `Setup VS Code for Xcode.command` in the same
  folder, double-click the `.command` file, pick your project folder. (First time only: if macOS
  blocks it, run `chmod +x *.command *.sh && xattr -c *.command *.sh` in that folder, or
  right-click > Open.)
- **Terminal**, from your project folder:
  ```bash
  bash ~/Downloads/setup-vscode-xcode.sh
  ```
- **Install it as a command** so it's one word in any project:
  ```bash
  install -m 755 ~/Downloads/setup-vscode-xcode.sh "$(brew --prefix)/bin/xcode-vscode"
  cd ~/Code/MyApp && xcode-vscode
  ```

VS Code opens when it's done. Then:

| Do this | Get this |
|---|---|
| **Shift+Cmd+B** | Build. Errors and warnings land in the Problems panel and are clickable. |
| **F5** | Build, install, launch on the Simulator, attach LLDB. Breakpoints, `po`, variables all work. iOS app output (`print`, `NSLog`) streams live in the *Xcode: Prepare Debug* terminal; for Mac apps it's in the Debug Console. Stopping the debugger terminates the app. |
| **Tasks: Run Task → Xcode: Run** | Build and launch without the debugger, streaming the app's console. |
| **Xcode: Test** | `xcodebuild test` for the scheme. |
| **Xcode: Select Scheme / Select Simulator** | Switch targets; completion is re-pointed automatically. |
| **Xcode: Clean**, **Stop App**, **Open Simulator**, **Show Info**, **Refresh Code Completion** | What they say. |

Options: `--scheme NAME`, `--simulator "iPhone 17 Pro"`, `--configuration Release`, `--yes`
(never prompt), `--skip-deps`, `--no-build`, `--no-open`. See `--help`.

## What it does

1. **Xcode**: checks it's installed and selected (switches from Command Line Tools if needed), runs
   first-launch/license setup if Xcode never has, and offers to enable Developer Mode so the
   debugger doesn't ask for a password.
2. **Tools** via Homebrew (installs Homebrew if missing, after asking):
   [`xcode-build-server`](https://github.com/SolaWing/xcode-build-server) so SourceKit-LSP
   understands the Xcode project (completion, jump-to-definition, diagnostics), and
   [`xcbeautify`](https://github.com/cpisciotta/xcbeautify) for readable logs. Adds XcodeGen /
   CocoaPods only if your project uses them.
3. **VS Code**: installs it if missing, plus the **Swift** (`swiftlang.swift-vscode`) and
   **CodeLLDB** (`vadimcn.vscode-lldb`) extensions.
4. **Project**: finds the workspace (preferred) or project, skipping `Pods`, `.swiftpm` etc.
   Runs `xcodegen generate`, `tuist generate` or `pod install` first when the project needs it.
   Picks the scheme named after the project, and only asks when that's ambiguous. Picks the newest
   iPhone simulator (or the booted one). Detects macOS / tvOS / watchOS / visionOS schemes too.
5. **Writes** `.vscode/tasks.json`, `launch.json`, `settings.json`, `extensions.json`, a helper at
   `.vscode/xcode/xc.sh`, and `buildServer.json`. Points CodeLLDB at **Xcode's own LLDB** (the
   bundled one can't read Swift types).
6. **Builds once**, so code completion works the moment VS Code opens.

### Safe to re-run

Re-running keeps your scheme/simulator choice and anything you added yourself. Only tasks and
launch configs named `Xcode: …` and a handful of settings keys are rewritten. The first time it
touches a file you already had, it saves the original as `*.before-xcode-setup`.

### Files and git

Commit `.vscode/tasks.json`, `launch.json`, `extensions.json` and `.vscode/xcode/xc.sh` if you
like; teammates just run the script once. Machine-specific files are added to `.gitignore`:
`.vscode/xcode/config.env` (scheme + simulator UDID), `.vscode/xcode/.state/`, `buildServer.json`.

## How the debugger hand-off works

`F5` runs the *Xcode: Prepare Debug* task, which builds, installs, and starts the app with
`simctl launch --console-pty --wait-for-debugger`, so it sits paused before `main` and its output
goes through a terminal (no stdout buffering). The task writes the app's path and PID to two small
LLDB command files, and the `Xcode: Debug` launch config (CodeLLDB `custom` request) sources them
to `target create` + `process attach --pid`. Early breakpoints (like in your `App.init`) are hit.
For Mac apps LLDB launches the binary directly.

## Developing the script

Edit the pieces in `src/` (`setup.sh.in`, the `xc.sh` helper, the `gen_vscode.py` generator), then
run `python3 tools/vscode-xcode-setup/build.py` to rebuild the single-file
`setup-vscode-xcode.sh`. CI (`.github/workflows/vscode-xcode-setup.yml`) checks the bundle is up to
date, runs shellcheck, and on macOS runners runs `test/ci-test.sh`, which does a real setup with
the stock `/bin/bash` 3.2 and then:

- **iOS** (`test/fixtures/SampleApp`, an XcodeGen project): builds, checks a type error lands in
  the Problems matcher, runs on a Simulator with live output, hits a breakpoint and reads a Swift
  local through Xcode's LLDB, and does the same through the CodeLLDB adapter over the Debug
  Adapter Protocol (`test/dap-test.mjs`), which is what VS Code does on F5.
- **macOS**: the same setup on this repo's own Mac app, run, and a breakpoint in `main`.

## Troubleshooting

- **Completions missing or stale**: build once (Shift+Cmd+B), then *Swift: Restart LSP Server*.
  After switching schemes it's done for you, but the LSP still needs a restart.
- **Scheme builds several apps** (app + watch app): set `XC_TARGET=YourAppTarget` in
  `.vscode/xcode/config.env`.
- **Extra build flags**: `XC_EXTRA_BUILD_ARGS="-quiet"` (or anything `xcodebuild` accepts) in the same file.
- **No simulators**: the script offers to download the runtime; or run
  `xcodebuild -downloadPlatform iOS`.
- **Debugger asks for a password**: `sudo DevToolsSecurity -enable`.
- **Physical devices** aren't covered (signing + `devicectl` + remote debugserver). For that,
  the [SweetPad](https://marketplace.visualstudio.com/items?itemName=sweetpad.sweetpad) extension
  is the best option and coexists fine with this setup.

Requirements: macOS, Xcode 15 or newer, VS Code. Works with the stock macOS bash 3.2.
