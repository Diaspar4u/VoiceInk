import AppKit
import SwiftUI

enum AppWindowLayout {
    static let width: CGFloat = 950
    static let minimumHeight: CGFloat = 750
}

enum WindowDiagnostics {
    static func visibleUserFacingWindows(excluding excludedWindow: NSWindow? = nil) -> [NSWindow] {
        NSApplication.shared.windows.filter { window in
            if let excludedWindow, window == excludedWindow {
                return false
            }

            return window.isVisible && window.level == .normal && window.styleMask.contains(.titled)
        }
    }
}

enum AppPresentationPolicy {
    static func activationPolicy(isDockless: Bool) -> NSApplication.ActivationPolicy {
        isDockless ? .accessory : .regular
    }

    static func activateForUserFacingWindow() {
        let isDockless = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
        NSApplication.shared.setActivationPolicy(activationPolicy(isDockless: isDockless))
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func restoreAccessoryIfNeededAfterUserFacingWindowClosed() {
        DispatchQueue.main.async {
            let menuBarOnly = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
            let hasVisibleUserWindows = !WindowDiagnostics.visibleUserFacingWindows().isEmpty

            guard menuBarOnly else { return }
            guard !hasVisibleUserWindows else { return }

            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.deactivate()
        }
    }
}

final class WindowManager: NSObject {
    static let shared = WindowManager()

    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("com.prakashjoshipax.voiceink.mainWindow")
    private static let mainWindowAutosaveName = NSWindow.FrameAutosaveName("VoiceInkMainWindowFrame")

    private var contentProvider: (() -> AnyView)?
    private var mainWindowController: NSWindowController?

    private override init() {
        super.init()
    }

    func configure(contentProvider: @escaping () -> AnyView) {
        self.contentProvider = contentProvider
    }

    @discardableResult
    func showMainWindow() -> NSWindow? {
        let controller = mainWindowController ?? makeMainWindowController()
        guard let window = controller?.window else { return nil }

        AppPresentationPolicy.activateForUserFacingWindow()
        controller?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return window
    }

    func hideMainWindow() {
        mainWindowController?.close()
    }

    func currentMainWindow() -> NSWindow? {
        mainWindowController?.window
    }

    private func makeMainWindowController() -> NSWindowController? {
        guard let contentProvider else { return nil }

        let hostingController = NSHostingController(rootView: contentProvider())
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AppWindowLayout.width,
                height: AppWindowLayout.minimumHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.mainWindowIdentifier
        window.delegate = self
        window.title = "VoiceInk"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = true
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal
        window.minSize = NSSize(width: AppWindowLayout.width, height: AppWindowLayout.minimumHeight)
        window.maxSize = NSSize(width: AppWindowLayout.width, height: CGFloat.greatestFiniteMagnitude)
        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        window.contentViewController = hostingController

        if !window.setFrameUsingName(Self.mainWindowAutosaveName) {
            window.center()
        }

        let controller = NSWindowController(window: window)
        mainWindowController = controller
        return controller
    }
}

extension WindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            mainWindowController?.window === window
        else {
            return
        }

        mainWindowController = nil
    }
}
