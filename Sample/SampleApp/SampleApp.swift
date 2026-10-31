import AppKit
import SwiftUI

/// Observable state shared by the window and the menu commands.
@MainActor
final class SampleModel: ObservableObject {
    @Published var clicks = 0
    @Published var shortcuts = 0
    @Published var menuActions = 0
    @Published var contextActions = 0
    @Published var lastModifierClick = "none"
    @Published var hover = "outside"

    /// Regressions are compiled in only for negative-control builds of the sample.
    static var regressions: Set<String> {
        #if REGRESSION_CLICK
        return ["click"]
        #elseif REGRESSION_SHORTCUT
        return ["shortcut"]
        #elseif REGRESSION_TYPING
        return ["typing"]
        #elseif REGRESSION_CONTEXT
        return ["context"]
        #elseif REGRESSION_MENU
        return ["menu"]
        #elseif REGRESSION_MODIFIER
        return ["modifier"]
        #elseif REGRESSION_HOVER
        return ["hover"]
        #elseif REGRESSION_FOCUS
        return ["focus"]
        #else
        return []
        #endif
    }
}

@main
struct SampleApp: App {
    @StateObject private var model = SampleModel()

    var body: some Scene {
        WindowGroup("Sample", id: "main") {
            ContentView(model: model)
        }
        .commands {
            CommandMenu("Sample") {
                Button("Run Shortcut Action") {
                    if !SampleModel.regressions.contains("shortcut") { model.shortcuts += 1 }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Run Menu Action") {
                    if !SampleModel.regressions.contains("menu") { model.menuActions += 1 }
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: SampleModel
    @State private var text = ""
    @State private var otherText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Increment") {
                if !SampleModel.regressions.contains("click") { model.clicks += 1 }
            }
            .accessibilityIdentifier("increment-button")
            Text("Clicks: \(model.clicks)").accessibilityIdentifier("clicks-label")
            Text("Shortcuts: \(model.shortcuts)").accessibilityIdentifier("shortcuts-label")
            Text("Menu actions: \(model.menuActions)").accessibilityIdentifier("menu-label")

            TextField("Name", text: Binding(
                get: { text },
                set: { if !SampleModel.regressions.contains("typing") { text = $0 } }
            ))
            .focused($fieldFocused)
            .accessibilityIdentifier("name-field")
            .frame(width: 240)
            TextField("Other", text: $otherText)
                .accessibilityIdentifier("other-field")
                .frame(width: 240)
            Text("Echo: \(text)").accessibilityIdentifier("echo-label")
            Text("Field focused: \(fieldFocused && !SampleModel.regressions.contains("focus") ? "yes" : "no")")
                .accessibilityIdentifier("focus-label")

            Text("Context target")
                .padding(8)
                .background(Color.secondary.opacity(0.2))
                .accessibilityIdentifier("context-target")
                .contextMenu {
                    Button("Mark Item") {
                        if !SampleModel.regressions.contains("context") { model.contextActions += 1 }
                    }
                }
            Text("Context actions: \(model.contextActions)").accessibilityIdentifier("context-label")

            ModifierClickView(model: model)
                .frame(width: 200, height: 40)
                .accessibilityIdentifier("modifier-target")
            Text("Modifier click: \(model.lastModifierClick)").accessibilityIdentifier("modifier-label")
            Text("Hover: \(model.hover)").accessibilityIdentifier("hover-label")
        }
        .padding(20)
        .frame(width: 420, alignment: .topLeading)
    }
}

/// AppKit view that reports the modifiers of a click and tracking-area hover.
struct ModifierClickView: NSViewRepresentable {
    let model: SampleModel

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        weak var model: SampleModel?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemTeal.withAlphaComponent(0.3).setFill()
            dirtyRect.fill()
        }

        override func mouseDown(with event: NSEvent) {
            guard let model, !SampleModel.regressions.contains("modifier") else { return }
            // Both the event's flags and the global flags are checked: apps read either.
            var parts: [String] = []
            if event.modifierFlags.contains(.shift) && NSEvent.modifierFlags.contains(.shift) { parts.append("shift") }
            if event.modifierFlags.contains(.option) && NSEvent.modifierFlags.contains(.option) { parts.append("option") }
            model.lastModifierClick = parts.isEmpty ? "plain" : parts.joined(separator: "+")
        }

        override func mouseEntered(with event: NSEvent) {
            guard !SampleModel.regressions.contains("hover") else { return }
            model?.hover = "inside"
        }

        override func mouseExited(with event: NSEvent) { model?.hover = "outside" }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
    }
}
