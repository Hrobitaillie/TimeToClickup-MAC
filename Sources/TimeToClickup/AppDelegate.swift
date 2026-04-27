import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayPanel: OverlayPanel?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        showOverlay()
        TimerState.shared.startSyncing()
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
