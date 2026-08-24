import AppKit

/// Walks a window's live accessibility tree and reports controls VoiceOver
/// could not announce (NFR-6, M4-06).
///
/// Why this exists: plan §8 leaves us with no XCTest UI tests and, most of the
/// time, no unlocked screen — so "every control has a label" cannot be checked
/// by a human looking at Accessibility Inspector on demand. But the tree itself
/// is just AppKit objects, and `NSAccessibility`'s protocol methods answer the
/// same questions the Inspector asks. A `Settings` window is built by SwiftUI
/// without ever being shown, which makes this runnable in a scripted phase.
///
/// The rule it enforces is deliberately narrow, so it never has to be argued
/// with: **anything that has an action, or is an image the user can see, must
/// have a label, a title, or help text.** Decorative images are expected to be
/// `accessibilityHidden(true)`, which removes them from the tree entirely and
/// therefore from this walk.
///
/// It cannot replace a VoiceOver pass — it does not know whether a label reads
/// well, whether focus order makes sense, or whether a rotor finds anything.
/// `docs/a11y-checklist.md` records that split.
@MainActor
enum AccessibilityAudit {

    /// One control the walk objected to.
    struct Finding: Sendable {
        var role: String
        var path: String
        var reason: String

        var description: String { "\(path) [\(role)] — \(reason)" }
    }

    struct Report: Sendable {
        /// Every element the walk visited that could hold a label.
        var controlsChecked = 0
        /// Controls with an action (buttons, checkboxes, pop-ups, menu items).
        var actionableChecked = 0
        /// Images that are still in the tree — i.e. not `accessibilityHidden`.
        var imagesChecked = 0
        var findings: [Finding] = []
        /// Elements visited in total, including groups and static text.
        var elementsVisited = 0
        /// Role → count, so a phase that suddenly walks a *different* tree is
        /// visible in the log rather than silently passing on nothing.
        var roles: [String: Int] = [:]

        var isClean: Bool { findings.isEmpty }

        var roleSummary: String {
            roles.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(8)
                .map { "\($0.key.replacingOccurrences(of: "AX", with: ""))=\($0.value)" }
                .joined(separator: " ")
        }
    }

    /// Roles that must be announceable: a control that does something.
    private static let actionableRoles: Set<String> = [
        NSAccessibility.Role.button.rawValue,
        NSAccessibility.Role.checkBox.rawValue,
        NSAccessibility.Role.radioButton.rawValue,
        NSAccessibility.Role.popUpButton.rawValue,
        NSAccessibility.Role.menuButton.rawValue,
        NSAccessibility.Role.slider.rawValue,
        NSAccessibility.Role.incrementor.rawValue,
        NSAccessibility.Role.textField.rawValue,
        NSAccessibility.Role.comboBox.rawValue,
        NSAccessibility.Role.disclosureTriangle.rawValue,
    ]

    /// Roles that carry meaning visually and so need a text equivalent.
    private static let imageRoles: Set<String> = [
        NSAccessibility.Role.image.rawValue,
    ]

    /// The window's own furniture. AppKit draws the close/minimise/zoom buttons
    /// and the full-screen control itself, publishes them with a *subrole* and
    /// no label, and VoiceOver announces them from the subrole — so they are
    /// correctly labelled by the system and are not ours to fix.
    private static let systemSubroles: Set<String> = [
        NSAccessibility.Subrole.closeButton.rawValue,
        NSAccessibility.Subrole.minimizeButton.rawValue,
        NSAccessibility.Subrole.zoomButton.rawValue,
        NSAccessibility.Subrole.fullScreenButton.rawValue,
        NSAccessibility.Subrole.toolbarButton.rawValue,
    ]

    /// Containers whose insides belong to AppKit: a scroller's arrows and knob
    /// are drawn and announced by the system, not by us.
    private static let systemContainerRoles: Set<String> = [
        NSAccessibility.Role.scrollBar.rawValue,
        NSAccessibility.Role.valueIndicator.rawValue,
    ]

    // MARK: - Walking

    static func audit(window: NSWindow?, named name: String) -> Report {
        var report = Report()
        guard let window else { return report }
        var visited: Set<ObjectIdentifier> = []
        visit(window, path: name, depth: 0, inherited: nil, visited: &visited, report: &report)
        return report
    }

    /// Depth is bounded: a SwiftUI tree can be surprisingly deep, and a cycle
    /// in a badly behaved accessibility proxy would otherwise hang a phase.
    private static let maxDepth = 40

