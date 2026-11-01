// Synthetic mouse and keyboard events, posted to the guest's WindowServer.

import AppKit

// MARK: - Mouse

func postMouse(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton, clickCount: Int = 1) {
    guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
        die("could not create mouse event", code: 1)
    }
    event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    event.post(tap: .cghidEventTap)
}

func click(at point: CGPoint, right: Bool, count: Int) {
    let button: CGMouseButton = right ? .right : .left
    let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
    postMouse(.mouseMoved, point, button: button)
    pause(60)
    for index in 1...max(1, count) {
        postMouse(down, point, button: button, clickCount: index)
        pause(30)
        postMouse(up, point, button: button, clickCount: index)
        pause(50)
    }
}

func drag(from start: CGPoint, to end: CGPoint, durationMs: Int) {
    postMouse(.mouseMoved, start, button: .left)
    pause(100)
    postMouse(.leftMouseDown, start, button: .left)
    pause(150) // Long enough for AppKit to recognise a drag source.
    let steps = max(4, durationMs / 16)
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        postMouse(.leftMouseDragged, point, button: .left)
        pause(durationMs / steps)
    }
    pause(150)
    postMouse(.leftMouseUp, end, button: .left)
}

/// Positive `lines` scrolls the content down; `horizontal` positive scrolls right.
func scroll(lines: Int32, horizontal: Int32, at point: CGPoint?) {
    if let point {
        postMouse(.mouseMoved, point, button: .left)
        pause(60)
    }
    guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 2,
                              wheel1: -lines, wheel2: -horizontal, wheel3: 0) else {
        die("could not create scroll event", code: 1)
    }
    event.post(tap: .cghidEventTap)
}

// MARK: - Keyboard (key codes are for the ANSI layout; the VM uses U.S.)

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
    "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
    ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
    "f10": 109, "f11": 103, "f12": 111,
]

let modifierFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand,
    "shift": .maskShift,
    "alt": .maskAlternate, "opt": .maskAlternate, "option": .maskAlternate,
    "ctrl": .maskControl, "control": .maskControl,
    "fn": .maskSecondaryFn,
]

let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
    (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59), (.maskSecondaryFn, 63),
]

func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else {
        die("could not create key event", code: 1)
    }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    pause(25)
}

func pressKey(combo: String) {
    var flags: CGEventFlags = []
    var keyName: String?
    for token in combo.lowercased().split(separator: "+", omittingEmptySubsequences: true).map(String.init) {
        if let flag = modifierFlags[token] {
            flags.insert(flag)
        } else if keyName == nil {
            keyName = token
        } else {
            die("more than one non-modifier key in '\(combo)'")
        }
    }
    guard let keyName, let code = keyCodes[keyName] else { die("unknown key in '\(combo)'") }
    // Press and release modifiers as real keys, the way a keyboard does, so that the
    // system's modifier state is always balanced when the command ends.
    var held: CGEventFlags = []
    let used = modifierKeyCodes.filter { flags.contains($0.0) }
    for (flag, modifier) in used {
        held.insert(flag)
        postKey(modifier, down: true, flags: held)
    }
    postKey(code, down: true, flags: flags)
    postKey(code, down: false, flags: flags)
    for (flag, modifier) in used.reversed() {
        held.remove(flag)
        postKey(modifier, down: false, flags: held)
    }
}

/// Types text independently of the keyboard layout, including non-ASCII.
func typeText(_ text: String) {
    for character in text {
        if character == "\n" || character == "\r\n" { pressKey(combo: "return"); continue }
        if character == "\t" { pressKey(combo: "tab"); continue }
        let units = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
            die("could not create key event", code: 1)
        }
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        pause(8)
        up.post(tap: .cghidEventTap)
        pause(8)
    }
}

