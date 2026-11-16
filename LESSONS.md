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
