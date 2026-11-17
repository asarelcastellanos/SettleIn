import AppKit

/// Plain yes or no questions that the installer and the uninstaller ask before they replace or quit an app.
enum Confirmation {
    @MainActor
    static func ask(title: String, detail: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
