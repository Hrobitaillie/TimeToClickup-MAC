import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayPanel: OverlayPanel?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        showOverlay()
        TimerState.shared.startSyncing()
        IdleAlertState.shared.startMonitoring()
    }

    /// Even though we're an LSUIElement / accessory app, SwiftUI's
    /// TextFields rely on the Main Menu for the standard editing
    /// shortcuts (⌘C / ⌘V / ⌘X / ⌘A). Without this, copy-paste in
    /// Settings / search popovers silently does nothing.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (placeholder so the rest of macOS is happy).
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Quit TimeToClickup",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — drives ⌘C / ⌘V / ⌘X / ⌘A in any focused field.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        let redo = NSMenuItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "timer",
            accessibilityDescription: "TimeToClickup"
        )
        let menu = NSMenu()
        menu.addItem(.init(title: "Show / Hide overlay",
                           action: #selector(toggleOverlay), keyEquivalent: "h"))
        menu.addItem(.init(title: "Settings…",
                           action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(.init(title: "Quit TimeToClickup",
                           action: #selector(quit), keyEquivalent: "q"))
        for i in menu.items { i.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleOverlay() {
        if let panel = overlayPanel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            showOverlay()
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    private func showOverlay() {
        if overlayPanel == nil {
            overlayPanel = OverlayPanel()
        }
        overlayPanel?.show()
    }
}
