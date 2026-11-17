# Installing pkg apps

This decision is accepted for v0.2.0.

## Decision

SettleIn installs a `.pkg` by opening it in Installer.app with `/usr/bin/open -a /System/Library/CoreServices/Installer.app <pkg>`. The user sees the standard macOS install window and types the administrator password into macOS. SettleIn never sees, asks for, or stores that password.

Before it opens the package, SettleIn checks the package signature and Team ID with `SignatureVerifier.verifyPackage`. A package that fails the check is never opened.

Next, SettleIn runs `pkgutil --pkg-info <pkgIdentifier>` once and records whether a receipt already exists. A receipt can stay from an earlier install. The already-installed check stops any run that starts with the app bundle present, so a bundle that appears during the polls came from this run.

After Installer.app opens, `PackageInstaller` polls once per second for an app with the catalog bundle ID. Each poll also asks whether Installer.app is running. The poll ends in one of these states.

- `waitingForUser` means Installer.app is open and the app bundle does not exist.
- `installing` means the app bundle exists and the install is not finished.
- `installed` means the app bundle exists and the receipt is new since before the open.
- `installedAfterInstallerClosed` means the app bundle exists and Installer.app has been closed for three polls in a row. SettleIn saw no new receipt. The UI treats it like `installed`, and the log says that no new receipt appeared.
- `cancelled` means Installer.app and the app bundle were both absent for enough polls in a row, or the caller cancelled the task. The poll waits for 3 polls after it saw Installer.app run at least once, and for 10 polls when it never did, because Installer.app can take several seconds to start.
- `failed` means the signature check failed, the install timed out, the app was already installed, or Installer.app did not open.

The timeout is 10 minutes by default. It counts only the polls that find Installer.app closed, so the poll never reports `timedOut` while the Installer window is open. Because three closed polls in a row already end the run, a timeout needs Installer.app to close and reopen repeatedly. This matters because the orchestrator deletes the downloaded package when the poll returns, and Installer.app may still read the file.

Cancelling the task stops the polling. It does not quit Installer.app, because an install in progress has to finish or fail on its own.

The row shows a "Stop waiting" button while the state is `installing` for a pkg. The button calls the orchestrator's `cancel`, which cancels the polling task and never touches Installer.app. The orchestrator then does what a declined install does. It asks LaunchServices for the bundle ID. When the app exists on disk outside the Trash, the row shows "Installed", and otherwise it returns to "Not installed". Without this button a row could wait forever, because an open Installer window never times out.

## Rejected options

1. `osascript` with administrator privileges. SettleIn would start a password prompt that it does not control, and the user could not tell it from a fake prompt. The password path would run through SettleIn code, and SettleIn does not need to take that risk.
2. `sudo installer -pkg`. It also needs a password. SettleIn has no terminal to ask in, so it would have to collect the password in its own window and pass it to `sudo`. That means SettleIn would see the password.
3. A privileged helper tool. The helper installs without a prompt for each package, but it is a root process that SettleIn has to ship, sign, update, and audit. Any bug in it, or in the way the app calls it, runs with root rights. One installer feature does not justify that.

## Cost

SettleIn cannot read the state of Installer.app, so `installing` is inferred. The state means the app bundle exists and the install is not finished. It does not mean Installer.app is copying files. These limits follow.

- Installer.app does not report progress, so SettleIn shows no percentage.
- LaunchServices can report a stale answer for a bundle ID. The manual test plan in issue 12 confirms detection on a clean VM with real Chrome.
- SettleIn cannot tell a user who closed the window from an installer that crashed. Both end as `cancelled` when the bundle is absent.
- Three polls in a row must find Installer.app closed before the result is `installedAfterInstallerClosed` (bundle present, no new receipt). The same count ends the run as `cancelled` (bundle absent) once SettleIn has seen Installer.app run. Before that, `cancelled` needs 10 polls, so a slow start of Installer.app is not read as a quit.
- When a receipt existed before the run, SettleIn cannot see a new receipt. It reports `installed` when Installer.app has been closed for three polls in a row with the bundle present. A user who closes the Installer window before the install finishes, after the bundle was copied, also ends as `installed`.

SettleIn does not use Accessibility APIs or read the Installer.app window to get a better signal. That is out of scope.
