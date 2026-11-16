# Security policy

## Report a vulnerability

Report vulnerabilities through GitHub private vulnerability reporting. Open the [Security Advisories form](https://github.com/asarelcastellanos/SettleIn/security/advisories/new) and describe the problem there. You can also reach it from the Security tab of this repository.

Do not open a public issue, pull request, or discussion about a vulnerability, and do not post details anywhere public before a fix ships. A public report gives attackers the details before users can update.

Include the version or commit you tested, the steps to reproduce the problem, and what an attacker gains from it.

## Supported versions

SettleIn is pre-alpha and has no release yet. Once releases exist, only the latest release receives security fixes.

| Version | Supported |
| ------- | --------- |
| Latest release | Yes |
| Earlier releases | No |
| Unreleased `main` | Report it, and the owner will fix it before the next release |

## Scope

These reports are in scope.

- A way to bypass the code signature or Team ID check.
- A way to bypass the SHA-256 check on a download.
- A way to download from a host that is not on the download host allowlist, or over a connection that is not HTTPS.
- A path allowlist escape, where the installer or uninstaller reads, writes, or deletes a path that the catalog does not list.
- A way to run a command through a shell string or injected argument.
- Anything that makes the app ask for, read, store, or send a password.

These reports are out of scope.

- Vulnerabilities in the third-party apps that the catalog installs. Report those to the vendor.
- A catalog entry that points to an app you dislike. Open a normal issue for that.
- Attacks that require an attacker who already has administrator access to your Mac.
