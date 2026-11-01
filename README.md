# AppleDev Toolbox

A native Mac app that collects the small, annoying jobs of Apple-platform development in one place: signing, crash logs, push, universal links, plists, privacy manifests, icons, plus the everyday JSON/JWT/Base64 helpers.

Paste anything (⇧⌘V), drop a file on the window, or open one (⌘O), and the app picks the right tool.

## Status

| Tool | Status |
|------|--------|
| Provisioning profiles: browse Xcode's profiles, inspect, clean up expired/superseded | ✅ first version |
| Signing certificates in the Keychain, with expiry and private-key check | ✅ first version |
| Crash logs (`.ips`): readable report + symbolication via Spotlight/dSYM folders + `atos` | ✅ first version |
| Push tester: APNs with a .p8 key (token auth) or a booted Simulator, payload templates and checks, plain-English APNs errors | ✅ first version |
| Universal links: fetch AASA from your server and Apple's CDN, check hosting rules and file contents, test which URLs open the app | ✅ first version |
| Plist & entitlements: view plists, an app's Info.plist / signed entitlements / profile / privacy manifest (.app or .ipa), compare two builds | ✅ first version (view only) |
| Privacy checker: scan a project or .app/.ipa for required-reason APIs, manifest mistakes, SDKs without manifests, and missing usage descriptions | ✅ first version |
| App icon: preview with the iOS mask and export AppIcon.appiconset (iOS single-size + dark/tinted, macOS sizes, watchOS) | ✅ first version |
| JSON formatter (keeps key order, line/column errors) | ✅ |
| JSON → Swift `Codable` | ✅ |
| JWT decoder | ✅ |
| Base64 (standard + URL-safe, hex dump for binary) | ✅ |
| Timestamps (s/ms/µs/ns auto-detect, ISO 8601) | ✅ |

## Layout

```
Packages/ToolboxCore/   Swift package: every parser and generator. Foundation only, so it
                        builds and tests on macOS and Linux.
App/Sources/            SwiftUI Mac app (macOS 14+). Views + Platform/ (Process, Security, atos).
project.yml             XcodeGen spec for the app.
```

Keep logic in `ToolboxCore` with tests; keep the app layer thin. Anything that depends on Xcode internals (paths, `xcrun` output formats) is isolated so yearly Xcode changes stay contained.

## Develop

```sh
# Core tests (macOS or Linux)
swift test --package-path Packages/ToolboxCore

# Mac app
brew install xcodegen
xcodegen generate
open AppleDevToolbox.xcodeproj
```

The `.xcodeproj` is generated and git-ignored; edit `project.yml` instead.

The app is **not sandboxed** on purpose: it runs `xcrun atos`/`dwarfdump`/`mdfind` and reads `~/Library/Developer` and `~/Library/Logs`. The plan is to distribute it with Developer ID (direct sales + Setapp), not the Mac App Store.

## CI

GitHub Actions runs the core tests on macOS and Linux and builds the Mac app with Xcode on every PR.
