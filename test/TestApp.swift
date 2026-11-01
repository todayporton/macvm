// Self-test target for macvm: every GUI interaction is written to stdout as one
// line, so verify.sh can assert that an input really reached the app.

import AppKit

func log(_ message: String) {
    print("EVENT \(message)")
    fflush(stdout)
}

final class DropView: NSView {
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        log("mouseDown count=\(event.clickCount) x=\(Int(p.x)) y=\(Int(p.y))")
    }
    override func rightMouseDown(with event: NSEvent) { log("rightMouseDown") }
    override func mouseDragged(with event: NSEvent) { dragged = true }
    override func mouseUp(with event: NSEvent) {
        if dragged { log("dragEnded") }
        dragged = false
    }
    override func scrollWheel(with event: NSEvent) {
        log("scroll dy=\(Int(event.scrollingDeltaY))")
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.setFill()
        bounds.fill() // dirtyRect may extend past the view's bounds.
    }
    private var dragged = false
}

final class Delegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    let field = NSTextField(frame: NSRect(x: 20, y: 300, width: 400, height: 28))
    let status = NSTextField(labelWithString: "idle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 460, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "macvm test"

        field.placeholderString = "type here"
        field.delegate = self
        field.setAccessibilityIdentifier("input")

        let button = NSButton(title: "Press me", target: self, action: #selector(pressed))
        button.frame = NSRect(x: 20, y: 256, width: 120, height: 32)
        button.setAccessibilityIdentifier("press")

        status.frame = NSRect(x: 160, y: 262, width: 280, height: 20)
        status.setAccessibilityIdentifier("status")

        let area = DropView(frame: NSRect(x: 20, y: 20, width: 420, height: 180))

        let save = NSButton(title: "保存", target: self, action: #selector(saved))
        save.frame = NSRect(x: 20, y: 212, width: 90, height: 32)
        let off = NSButton(title: "Disabled", target: self, action: #selector(pressed))
        off.frame = NSRect(x: 120, y: 212, width: 100, height: 32)
        off.isEnabled = false
        let cover = NSButton(title: "Cover", target: self, action: #selector(showCover))
        cover.frame = NSRect(x: 230, y: 212, width: 90, height: 32)

        [field, button, status, area, save, off, cover].forEach(window.contentView!.addSubview)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("hello-stdout")
        FileHandle.standardError.write(Data("hello-stderr\n".utf8))
        log("launched")
    }

    @objc func pressed() {
        status.stringValue = "pressed"
        log("buttonPressed")
    }

    @objc func saved() { log("saved") }

    /// A panel exactly over the "Press me" button, to test covered-element detection.
    @objc func showCover() {
        let origin = window.convertPoint(toScreen: NSPoint(x: 10, y: 250))
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 150, height: 44)),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .systemRed
        panel.isReleasedWhenClosed = false
        panel.orderFront(nil)
        coverPanel = panel
        log("coverShown")
    }

    @objc func hideCover() {
        coverPanel?.close()
        coverPanel = nil
        log("coverHidden")
    }

    @objc func menuAction() { log("menuAction") }

    var coverPanel: NSPanel?

    func controlTextDidChange(_ notification: Notification) {
        log("text=\(field.stringValue)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { log("terminated") }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
let toolsItem = NSMenuItem()
mainMenu.addItem(toolsItem)
let toolsMenu = NSMenu(title: "Tools")
toolsMenu.addItem(withTitle: "Do Thing", action: #selector(Delegate.menuAction), keyEquivalent: "")
toolsMenu.addItem(withTitle: "Hide Cover", action: #selector(Delegate.hideCover), keyEquivalent: "")
toolsItem.submenu = toolsMenu
app.mainMenu = mainMenu

let delegate = Delegate()
app.delegate = delegate
app.run()
