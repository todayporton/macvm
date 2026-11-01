// macvm-helper: GUI primitives that run INSIDE the guest VM.
//
// It is copied into the VM by `macvm setup` and must never be run on the host:
// the first thing main() does is refuse to run outside a virtual machine, so a
// misdirected invocation cannot move the host's cursor.
//
// Output: JSON (one object per line for lists). Exit codes: 0 ok, 2 usage,
// 3 not found, 4 missing TCC permission, 5 refused (not in a VM), 6 element disabled,
// 7 element covered or unreachable, 8 selector ambiguous.

import AppKit
import ApplicationServices

// MARK: - Basics

func die(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("macvm-helper: \(message)\n".utf8))
    exit(code)
}

func emit(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { die("JSON encoding failed", code: 1) }
    print(text)
}

func isVirtualMachine() -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}

/// Splits `--name value` options from positional arguments.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String], valueOptions: Set<String> = [], flagOptions: Set<String> = []) {
        var index = 0
        var onlyPositional = false
        while index < raw.count {
            let item = raw[index]
            if onlyPositional {
                positional.append(item)
            } else if item == "--" {
                onlyPositional = true
            } else if item.hasPrefix("--"), valueOptions.contains(String(item.dropFirst(2))) {
                guard index + 1 < raw.count else { die("\(item) needs a value") }
                options[String(item.dropFirst(2))] = raw[index + 1]
                index += 1
            } else if item.hasPrefix("--"), flagOptions.contains(String(item.dropFirst(2))) {
                flags.insert(String(item.dropFirst(2)))
            } else if item.hasPrefix("--") {
                die("unknown option \(item)")
            } else {
                positional.append(item)
            }
            index += 1
        }
    }

    func int(_ name: String, default fallback: Int) -> Int {
        guard let raw = options[name] else { return fallback }
        guard let value = Int(raw) else { die("--\(name) must be an integer") }
        return value
    }
}

func number(_ raw: String, _ label: String) -> Double {
    guard let value = Double(raw) else { die("\(label) must be a number, got '\(raw)'") }
    return value
}

func requireAccessibility() {
    if !AXIsProcessTrusted() {
        die("Accessibility permission is missing for this process in the VM", code: 4)
    }
}

let eventSource = CGEventSource(stateID: .hidSystemState)

func pause(_ milliseconds: Int) {
    usleep(UInt32(max(0, milliseconds)) * 1000)
}

// MARK: - Entry point

func main() {
    guard isVirtualMachine() else {
        die("refusing to run: this is not a virtual machine (host GUI must not be automated)", code: 5)
    }
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first else { die("usage: macvm-helper <command> [args]") }
    let rest = Array(argv.dropFirst())
    // Lazy: `ax` and `type` must not have their arguments parsed as mouse options.
    var positionalMouse: Arguments { Arguments(rest, valueOptions: ["count", "button", "duration", "at"], flagOptions: []) }

    switch command {
    case "permissions":
        emit(["accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess()])
    case "screen":
        for screen in NSScreen.screens {
            emit(["x": screen.frame.minX, "y": screen.frame.minY,
                  "width": screen.frame.width, "height": screen.frame.height,
                  "scale": screen.backingScaleFactor])
        }
    case "set-display":
        guard rest.count == 2, let width = Int(rest[0]), let height = Int(rest[1]) else { die("set-display needs WIDTH HEIGHT") }
        setDisplay(width: width, height: height)
    case "frontmost":
        emit(describe(NSWorkspace.shared.frontmostApplication))
    case "apps":
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            emit(describe(app))
        }
    case "app-status":
        guard let bundleId = rest.first else { die("app-status needs a bundle id") }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        var out = describe(app)
        out["bundleId"] = bundleId
        out["running"] = app != nil
        if let app, AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 3)
            out["windows"] = children(of: element, attribute: kAXWindowsAttribute).map { stringAttribute($0, kAXTitleAttribute) ?? "" }
        }
        emit(out)
    case "windows":
        listWindows(bundleId: rest.first)
    case "activate":
        guard let bundleId = rest.first else { die("activate needs a bundle id") }
        activate(bundleId: bundleId, title: rest.count > 1 ? rest[1] : nil)
    case "click":
        let args = positionalMouse
        guard args.positional.count == 2 else { die("click needs X Y") }
        let button = args.options["button"] ?? "left"
        guard button == "left" || button == "right" else { die("--button must be left or right") }
        click(at: CGPoint(x: number(args.positional[0], "X"), y: number(args.positional[1], "Y")),
              right: button == "right", count: args.int("count", default: 1))
    case "move":
        let args = positionalMouse
        guard args.positional.count == 2 else { die("move needs X Y") }
        postMouse(.mouseMoved, CGPoint(x: number(args.positional[0], "X"), y: number(args.positional[1], "Y")), button: .left)
    case "drag":
        let args = positionalMouse
        guard args.positional.count == 4 else { die("drag needs X1 Y1 X2 Y2") }
        let p = args.positional.map { number($0, "coordinate") }
        drag(from: CGPoint(x: p[0], y: p[1]), to: CGPoint(x: p[2], y: p[3]), durationMs: args.int("duration", default: 400))
    case "scroll":
        let args = positionalMouse
        guard (1...2).contains(args.positional.count) else { die("scroll needs DY [DX]") }
        var at: CGPoint?
        if let raw = args.options["at"] {
            let parts = raw.split(separator: ",").map { number(String($0), "--at") }
            guard parts.count == 2 else { die("--at needs X,Y") }
            at = CGPoint(x: parts[0], y: parts[1])
        }
        let dy = Int32(number(args.positional[0], "DY"))
        let dx = args.positional.count > 1 ? Int32(number(args.positional[1], "DX")) : 0
        scroll(lines: dy, horizontal: dx, at: at)
    case "key":
        guard !rest.isEmpty else { die("key needs a combo such as cmd+a") }
        rest.forEach(pressKey(combo:))
    case "type":
        guard rest.count == 1 else { die("type needs exactly one text argument") }
        typeText(rest[0])
    case "ui":
        uiCommand(rest)
    default:
        die("unknown command \(command)")
    }
}

main()
