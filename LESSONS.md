# Lessons

## 2026-11-16: Docs stated a rule the design allows exceptions to
- What happened: The README said every catalog entry pins a SHA-256, but entries marked `latest` have no hash and rely on the Team ID check.
- Caught by: the review
- Fix: When a design exception is added, grep the docs for each claim it breaks. The README, the issue form, and CONTRIBUTING now state the exception.

## 2026-11-16: Dependabot entry pointed at a missing manifest
- What happened: dependabot.yml listed npm for /site before site/ had a package.json.
- Caught by: the review
- Fix: Add a Dependabot entry in the same PR that adds its manifest. The comment in dependabot.yml says so.

## 2026-11-16: Docs told contributors to run a script that did not exist
- What happened: CONTRIBUTING and the PR template required `bash catalog/validate.sh` before issue 5 created it.
- Caught by: the review
- Fix: Docs name the issue that adds a command until the command exists.

## 2026-11-16: A fake ignored the value the test was meant to check
- What happened: The signature and package fakes ignored the expected Team ID and bundle ID, so a hard-coded value passed every test.
- Caught by: the review
- Fix: Fakes record the arguments they receive, and tests assert the catalog values. Mutation checks show each new test fails without its fix.

## 2026-11-16: Uninstall paths were checked by folder only
- What happened: The allowlist accepted paths such as ~/Library/Keychains/login.keychain-db and paths inside another app.
- Caught by: the review
- Fix: Paths must sit in an allowed Library folder or be /Applications/<Name>.app, and a real bundle on disk must carry the catalog bundle ID. docs/catalog.md lists the rules.

## 2026-11-16: A fix replaced a bundle check with a name check
- What happened: The first fix refused any path component that ended in .app, so a plain folder named com.vendor.app blocked a pkg uninstall.
- Caught by: the second review
- Fix: The uninstaller checks for Contents/Info.plist on disk before it treats a folder as a bundle, and a test covers a plain folder named like an app.

## 2026-11-16: Cancelling a task left the child process running
- What happened: ProcessCommandRunner ignored cancellation, so a timed-out hdiutil kept running, and cleanup after a cancel did not run.
- Caught by: the review
- Fix: The runner ends the child on cancel, and cleanup runs in a detached task. Tests use a child that ignores the terminate signal.

## 2026-11-16: Test helpers could hang or leave processes behind
- What happened: A cleanup used a signal the child ignored, and pkg tests looped forever when a rule regressed.
- Caught by: the review
- Fix: Cleanup uses kill -9 with a unique marker, the fake clock stops after 5,000 sleeps, and the pkg suites carry a time limit.
