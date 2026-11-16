# Contributing to SettleIn

Thank you for helping. This guide covers how to add a catalog entry and how to run the tests. Report vulnerabilities through [SECURITY.md](SECURITY.md), and never in a public issue. Everyone who takes part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Add a catalog entry

You can open a [catalog entry request](https://github.com/asarelcastellanos/SettleIn/issues/new?template=catalog_entry_request.yml) or send a pull request that adds the entry to `catalog/`. The catalog schema lands with [issue 5](https://github.com/asarelcastellanos/SettleIn/issues/5), and this section will list exact field names then.

Each entry needs these fields.

- The app name.
- The vendor's homepage.
- The vendor's download page.
- The install type, which is `dmg`, `zip`, or `pkg`.
- A download URL over HTTPS. Prefer a versioned URL. A URL that always serves the latest build is allowed only when the vendor offers no versioned URL, and the entry then sets its version to `latest`.
- The SHA-256 hash of the file at that URL. A versioned entry must have one. A `latest` entry must not, because the file changes with each release, so it relies on the Team ID check alone.
- The vendor's Team ID.

### Find the real Team ID

Download the app from the vendor's own site, then run this command on the app bundle.

```sh
codesign -dv --verbose=4 /Applications/Example.app 2>&1 | grep TeamIdentifier
```

Copy the `TeamIdentifier` value. Do not copy a Team ID from a blog post, a forum, or another catalog. If the command prints `not set`, the app has no Team ID and the catalog cannot accept it.

### Pin a SHA-256

Skip this section for a `latest` entry. Download the file from the exact versioned URL in the entry, then run this command.

```sh
shasum -a 256 path/to/the-file
```

Put the printed hash in the entry. Run the command twice, on two separate downloads, and confirm both hashes match. When the vendor publishes a hash, confirm it matches yours.

## Run the tests

All tests run locally on a Mac. These commands become available as the app, the package, and the catalog land in [issue 4](https://github.com/asarelcastellanos/SettleIn/issues/4) and [issue 5](https://github.com/asarelcastellanos/SettleIn/issues/5).

```sh
swift test --package-path app/SettleInCore
xcodebuild -project app/SettleIn.xcodeproj -scheme SettleIn -destination 'platform=macOS' test
swiftlint --strict --config app/.swiftlint.yml app
bash catalog/validate.sh
```

Run all four before you open a pull request. A weekly catalog check runs on GitHub Actions starting at v0.9.0.

## Open a pull request

The pull request template asks for a summary, a test checklist, and whether the change touches the security model. Fill in each part. A change that touches signature checks, hash checks, the host allowlist, the path allowlist, or anything near a password needs a clear explanation of why it is safe.
