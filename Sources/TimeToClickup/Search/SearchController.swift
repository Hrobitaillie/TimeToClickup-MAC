import AppKit
import Combine

@MainActor
final class SearchController: ObservableObject {
    static let shared = SearchController()

    @Published private(set) var isOpen = false
    private var panel: SearchPanel?
    private var backdrop: BackdropPanel?

    func toggle(anchor: NSRect) {
        isOpen ? close() : open(anchor: anchor)
    }

    func open(anchor: NSRect) {
        if backdrop == nil { backdrop = BackdropPanel() }
        backdrop?.show()

        if panel == nil {
            panel = SearchPanel(onPick: { task in
                TimerState.shared.attach(task: task)
                if !TimerState.shared.isRunning { TimerState.shared.start() }
            })
        }
        panel?.show(below: anchor)
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        panel?.dismiss()
        backdrop?.hide()
        isOpen = false
    }
}
