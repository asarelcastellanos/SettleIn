#!/bin/bash
# Builds the four install fixtures that the integration tests use.
#
# Usage: bash build-fixtures.sh <output-directory>
#
# The output directory must not exist yet or must be empty. The script creates it when it is missing.
# It writes Fixture.app, Fixture.dmg, Fixture.zip, and Fixture.pkg there. The app is ad hoc signed, so it
# has no Team ID. The package is unsigned. Nothing here needs a password, installs anything, or reads the
# real /Applications folder. The repository holds no binary fixtures, so each run builds them again.

set -euo pipefail
trap 'echo "build-fixtures.sh failed at line $LINENO" >&2' ERR

if [ "$#" -ne 1 ]; then
    echo "usage: build-fixtures.sh <output-directory>" >&2
    exit 2
fi

out="$1"
bundle_id="com.example.SettleInFixture"

mkdir -p "$out"
if [ -n "$(ls -A "$out")" ]; then
    echo "error: $out is not empty" >&2
    exit 2
fi

app="$out/Fixture.app"
mkdir -p "$app/Contents/MacOS"

printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/fixture"
chmod 755 "$app/Contents/MacOS/fixture"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleExecutable</key>
    <string>fixture</string>
    <key>CFBundleName</key>
    <string>Fixture</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF

codesign --force --sign - "$app"

# hdiutil puts the contents of the source folder at the volume root, so the app goes into a folder first.
dmg_source="$(mktemp -d "${TMPDIR:-/tmp}/settlein-fixture-dmg.XXXXXX")"
pkg_root="$(mktemp -d "${TMPDIR:-/tmp}/settlein-fixture-pkg.XXXXXX")"
cleanup() {
    rm -rf "$dmg_source" "$pkg_root"
}
trap cleanup EXIT

# hdiutil sometimes fails with "Resource busy" or "Resource temporarily unavailable" while another
# process creates or attaches an image. The script retries once after one second for those two messages
# and for no other failure.
make_dmg() {
    local attempt output
    for attempt in 1 2; do
        if output="$(hdiutil create -srcfolder "$dmg_source" -volname SettleInFixture -format UDZO -ov \
            "$out/Fixture.dmg" 2>&1)"; then
            return 0
        fi
        case "$output" in
            *"Resource busy"* | *"Resource temporarily unavailable"*)
                if [ "$attempt" -lt 2 ]; then
                    sleep 1
                    continue
                fi
                ;;
        esac
        echo "$output" >&2
        return 1
    done
}

ditto "$app" "$dmg_source/Fixture.app"
make_dmg

ditto -c -k --keepParent "$app" "$out/Fixture.zip"

ditto "$app" "$pkg_root/Fixture.app"
pkgbuild --quiet --root "$pkg_root" --identifier "$bundle_id.pkg" --version 1.0 \
    --install-location /Applications "$out/Fixture.pkg"

echo "Built Fixture.app, Fixture.dmg, Fixture.zip, and Fixture.pkg in $out"
