# app

This directory holds the macOS app. `SettleIn.xcodeproj` is the SwiftUI app, and the Swift package `SettleInCore` holds the logic that the app calls. The project links the package as a local dependency. The package has no third-party dependencies.

## Requirements

- A Mac with Xcode 16 or later. The project was built and checked with Xcode 27.2.
- macOS 14 or later to run the app. The deployment target is 14.0.
- SwiftLint, installed on your Mac. Contributors need it to run the lint command.

## Layout

- `SettleIn/` holds the app sources and `SettleIn.entitlements`.
- `SettleInCore/` holds the package. `Sources/SettleInCore` is the library and `Tests/SettleInCoreTests` holds its tests. `Tests/Fixtures` holds captured tool output and `build-fixtures.sh`, which builds the end-to-end fixtures.
- `.swiftlint.yml` holds the lint rules for both the app and the package.

## Build and test

Run these commands from the repository root.

Test the package alone.

```sh
swift test --package-path app/SettleInCore
```

Run only the end-to-end tests. They build a tiny ad hoc signed app and its dmg, zip, and pkg with `Tests/Fixtures/build-fixtures.sh` in a temp folder, and they install into a temp home and a temp applications folder. They never touch `/Applications` or your home folder, and they never ask for a password. The run builds the fixtures once and gives each test a copy, and it takes under a minute. [docs/test-plan.md](../docs/test-plan.md) covers the manual runs on the real apps.

```sh
swift test --package-path app/SettleInCore --filter IntegrationTests
```

Build the app.

```sh
xcodebuild -project app/SettleIn.xcodeproj -scheme SettleIn -destination 'platform=macOS' build
```

Build the app and run the `SettleInCoreTests` target through the app scheme.

```sh
xcodebuild -project app/SettleIn.xcodeproj -scheme SettleIn -destination 'platform=macOS' test
```

Lint the app and the package.

```sh
swiftlint --strict --config app/.swiftlint.yml app
```

`swiftlint --strict app` also works in a fresh checkout. After `swift test` creates `app/SettleInCore/.build`, SwiftLint reads the `.build` folder as source, because it ignores the `excluded` list of a config it finds in a subfolder. Passing `--config` makes the list apply.

## Build outputs

To keep build outputs out of your Xcode derived data folder, add `-derivedDataPath "$TMPDIR/settlein-dd"` to an `xcodebuild` command. The built app is then at `$TMPDIR/settlein-dd/Build/Products/Debug/SettleIn.app`. Do not point `-derivedDataPath` inside the repository.

## Code signing

The project signs local builds with an ad hoc signature. It sets `CODE_SIGN_IDENTITY` to `-`, leaves the team empty, and passes `-o runtime` so the signature carries the Hardened Runtime flag. The repository holds no certificate, Team ID, or provisioning profile, and it never will.

To set the same values on the command line, add them to an `xcodebuild` command.

```sh
xcodebuild -project app/SettleIn.xcodeproj -scheme SettleIn -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

Xcode prints the note "Disabling hardened runtime with ad-hoc codesigning" during an ad hoc build. The flag still lands in the signature. Check it with the commands below.

```sh
codesign -dv --verbose=4 path/to/SettleIn.app 2>&1 | grep flags
codesign -d --entitlements - path/to/SettleIn.app
```

The first command prints `adhoc,runtime`. The second prints `com.apple.security.app-sandbox` set to false. A Debug build also carries `com.apple.security.get-task-allow`, which Xcode adds so a debugger can attach. The Release configuration sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, so a Release build does not carry it.

## Entitlements

The App Sandbox is off because SettleIn must write apps into `/Applications` and run installers, and the sandbox forbids both. `SettleIn/SettleIn.entitlements` explains this in a comment. Hardened Runtime is on. The project adds no `com.apple.security.cs.*` exception entitlements and no network or file entitlements. Do not add any without a reviewed reason.
