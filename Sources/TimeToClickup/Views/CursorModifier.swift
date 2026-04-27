import SwiftUI
import AppKit

extension View {
    /// Pushes the given `NSCursor` while the pointer is over the view,
    /// pops it on exit. Stacks correctly with nested cursor modifiers.
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
