import AppKit
import SwiftUI

/// Hands the hosting `NSWindow` to SwiftUI once it exists.
///
/// Used for the things AppKit still owns: the frame autosave name (FR-1.5) and
/// the resign-key flush point (FR-2.3).
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Reports the live width of the view it decorates, so the sidebar's column
/// width can be remembered across launches (FR-1.5).
struct WidthReporter: View {
    var onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in onChange(width) }
        }
    }
}

@MainActor
enum FirstResponder {
    /// Moves focus to the sidebar's outline view (⌘1). SwiftUI does not expose
    /// its `List` to `@FocusState` on macOS 14, so this walks the hierarchy.
    static func focusSidebar() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        guard let outline = firstOutlineView(in: window.contentView) else { return }
        window.makeFirstResponder(outline)
    }

    private static func firstOutlineView(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let found = firstOutlineView(in: subview) { return found }
        }
        return nil
    }
}
