These files are text that macOS tools printed during real runs on macOS 27.2.
SignatureVerifierTests reads them to test the output parsers. Nobody wrote
or edited them by hand.

Each run's temporary folder was replaced with /fixture/path, so no file holds a
home directory path or a user name. Nothing else changed.

The codesign and spctl tools print to stderr, so those files hold stderr.
The pkgutil tool prints to stdout, so those files hold stdout.

codesign-dv-developer-id-app.txt
  Command: codesign -dv --verbose=4 on the installed Google Chrome app.
  The app was only read. Exit code 0.

spctl-accepted-developer-id-app.txt
  Command: spctl --assess --type execute --verbose=4 on the same Chrome app.
  Exit code 0.

codesign-dv-adhoc-app.txt
  Command: codesign -dv --verbose=4 on a tiny test app signed with codesign -s -.
  Exit code 0. It reports TeamIdentifier=not set.

spctl-rejected-adhoc-app.txt
  Command: spctl --assess --type execute --verbose=4 on the same ad hoc app.
  Exit code 3. Gatekeeper rejects an ad hoc signature.

codesign-verify-unsigned-app.txt
codesign-dv-unsigned-app.txt
spctl-rejected-unsigned-app.txt
  Commands: codesign --verify --deep --strict --verbose=2, codesign -dv
  --verbose=4, and spctl --assess --type execute --verbose=4 on a tiny test
  app with no signature. Exit codes 1, 1, and 3.

codesign-verify-tampered-app.txt
  Command: codesign --verify --deep --strict --verbose=2 on the ad hoc app
  after appending a line to its Info.plist. Exit code 1.

pkgutil-signed-package.txt
  Command: pkgutil --check-signature on the signed .pkg that the Rectangle
  project publishes in its latest GitHub release (version 2.0.4). The package
  was downloaded into an empty folder, checked with this one command, and
  deleted. Nobody opened or installed it. Exit code 0.

pkgutil-unsigned-package.txt
  Command: pkgutil --check-signature on a tiny package built with pkgbuild
  and no signature. Exit code 1.
