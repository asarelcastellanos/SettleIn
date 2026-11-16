# Contributing to SettleIn

Thank you for helping. This guide covers how to add a catalog entry and how to run the tests. Report vulnerabilities through [SECURITY.md](SECURITY.md), and never in a public issue. Everyone who takes part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Add a catalog entry

You can open a [catalog entry request](https://github.com/asarelcastellanos/SettleIn/issues/new?template=catalog_entry_request.yml) or send a pull request that adds the entry to `catalog/`. [docs/catalog.md](docs/catalog.md) describes the file format and the rules.

Each entry needs these fields.

- `id`, a lowercase name made of words joined by hyphens.
- `name`, `category`, and `homepage`, which is the vendor's site over HTTPS.
- `version`, the release the entry pins. Use the literal `latest` only when the vendor offers no versioned URL.
- `installType`, which is `dmg`, `zip`, or `pkg`.
- `appName`, the `.app` folder name inside the archive, for a `dmg` or `zip` entry. A `pkg` entry has `pkgIdentifier` instead, the package ID that `pkgutil` reports.
- `architecture`, which is `universal` or `perArch`. A `universal` entry has `downloadURL`. A `perArch` entry has an `arm64` object and an `x86_64` object, each with its own `downloadURL`.
- `allowedHosts`, the hosts the download may use. List every host in the redirect chain. Check it with `curl -sIL <download URL>`.
- `sha256`, the SHA-256 hash of the file at each URL. A versioned entry must have one. A `latest` entry must not, because the file changes with each release, so it relies on the Team ID check alone.
- `teamID`, the vendor's Team ID.
- `bundleID`, the app's bundle identifier. Read it with `defaults read /path/to/Example.app/Contents/Info CFBundleIdentifier`.
- `uninstallPaths`, the paths the uninstaller may remove. Each one starts with `/Applications/`, `~/Library/`, or `~/.config/`. It is not a direct child of `~/Library`, and it has no `..` and no wildcard.

### Find the real Team ID

Download the app from the vendor's own site, then run this command on the app bundle.

```sh
codesign -dv --verbose=4 /Applications/Example.app 2>&1 | grep TeamIdentifier
```

Copy the `TeamIdentifier` value. Do not copy a Team ID from a blog post, a forum, or another catalog. If the command prints `not set`, the app has no Team ID and the catalog cannot accept it.

For an app inside a disk image, mount it with `hdiutil attach -nobrowse -readonly -noautoopen -mountpoint <dir>` and run the command on the `.app` there, then detach it. For a `pkg`, run `pkgutil --check-signature` on the file, and run `pkgutil --expand-full` into a new folder to read the package identifier in `PackageInfo` and to run `codesign` on the app in the payload. Never run the installer to find these values.

### Pin a SHA-256

Skip this section for a `latest` entry. Download the file from the exact versioned URL in the entry, then run this command.

```sh
shasum -a 256 path/to/the-file
```

Put the printed hash in the entry. Run the command twice, on two separate downloads, and confirm both hashes match. When the vendor publishes a hash, confirm it matches yours.

## Run the tests

All tests run locally on a Mac. `bash catalog/validate.sh` needs Node.js and `npx`.

```sh
swift test --package-path app/SettleInCore
xcodebuild -project app/SettleIn.xcodeproj -scheme SettleIn -destination 'platform=macOS' test
swiftlint --strict --config app/.swiftlint.yml app
bash catalog/validate.sh
```

Run every command before you open a pull request. A weekly catalog check runs on GitHub Actions starting at v0.9.0.

## Open a pull request

The pull request template asks for a summary, a test checklist, and whether the change touches the security model. Fill in each part. A change that touches signature checks, hash checks, the host allowlist, the path allowlist, or anything near a password needs a clear explanation of why it is safe.
