# Test plan for the install engine

This plan checks the install engine on the three real apps in the catalog. The automated tests prove the engine on tiny fixture apps. This plan proves it on Rectangle, AltTab, and Google Chrome, which only a person on a clean machine can do. It closes milestone v0.2.0.

## Safety rules

- Never run this plan on your daily Mac. The Chrome run installs and removes Google Chrome, and the uninstaller moves the Chrome profile folder to the Trash. A Mac that has Chrome installed (the project owner's daily Mac has it) is not a clean machine for the Chrome run. Use a clean machine, or remove Chrome from a test Mac first.
- Use a throwaway VM or a freshly erased Mac. Take a snapshot before the first run, and restore it before each app, so every run starts clean.
- Never type your password into SettleIn. SettleIn never asks for one. The Chrome install shows the standard macOS Installer window, and macOS asks for the password there. If any other window asks for a password, stop and record it as a failure.
- Do not run `sudo` for any step in this plan.

## Environments

Run every app on both architectures.

- Apple silicon. A clean VM that runs macOS 14 or later on an Apple silicon host.
- Intel. A clean Intel Mac, or an Intel VM. Intel macOS cannot run in a VM on an Apple silicon host, so an Intel VM needs an Intel host. Write down in the results table which machine you used.

Record the output of `sw_vers -productVersion` and `uname -m` for each machine. The second command prints `arm64` on Apple silicon and `x86_64` on Intel.

## Build SettleIn

Run these commands from the repository root on the test machine. They build the app into a folder under `$TMPDIR`, outside the repository.

```sh
xcodebuild -project app/SettleIn.xcodeproj -scheme SettleIn -destination 'platform=macOS' \
  -derivedDataPath "$TMPDIR/settlein-dd" build
open "$TMPDIR/settlein-dd/Build/Products/Debug/SettleIn.app"
```

The window lists the three apps. A row shows its state and the buttons that state allows. On a clean machine, every row reads "Not installed".

## Part 1. Install, check, launch, and uninstall each app

These are the catalog values the checks compare against. They come from `catalog/catalog.json`. If the catalog changes, update this table in the same pull request.

| App | Install type | Team ID | Bundle ID |
| --- | --- | --- | --- |
| Rectangle | dmg | `XSYZ3E4B7D` | `com.knollsoft.Rectangle` |
| AltTab | zip | `QXD7GW8FHY` | `com.lwouis.alt-tab-macos` |
| Google Chrome | pkg | `EQHXZ8M8AV` | `com.google.Chrome` |

Do these steps for each app, one app at a time. Restore the snapshot between apps.

1. Check the starting state. The app is not in `/Applications`, and its row in SettleIn reads "Not installed". For example, run `ls /Applications | grep -i rectangle`, which prints nothing.
2. Click Install in the app's row. Watch the status go from "Downloading" to "Verifying" to "Installing" to "Installed". For Chrome, the macOS Installer window opens after "Verifying". Finish the install there and type the password into that window only.
3. Confirm the app is in `/Applications`, then confirm its signature.

   ```sh
   codesign -dv --verbose=4 "/Applications/Rectangle.app" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority"
   spctl --assess --type execute --verbose=4 "/Applications/Rectangle.app"
   ```

   Use the app's own path from the list below. The `TeamIdentifier` line must equal the Team ID in the table, character for character. The `Identifier` line must equal the bundle ID. `spctl` must print `accepted`. Copy the `TeamIdentifier` line into the results table notes.
4. Launch the app and confirm the process runs, then quit it.

   ```sh
   open "/Applications/Rectangle.app"
   pgrep -x Rectangle
   ```

   The process names are `Rectangle`, `AltTab`, and `Google Chrome`. `pgrep` prints a process ID when the app runs. Rectangle and AltTab ask for the Accessibility permission on first launch. You may deny it, because this plan checks only that the app starts. Quit the app before the next step.
5. For Chrome only, confirm the package receipt.

   ```sh
   pkgutil --pkg-info com.google.Chrome
   ```

   The command must exit with 0. SettleIn does not remove the receipt, and removing it needs `sudo`, so leave it.
6. Click Uninstall in the app's row. The row returns to "Not installed".
7. Check for leftover paths. Every path in the list for the app must be gone.

   ```sh
   ls -d "/Applications/Rectangle.app" \
     "$HOME/Library/Application Support/Rectangle" \
     "$HOME/Library/Preferences/com.knollsoft.Rectangle.plist" \
     "$HOME/Library/Caches/com.knollsoft.Rectangle" 2>&1
   ```

   Every line must say "No such file or directory".
8. Check the Trash. Run `ls -A "$HOME/.Trash"`, or open the Trash in Finder if Terminal has no permission to read it. The app and each support path that existed before the uninstall must be there. Paths that never existed are not in the Trash, and that is fine.
9. Check that the install left nothing behind. Both commands must print `0` or nothing.

   ```sh
   ls "$TMPDIR" | grep -cE "SettleIn-[0-9A-F]{8}-"
   hdiutil info | grep -c "Rectangle"
   ```

   Use the app's name in the second command.

Paths to check for each app. The first path is the app. The rest come from the `uninstallPaths` list in the catalog.

- Rectangle
  - `/Applications/Rectangle.app`
  - `~/Library/Application Support/Rectangle`
  - `~/Library/Preferences/com.knollsoft.Rectangle.plist`
  - `~/Library/Caches/com.knollsoft.Rectangle`
- AltTab
  - `/Applications/AltTab.app`
  - `~/Library/Preferences/com.lwouis.alt-tab-macos.plist`
  - `~/Library/Caches/com.lwouis.alt-tab-macos`
- Google Chrome
  - `/Applications/Google Chrome.app`
  - `~/Library/Application Support/Google/Chrome`
  - `~/Library/Caches/Google/Chrome`
  - `~/Library/Preferences/com.google.Chrome.plist`

Record pass in the results table only when every step held. Record fail and the step number otherwise.

## Part 2. Negative runs

Each run changes the catalog in a local build and expects SettleIn to refuse the install and install nothing. Use Rectangle for both runs, on a machine where Rectangle is not installed. Restore the catalog after each run.

### Wrong sha256

1. Change the first characters of Rectangle's `sha256` in the catalog. The value stays 64 hex characters, so the catalog still passes validation.

   ```sh
   sed -i '' 's/9f820a2e56bd2c27/0000000000000000/' catalog/catalog.json
   bash catalog/validate.sh
   ```

2. Build the app into a separate folder and open it.

   ```sh
   xcodebuild -project app/SettleIn.xcodeproj -scheme SettleIn -destination 'platform=macOS' \
     -derivedDataPath "$TMPDIR/settlein-dd-negative" build
   open "$TMPDIR/settlein-dd-negative/Build/Products/Debug/SettleIn.app"
   ```

3. Click Install in the Rectangle row. Expected result. The row shows "Failed" with the message "The downloaded file does not match the SHA-256 in the catalog, so SettleIn deleted it and installed nothing."
4. Click Copy log, then check the log from the clipboard. Each command prints the number after the arrow.

   ```sh
   pbpaste | grep -c "failed: The downloaded file does not match the SHA-256"   # 1
   pbpaste | grep -c "state: downloading -> failed"                              # 1
   pbpaste | grep -c "downloaded to"                                             # 0
   pbpaste | grep -c "installed at"                                              # 0
   ```

5. Confirm nothing is installed or left behind.

   ```sh
   ls -d /Applications/Rectangle.app 2>&1                  # No such file or directory
   ls "$TMPDIR" | grep -cE "SettleIn-[0-9A-F]{8}-"         # 0
   hdiutil info | grep -c "Rectangle"                      # 0
   ```

6. Restore the catalog with `git checkout -- catalog/catalog.json`. Record the run in the results table as a fail row, because the install fails by design. In the notes, write "refused, installed nothing" when every check above held.

### Wrong teamID

1. Change Rectangle's `teamID` in the catalog to a Team ID that Rectangle's developer does not own. The value stays 10 uppercase characters, so the catalog still passes validation.

   ```sh
   sed -i '' 's/XSYZ3E4B7D/AAAAAAAAAA/' catalog/catalog.json
   bash catalog/validate.sh
   ```

2. Build and open the app as in the previous run.
3. Click Install in the Rectangle row. The download passes the checksum, so the status reaches "Verifying" before it fails. Expected result. The row shows "Failed" with the message "The signature belongs to Team ID XSYZ3E4B7D, but the catalog expects Team ID AAAAAAAAAA. SettleIn installed nothing."
4. Click Copy log, then check the log from the clipboard.

   ```sh
   pbpaste | grep -c "The signature belongs to Team ID XSYZ3E4B7D, but the catalog expects Team ID AAAAAAAAAA"   # 1
   pbpaste | grep -c "state: verifying -> failed"                                                              # 1
   pbpaste | grep -c "downloaded to"                                                                           # 1
   pbpaste | grep -c "installed at"                                                                            # 0
   ```

5. Run the three commands from step 5 of the previous run. They must give the same results.
6. Restore the catalog with `git checkout -- catalog/catalog.json`, and record the run in the results table the same way.

## Part 3. Edge cases

The automated column names the test in `app/SettleInCore/Tests/SettleInCoreTests/` that covers the case. Run them with `swift test --package-path app/SettleInCore --filter IntegrationTests`. A case marked manual has a reason, because no test can cause it safely or at all.

| Case | How to trigger it | Expected result | Automated or manual |
| --- | --- | --- | --- |
| Network drop | Automated. The stub sends half of the file, then fails with `networkConnectionLost`. Manual. Click Install on Chrome, and turn off the VM network while the progress bar moves. | The row shows "Failed" with "The download failed with network error code" and a number. Nothing is in `/Applications`, and `ls "$TMPDIR" \| grep -cE "SettleIn-[0-9A-F]{8}-"` prints `0`. | Automated (`networkDropMidTransferInstallsNothing`). The manual run confirms the real network stack. |
| Disk full | The test injects a free-space provider that reports 1024 bytes. | The install fails with "The install needs ... of free space" before it copies anything. Nothing is in `/Applications`, and no image stays mounted. | Automated (`notEnoughFreeSpaceStopsBeforeAnyCopy`). No manual run, because filling a real disk risks the machine and the test covers the same check. |
| Quarantine flag | The test runs `xattr -w com.apple.quarantine "0083;00000000;Test;"` on the fixture dmg, then installs it. | The flag does not decide the result. The install succeeds when the signature check passes (`quarantinedImageInstallsWhenTheSignatureCheckPasses`) and fails when it does not (`quarantinedImageIsRefusedWhenTheSignatureCheckFails`). | Automated. On the VM, also run `xattr -l "/Applications/Rectangle.app"` after the install and write the output in the notes. Record it only. It is not a pass or fail check. |
| App already installed | The test puts an app with the same bundle ID at the destination, then installs. It also tries an app with another bundle ID at the same path, and an app the orchestrator already found. | With the same bundle ID, SettleIn asks before it replaces the app, and a "no" keeps the old app (`installedAppIsReplacedAfterTheUserConfirms`, `installedAppStaysWhenTheUserDeclinesTheReplace`). With another bundle ID, SettleIn leaves the app alone (`differentAppAtTheDestinationIsLeftAlone`). An app that is already installed gets no install (`orchestratorRefusesToInstallAnAppItAlreadyFound`). | Automated. Manual check. Copy Rectangle into `/Applications` by hand, then open SettleIn. The row must read "Installed" with no Install button. |
| App running | The test uses a fake running-app provider, because the fixture app never launches. It covers a confirmed quit, a refused quit, a quit that fails, and an uninstall while the app runs. | A confirmed quit replaces the app (`runningAppQuitsAfterTheUserConfirmsAndIsReplaced`). A refused or failed quit stops the install with "The app is still running" and leaves the old app (`runningAppIsNotReplacedWhenTheUserRefusesToQuit`, `runningAppThatDoesNotQuitIsNotReplaced`). An uninstall of a running app removes nothing (`uninstallRefusesWhileTheAppRunsAndRemovesNothing`). | Automated with the fake. Manual for the real quit. Launch Rectangle, click Uninstall, and choose "Quit and remove". Rectangle quits and moves to the Trash. Repeat and choose Cancel. The row shows "Failed" with "The app is still running", and Rectangle stays. |
| User cancels the Installer | The test replaces `open` and the Installer.app monitor with fakes. The fake reports that Installer.app quit and the app never appeared. Manual. Click Install on Chrome, then quit Installer.app from its menu or close its window before the install finishes. | The row returns to "Not installed" within a few seconds. Nothing is in `/Applications`. The log holds "Installer.app quit before the app appeared". | Automated (`userCancellingInstallerEndsIdleWithNothingInstalled`). The manual run confirms the real Installer.app. |

## Results table

Copy this table into the pull request description and fill it in. Use one row per app and architecture, and one row per negative run. Write the `TeamIdentifier` line from `codesign -dv` in the notes for each app. In the notes, name the machine used for each Intel row.

| App | Architecture | macOS version | Pass or fail | Notes |
| --- | --- | --- | --- | --- |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
