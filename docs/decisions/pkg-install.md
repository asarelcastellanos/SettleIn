# Installing pkg apps

This decision is accepted for v0.2.0.

## Decision

SettleIn installs a `.pkg` by opening it in Installer.app with `/usr/bin/open -a /System/Library/CoreServices/Installer.app <pkg>`. The user sees the standard macOS install window and types the administrator password into macOS. SettleIn never sees, asks for, or stores that password.

Before it opens the package, SettleIn checks the package signature and Team ID with `SignatureVerifier.verifyPackage`. A package that fails the check is never opened.

After Installer.app opens, `PackageInstaller` polls once per second for an app with the catalog bundle ID. It ends in one of these states.

- `waitingForUser` means Installer.app is open and the app bundle does not exist.
- `installing` means the app bundle exists and `pkgutil --pkg-info <pkgIdentifier>` reports no receipt.
- `installed` means the app bundle and the receipt both exist.
- `cancelled` means Installer.app quit and the bundle never appeared, or the caller cancelled the task.
- `failed` means the signature check failed, the install timed out (10 minutes by default), the app was already installed, or Installer.app did not open.

Cancelling the task stops the polling. It does not quit Installer.app, because an install in progress has to finish or fail on its own.

## Rejected options

1. `osascript` with administrator privileges. SettleIn would start a password prompt that it does not control, and the user could not tell it from a fake prompt. The password path would run through SettleIn code, and SettleIn does not need to take that risk.
2. `sudo installer -pkg`. It also needs a password. SettleIn has no terminal to ask in, so it would have to collect the password in its own window and pass it to `sudo`. That means SettleIn would see the password.
3. A privileged helper tool. The helper installs without a prompt for each package, but it is a root process that SettleIn has to ship, sign, update, and audit. Any bug in it, or in the way the app calls it, runs with root rights. One installer feature does not justify that.

## Cost

SettleIn cannot read the state of Installer.app, so `installing` is inferred. The state means the app bundle exists and the receipt does not exist yet. It does not mean Installer.app is copying files. Three limits follow.

- Installer.app does not report progress, so SettleIn shows no percentage.
- LaunchServices can report a stale answer for a bundle ID. The manual test plan in issue 12 confirms detection on a clean VM with real Chrome.
- SettleIn cannot tell a user who closed the window from an installer that crashed. Both end as `cancelled` when the bundle is absent.

SettleIn does not use Accessibility APIs or read the Installer.app window to get a better signal. That is out of scope.
