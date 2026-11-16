# SettleIn

SettleIn is a macOS app that installs a set of apps from a catalog you can read. You pick the apps, and SettleIn downloads each one, checks it, and installs it. The site will live at settlein.dev.

## Status

Pre-alpha. Version 0.1.0 is in progress, and there is nothing to download yet. The sections below describe the design, and each one links to the issue that builds it.

## Why the code is open source

SettleIn downloads software and installs it on your Mac. You should be able to read exactly what it downloads, how it checks each file, and where it writes. The catalog of apps and the code that installs them are both in this repository, so anyone can audit them.

## Security design

These are design goals for the app. They are not claims about a released build, and nothing here means the app is safe. The code that runs each check will be linked here once it exists.

- The app checks each downloaded app's code signature and compares its Team ID with the catalog entry ([issue 7](https://github.com/asarelcastellanos/SettleIn/issues/7)).
- A versioned catalog entry pins a SHA-256 hash to its download URL, and the app rejects a file with a different hash ([issue 6](https://github.com/asarelcastellanos/SettleIn/issues/6)). An entry whose version is `latest` serves the vendor's newest build, has no hash, and relies on the code signature and Team ID check alone.
- The app downloads over HTTPS only, and only from hosts on an allowlist ([issue 6](https://github.com/asarelcastellanos/SettleIn/issues/6)).
- The app never builds a shell string. It runs each tool with an argument list ([issue 8](https://github.com/asarelcastellanos/SettleIn/issues/8)).
- The uninstaller removes only paths that the catalog lists ([issue 10](https://github.com/asarelcastellanos/SettleIn/issues/10)).
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
