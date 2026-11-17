# SettleIn

SettleIn is a macOS app that installs a set of apps from a catalog you can read. You pick the apps, and SettleIn downloads each one, checks it, and installs it. The site will live at settlein.dev.

## Status

Pre-alpha. This is version 0.2.0, and there is nothing to download yet. The repository holds the catalog parser, the downloader, the signature verifier, the dmg, zip, and pkg installers, the uninstaller, the install orchestrator, and a plain window that runs them. None of it has had a release or an outside review. The sections below describe the design and link to the code for each part.

## Why the code is open source

SettleIn downloads software and installs it on your Mac. You should be able to read exactly what it downloads, how it checks each file, and where it writes. The catalog of apps and the code that installs them are both in this repository, so anyone can audit them.

## Security design

These are design goals for the app. They are not claims about a released build, and nothing here means the app is safe. Each item links to the code that runs the check.

- The app checks each downloaded app's code signature and compares its Team ID with the catalog entry ([`SignatureVerifier`](app/SettleInCore/Sources/SettleInCore/Signature/SignatureVerifier.swift)). The install runs in a fixed order. The reducer cannot go from `downloading` to `installing` without `verifying` ([`InstallState`](app/SettleInCore/Sources/SettleInCore/Orchestration/InstallState.swift)), and the installer runs the signature check inside its call, so a dmg or zip row reads "Checking and installing" until the app is in place.
- A versioned catalog entry pins a SHA-256 hash to its download URL, and the app rejects a file with a different hash ([`Downloader`](app/SettleInCore/Sources/SettleInCore/Download/Downloader.swift)). An entry whose version is `latest` serves the vendor's newest build, has no hash, and relies on the code signature and Team ID check alone.
- The app downloads over HTTPS only, and only from hosts on an allowlist, for the first URL and for every redirect ([`DownloadPolicy`](app/SettleInCore/Sources/SettleInCore/Download/DownloadPolicy.swift)).
- The app never builds a shell string. It runs each tool with an argument list ([`ProcessCommandRunner`](app/SettleInCore/Sources/SettleInCore/Signature/ProcessCommandRunner.swift)).
- The uninstaller removes only the app the catalog entry names and the paths the entry lists, and it checks each path again right before it removes it ([`Uninstaller`](app/SettleInCore/Sources/SettleInCore/Uninstall/Uninstaller.swift)).
- The app never asks for or handles your password.

## How to verify a release

Releases do not exist yet. When they do, check a downloaded copy of SettleIn with these steps.

1. Run `codesign -dv --verbose=4 /Applications/SettleIn.app` and confirm the Team ID matches the one published on the release page.
2. Run `spctl --assess --verbose /Applications/SettleIn.app` and confirm it reports the app as accepted.
3. Run `shasum -a 256` on the downloaded archive and compare the result with the SHA-256 published on the release page.

## Testing

The project tests locally on a Mac before each release, and a weekly catalog check runs on GitHub Actions starting at v0.9.0. [CONTRIBUTING.md](CONTRIBUTING.md) lists the test commands.

## Repository layout

- [`app/`](app/README.md) holds the Xcode project and the Swift package.
- [`site/`](site/README.md) holds the website.
- [`catalog/`](catalog/README.md) holds the app catalog and its schema.
- [`docs/`](docs/README.md) holds design notes and decision records.

## Contributing and security reports

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you open a pull request. Report vulnerabilities through the process in [SECURITY.md](SECURITY.md), and never in a public issue.

## License

SettleIn uses the [MIT license](LICENSE).