    private static func visit(
        _ element: Any, path: String, depth: Int, inherited: String?,
        visited: inout Set<ObjectIdentifier>, report: inout Report
    ) {
        guard depth < maxDepth else { return }
        // The AX tree and the `NSView` tree overlap heavily — the same control
        // is reachable by several routes — so identity, not position, is what
        // says whether it has been seen.
        guard visited.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
        // A hidden view is not on screen and not in VoiceOver's way.
        if let view = element as? NSView, view.isHidden { return }
        report.elementsVisited += 1

        let object = element as AnyObject
        let role = string(object, #selector(NSAccessibilityProtocol.accessibilityRole)) ?? ""
        let subrole = string(object, #selector(NSAccessibilityProtocol.accessibilitySubrole)) ?? ""
        let label = string(object, #selector(NSAccessibilityProtocol.accessibilityLabel))
        let title = string(object, #selector(NSAccessibilityProtocol.accessibilityTitle))
        let help = string(object, #selector(NSAccessibilityProtocol.accessibilityHelp))
        let value = string(object, #selector(NSAccessibilityProtocol.accessibilityValue))
        let name = [label, title].compactMap { $0 }.first { !$0.isEmpty }

        let here = path + " › " + describe(role: role, name: name)
        report.roles[role.isEmpty ? "AXNone" : role, default: 0] += 1
        guard !systemContainerRoles.contains(role) else { return }

        if actionableRoles.contains(role) {
            if !systemSubroles.contains(subrole) {
                report.controlsChecked += 1
                report.actionableChecked += 1
                if name == nil, (help ?? "").isEmpty, (value ?? "").isEmpty, inherited == nil {
                    report.findings.append(Finding(
                        role: role, path: here + locate(object),
                        reason: "no accessibilityLabel, title or help, and no named ancestor — "
                            + "VoiceOver would announce only its role"
                    ))
                }
            }
            // A control is a leaf as far as VoiceOver is concerned. AppKit
            // builds steppers out of two nested buttons and tab items out of a
            // button inside a button; none of those internals is ever spoken
            // separately, and objecting to them would be objecting to AppKit.
            return
        } else if imageRoles.contains(role) {
            report.controlsChecked += 1
            report.imagesChecked += 1
            if name == nil, (help ?? "").isEmpty, inherited == nil {
                report.findings.append(Finding(
                    role: role, path: here + locate(object),
                    reason: "a visible image with no label — decorative glyphs must be accessibilityHidden(true)"
                ))
            }
        }

        // A control wrapped by a named container is announced through that
        // container — which is exactly what `.accessibilityElement(children:)`
        // and SwiftUI's own control wrappers do. Carrying the name down is what
        // keeps this walk from objecting to correct code.
        let nameForChildren = inherited ?? name.flatMap { $0.isEmpty ? nil : $0 }
        for child in children(of: object) {
            visit(child, path: here, depth: depth + 1, inherited: nameForChildren,
                  visited: &visited, report: &report)
        }
    }

    /// Where on screen the offender is, so a finding can be matched to a row in
    /// the pane without guessing. A path of `AXUnknown`s is otherwise not much
    /// of a clue.
    private static func locate(_ object: AnyObject) -> String {
        guard let view = object as? NSView else { return "" }
        let frame = view.convert(view.bounds, to: nil)
        return String(
            format: " @(%.0f,%.0f %.0f×%.0f) %@",
            frame.origin.x, frame.origin.y, frame.width, frame.height,
            String(describing: type(of: view))
        )
    }

    private static func describe(role: String, name: String?) -> String {
        let role = role.isEmpty ? "?" : role
        guard let name, !name.isEmpty else { return role }
        return "\(role)(\(name.prefix(40)))"
    }

    /// `accessibilityChildren()` is the tree SwiftUI actually publishes; a few
    /// AppKit containers only answer `accessibilityChildrenInNavigationOrder`,
    /// so both are merged.
    private static func children(of object: AnyObject) -> [Any] {
        var out: [Any] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ candidates: [Any]) {
            for kid in candidates {
                guard seen.insert(ObjectIdentifier(kid as AnyObject)).inserted else { continue }
                out.append(kid)
            }
        }
        for selector in [
            #selector(NSAccessibilityProtocol.accessibilityChildren),
            #selector(NSAccessibilityProtocol.accessibilityChildrenInNavigationOrder),
        ] {
            guard object.responds(to: selector),
                  let kids = object.perform(selector)?.takeUnretainedValue() as? [Any] else { continue }
            add(kids)
        }
        // A window that has never been on screen publishes a shallow AX tree —
        // SwiftUI only materialises the deep one when something asks the view
        // hierarchy. Descending the real `NSView` tree as well is what makes
        // this usable on a locked screen, which is the case that matters here.
        if let window = object as? NSWindow, let content = window.contentView {
            add([content])
        }
        if let view = object as? NSView {
            add(view.subviews)
        }
        return out
    }

    private static func string(_ object: AnyObject, _ selector: Selector) -> String? {
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}
