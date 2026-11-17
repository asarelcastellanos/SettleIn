# Catalog format

The catalog is `catalog/catalog.json`. It is the root of trust for the app, so a bad value there defeats every later check. `catalog/catalog.schema.json` describes the file as a JSON Schema, and `CatalogParser.parse(_:)` in `app/SettleInCore/Sources/SettleInCore/Catalog/` enforces the same rules in Swift when the app reads the file. The parser runs once, at the boundary. Every other part of the app uses the parsed types and does not check them again.

## Fields

The file is an object with one key, `apps`, which holds a list of entries. Each entry has these fields.

- `id` is a lowercase name made of words joined by hyphens, such as `google-chrome`. It is unique in the file.
- `name`, `category`, and `homepage` describe the app. `homepage` is an `https` URL.
- `version` is the release the entry pins, or the literal `latest`.
- `installType` is `dmg`, `zip`, or `pkg`.
- `appName` is the `.app` folder name inside the archive. A `dmg` or `zip` entry has it, and a `pkg` entry does not.
- `pkgIdentifier` is the package ID that `pkgutil` reports. A `pkg` entry has it, and a `dmg` or `zip` entry does not.
- `allowedHosts` lists every host a download may use, including the hosts the download redirects to.
- `teamID` is the vendor's Team ID, 10 uppercase letters or digits.
- `bundleID` is the app's bundle identifier.
- `uninstallPaths` lists the paths the uninstaller may remove. A `pkg` entry lists its app as `/Applications/<Name>.app`.
- `architecture` is `universal` or `perArch`. A `universal` entry has `downloadURL` and an optional `sha256`. A `perArch` entry has an `arm64` object and an `x86_64` object, and each holds `downloadURL` and an optional `sha256`. An entry cannot hold both forms. In Swift they are two cases of the `DownloadSource` enum.

## Rules

- A `version` other than `latest` needs a `sha256` for every download. A `latest` entry has none, and it relies on the Team ID check alone.
- Every URL uses `https`.
- Every download host is in `allowedHosts`.
- A `pkg` entry lists at least one `/Applications/<Name>.app` path in `uninstallPaths`, so the uninstaller can remove the app. The parser rejects a `pkg` entry without one.
- An uninstall path has one of three forms. `UninstallPath` and the schema check the same rules.
  - `/Applications/<Name>.app`, and nothing deeper.
  - `~/Library/<folder>/<more>`. The folder is Application Support, Caches, Preferences, Logs, Containers, Saved Application State, HTTPStorages, WebKit, or Cookies, spelled with exactly that letter case. A direct child of `~/Library` is not allowed, so the path goes at least one level below the folder.
  - `~/.config/<name>`, or a path below it. A `~/.config/<name>` entry removes a whole folder, so a reviewer must check that the folder belongs to the app.
- Under `/Applications`, nothing goes inside an `.app`. Under `~/Library` and `~/.config`, a folder name may end in `.app`, such as `~/Library/Containers/com.vendor.app`. The path has no `..` component, no wildcard (`*`, `?`, `[`, `]`, `{`, `}`), no empty or `.` component, and no control character. The Swift type `UninstallPath` checks the catalog text only. The uninstaller checks symlinks at run time, and `PathGuard` applies the same shape rules again to the resolved path. Before it removes a path, the uninstaller also looks at the disk. When the path or a folder above it, up to the allowed folder, has a name that ends in `.app` and holds `Contents/Info.plist`, that folder is a real bundle, and its bundle identifier must equal the entry's `bundleID`. Otherwise the uninstaller leaves the path alone. A folder named `com.vendor.app` with no `Contents/Info.plist` is a plain folder and is removed normally. For a `dmg` or `zip` entry the app is the `appName` bundle in `/Applications`. For a `pkg` entry the app is each listed `/Applications/<Name>.app`. Every other listed path is a support path.
- A SHA-256 is 64 hex characters. The parser stores it in lowercase.

## Validate the schema

Run this command from the repository root. It needs Node.js and `npx`.

```sh
bash catalog/validate.sh
```

The script runs `ajv-cli` version 5.0.0 through `npx`. The version is written in `catalog/validate.sh`. Change it there and in this file together. The script checks that the schema is valid, then validates `catalog/catalog.json` against it. It exits with 0 on success and a non-zero code on any failure. It also takes the path of another catalog file.

```sh
bash catalog/validate.sh catalog/fixtures/invalid/bad-team-id.json
```

The fixtures in `catalog/fixtures/` are test data for the schema and for `CatalogTests`. They are not catalog entries, and their values are made up. Each file in `catalog/fixtures/invalid/` breaks one rule. This loop prints the exit code of each one.

```sh
for f in catalog/fixtures/invalid/*.json; do bash catalog/validate.sh "$f" >/dev/null 2>&1; echo "$? $f"; done
```

Every fixture prints a non-zero code except the two in the next section. The path fixtures cover a Keychains path, an iCloud Drive path, a path inside an `.app`, and a deep `/Applications` path. `pkg-without-app.json` covers a `pkg` entry with no `/Applications/<Name>.app` path, and `bad-app-name.json` covers an `appName` that holds a path separator.

## Rules the schema cannot express

JSON Schema cannot compare one value in a file with another, so these rules live only in the Swift parser and in review.

- A download host must be in `allowedHosts`. The fixture `host-not-allowed.json` fails in Swift and passes the schema.
- An `id` must not repeat. The fixture `duplicate-id.json` fails in Swift and passes the schema.
- The schema accepts a version string of any text. Only `latest` has a special meaning.
- `allowedHosts` must list each host a download redirects to. A person checks this with `curl -sIL <url>` when writing the entry, and no program can check it from the file alone.
- The Team ID, bundle ID, package identifier, SHA-256, and uninstall paths must be true for the vendor's app. The schema checks their shape. A reviewer checks the values with `codesign -dv --verbose=4`, `pkgutil`, and `shasum -a 256`, as [CONTRIBUTING.md](../CONTRIBUTING.md) describes.
- The Swift parser also parses each URL with Foundation and rejects a URL with a user name or password. The schema checks only the text of the URL.
