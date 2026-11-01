// Running apps, windows and the display.

import AppKit
import ApplicationServices

// MARK: - Apps and windows

func runningApp(_ bundleId: String) -> NSRunningApplication {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
        die("app not running: \(bundleId)", code: 3)
    }
    return app
}

func describe(_ app: NSRunningApplication?) -> [String: Any] {
    guard let app else { return [:] }
    return [
        "bundleId": app.bundleIdentifier ?? "",
        "name": app.localizedName ?? "",
        "pid": Int(app.processIdentifier),
        "active": app.isActive,
        "hidden": app.isHidden,
        "launched": app.isFinishedLaunching,
    ]
}

func listWindows(bundleId: String?) {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        die("could not read the window list", code: 1)
    }
    for window in list {
        guard (window[kCGWindowLayer as String] as? Int) == 0,
              let pid = window[kCGWindowOwnerPID as String] as? Int32 else { continue }
        let app = NSRunningApplication(processIdentifier: pid)
        if let bundleId, app?.bundleIdentifier != bundleId { continue }
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        emit([
            "windowId": window[kCGWindowNumber as String] as? Int ?? 0,
            "app": window[kCGWindowOwnerName as String] as? String ?? "",
            "bundleId": app?.bundleIdentifier ?? "",
            "pid": Int(pid),
            "title": window[kCGWindowName as String] as? String ?? "",
            "x": bounds["X"] ?? 0, "y": bounds["Y"] ?? 0,
            "width": bounds["Width"] ?? 0, "height": bounds["Height"] ?? 0,
        ])
    }
}

func activate(bundleId: String, title: String?) {
    requireAccessibility()
    let app = runningApp(bundleId)
    app.unhide()
    app.activate(options: [.activateAllWindows])
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 3)
    if let title {
        var raised = false
        for window in children(of: element, attribute: kAXWindowsAttribute) {
            if (stringAttribute(window, kAXTitleAttribute) ?? "").contains(title) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                raised = true
                break
            }
        }
        if !raised { die("no window with title containing '\(title)'", code: 3) }
    }
    // Activation is asynchronous; report what actually happened rather than assume.
    for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleId { pause(100) }
    let front = NSWorkspace.shared.frontmostApplication
    if front?.bundleIdentifier != bundleId {
        die("activation did not take effect; frontmost is \(front?.bundleIdentifier ?? "none")", code: 1)
    }
    emit(describe(front))
}

// MARK: - Display

/// Tart's display setting only offers modes; the guest keeps the mode saved in its image.
func setDisplay(width: Int, height: Int) {
    let display = CGMainDisplayID()
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
        die("could not list display modes", code: 1)
    }
    let matching = modes.filter { $0.width == width && $0.height == height }
    guard let mode = matching.max(by: { $0.pixelWidth < $1.pixelWidth }) else {
        let available = Set(modes.map { "\($0.width)x\($0.height)" }).sorted().joined(separator: " ")
        die("no \(width)x\(height) mode; available: \(available)", code: 3)
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success,
          CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success,
          CGCompleteDisplayConfiguration(config, .permanently) == .success else {
        die("could not switch the display mode", code: 1)
    }
    emit(["width": mode.width, "height": mode.height, "pixelWidth": mode.pixelWidth, "pixelHeight": mode.pixelHeight])
}

