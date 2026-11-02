// UI elements through the macOS Accessibility API: the structured view of an app.
//
// Reads use AX; clicks default to real mouse events at the element's centre, so a
// test exercises what a user would (hit testing, covered and disabled controls).
// See docs/DESIGN.md for the reasoning.

import AppKit
import ApplicationServices

// MARK: - Attributes

func children(of element: AXUIElement, attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == CFArrayGetTypeID(), let array = value as? [AnyObject] else { return [] }
    return array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
}

func element(_ owner: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(owner, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
    if let string = value as? String { return string.isEmpty ? nil : string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return (value as? NSNumber)?.boolValue
}

func frame(of element: AXUIElement) -> CGRect? {
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size,
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
}

func actions(of element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

/// A window's own buttons only carry help text such as "also has an action to zoom".
let windowButtonNames = ["AXCloseButton": "close window", "AXMinimizeButton": "minimize window",
                         "AXZoomButton": "zoom window", "AXFullScreenButton": "full screen"]

/// What a person would call it. Many controls keep their visible name somewhere
/// other than AXTitle: in a description, a placeholder, or a separate text element.
func label(of target: AXUIElement, role: String) -> String? {
    if let subrole = stringAttribute(target, kAXSubroleAttribute), let name = windowButtonNames[subrole] { return name }
    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
        if let text = stringAttribute(target, attribute) { return text }
    }
    if let linked = element(target, kAXTitleUIElementAttribute), let text = stringAttribute(linked, kAXValueAttribute) {
        return text
    }
    if ["AXRow", "AXCell", "AXLink", "AXButton"].contains(role), let text = firstStaticText(in: target, depth: 0) {
        return text
    }
    return stringAttribute(target, kAXHelpAttribute)
}

func firstStaticText(in target: AXUIElement, depth: Int) -> String? {
    guard depth < 4 else { return nil }
    for child in children(of: target) {
        if stringAttribute(child, kAXRoleAttribute) == "AXStaticText", let text = stringAttribute(child, kAXValueAttribute) { return text }
        if let text = firstStaticText(in: child, depth: depth + 1) { return text }
    }
    return nil
}

/// Comparison form: ignores case, accents and full/half width, so "ｓａｖｅ" finds "Save".
func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// "AXButton" -> "button"; subroles are kept where they are what people call it.
func shortRole(_ role: String, subrole: String?) -> String {
    if subrole == "AXSearchField" { return "searchfield" }
    if subrole == "AXSecureTextField" { return "securefield" }
    return (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
}

// MARK: - Walking

struct Node {
    let element: AXUIElement
    let path: String
    let depth: Int
    let role: String
    let shortRole: String
    let label: String?
    let value: String?
    let identifier: String?
    let frame: CGRect?

    init(_ element: AXUIElement, path: String, depth: Int) {
        self.element = element
        self.path = path
        self.depth = depth
        role = stringAttribute(element, kAXRoleAttribute) ?? "?"
        shortRole = macvm_helper_shortRole(role, element)
        label = macvm_helper_label(element, role)
        value = stringAttribute(element, kAXValueAttribute)
        identifier = stringAttribute(element, kAXIdentifierAttribute)
        frame = macvm_helper_frame(element)
    }

    var enabled: Bool { boolAttribute(element, kAXEnabledAttribute) ?? true }

    func json() -> [String: Any] {
        var out: [String: Any] = ["path": path, "role": shortRole]
        if let label { out["label"] = String(label.prefix(120)) }
        if let value { out["value"] = String(value.prefix(200)) }
        if let identifier { out["id"] = identifier }
        if let frame { out["frame"] = [Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)] }
        if !enabled { out["enabled"] = false }
        return out
    }
}

// Node's stored-property initialisers cannot call the free functions it shares names with.
private func macvm_helper_shortRole(_ role: String, _ e: AXUIElement) -> String { shortRole(role, subrole: stringAttribute(e, kAXSubroleAttribute)) }
private func macvm_helper_label(_ e: AXUIElement, _ role: String) -> String? { label(of: e, role: role) }
private func macvm_helper_frame(_ e: AXUIElement) -> CGRect? { frame(of: e) }

let controlRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
    "AXTextField", "AXTextArea", "AXComboBox", "AXLink", "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
    "AXTab", "AXRow", "AXCell", "AXColorWell", "AXDateField",
]
let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

func isControl(_ node: Node) -> Bool {
    if controlRoles.contains(node.role) { return true }
    return actions(of: node.element).contains(kAXPressAction as String)
}

/// The windows a user can currently reach: the focused one (sheets are its children)
/// plus dialogs and panels above it. Windows behind are left out because their
/// controls are covered, so listing them invites clicks on the wrong thing.
func reachableRoots(_ app: AXUIElement, allWindows: Bool) -> [(AXUIElement, String)] {
    let windows = children(of: app, attribute: kAXWindowsAttribute)
    var picked: [AXUIElement] = []
    if allWindows {
        picked = windows
    } else {
        if let focused = element(app, kAXFocusedWindowAttribute) ?? windows.first { picked.append(focused) }
        for window in windows where !picked.contains(where: { CFEqual($0, window) }) {
            let subrole = stringAttribute(window, kAXSubroleAttribute) ?? ""
            if ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"].contains(subrole) { picked.append(window) }
        }
    }
    return picked.map { window in
        let index = windows.firstIndex { CFEqual($0, window) } ?? 0
        return (window, "w\(index)")
    }
}

let screenBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }

/// Visits elements depth first. Stops at scrollbars, closed menus and anything
/// entirely off-screen. Returns false from `visit` to stop early.
final class Walker {
    let maxDepth: Int
    let budget: Int
    let includeOffscreen: Bool
    var visited = 0
    var truncated = false
    private var seen: [CFHashCode: [AXUIElement]] = [:]

    init(maxDepth: Int = 40, budget: Int = 6000, includeOffscreen: Bool = false) {
        self.maxDepth = maxDepth
        self.budget = budget
        self.includeOffscreen = includeOffscreen
    }

    @discardableResult
    func walk(_ target: AXUIElement, path: String, depth: Int, visit: (Node) -> Bool) -> Bool {
        if visited >= budget { truncated = true; return false }
        let hash = CFHash(target)
        if seen[hash, default: []].contains(where: { CFEqual($0, target) }) { return true }
        seen[hash, default: []].append(target)
        visited += 1

        let node = Node(target, path: path, depth: depth)
        if ["AXScrollBar", "AXValueIndicator"].contains(node.role) { return true }
        if !includeOffscreen, let rect = node.frame, !["AXMenuBar", "AXMenu"].contains(node.role), !rect.intersects(screenBounds) { return true }
        if !visit(node) { return false }
        if depth >= maxDepth { return true }
        // A closed menu's items have nothing on screen to click; `ui menu` reaches them.
        if node.role == "AXMenuBarItem", boolAttribute(target, kAXSelectedAttribute) != true { return true }
        for (index, child) in children(of: target).enumerated() {
            if !walk(child, path: "\(path).\(index)", depth: depth + 1, visit: visit) { return false }
        }
        return true
    }
}

// MARK: - Targets

/// The app named by --app, otherwise the frontmost app (so a system dialog that
/// has taken the front shows up in the listing rather than being invisible).
func targetApp(_ args: Arguments) -> NSRunningApplication {
    if let id = args.options["app"] { return runningApp(id) }
    guard let app = NSWorkspace.shared.frontmostApplication else { die("no app is frontmost", code: 3) }
    return app
}

func axApp(_ app: NSRunningApplication) -> AXUIElement {
    requireAccessibility()
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 3)
    // Chromium and Electron build their tree only when asked. Ignored by other apps.
    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    return root
}

struct Selector {
    var role: String?
    var label: String?
    var identifier: String?
    var value: String?
    var path: String?

    init(_ args: Arguments) {
        role = args.options["role"]
        label = args.options["label"]
        identifier = args.options["id"]
        value = args.options["value"]
        path = args.options["path"]
        if role == nil, label == nil, identifier == nil, value == nil, path == nil {
            die("give at least one of --label --id --role --value --path")
        }
    }

    func matches(_ node: Node) -> Bool {
        if let path, node.path != path { return false }
        if let identifier, node.identifier != identifier { return false }
        if let role {
            let wanted = fold(role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)
            if fold(node.shortRole) != wanted { return false }
        }
        if let value, !fold(node.value ?? "").contains(fold(value)) { return false }
        if let label, !fold(node.label ?? "").contains(fold(label)) { return false }
        return true
    }

    var description: String {
        [("label", label), ("id", identifier), ("role", role), ("value", value), ("path", path)]
            .compactMap { pair in pair.1.map { "--\(pair.0) \($0)" } }.joined(separator: " ")
    }
}

/// A row and the cell inside it often share a name and are one thing to a user.
/// Nodes arrive depth first, so a parent comes before its children.
func withoutNestedDuplicates(_ nodes: [Node]) -> [Node] {
    var kept: [Node] = []
    for node in nodes {
        let duplicate = kept.contains { parent in
            parent.label != nil && parent.label == node.label && node.path.hasPrefix(parent.path + ".")
        }
        if !duplicate { kept.append(node) }
    }
    return kept
}

/// Elements matching the selector within reach of the user, or in the whole app with --all.
func findNodes(_ args: Arguments, _ selector: Selector) -> [Node] {
    let root = axApp(targetApp(args))
    let all = args.flags.contains("all")
    var found: [Node] = []
    let walker = Walker(includeOffscreen: all)
    var starts = reachableRoots(root, allWindows: all)
    if let bar = element(root, kAXMenuBarAttribute) { starts.append((bar, "m")) }
    for (start, path) in starts {
        walker.walk(start, path: path, depth: 0) { node in
            if selector.matches(node) { found.append(node) }
            return true
        }
    }
    // An exact label beats a partial one: --label Save means "Save", not "Save As…".
    if let wanted = selector.label.map(fold) {
        let exact = found.filter { fold($0.label ?? "") == wanted }
        if !exact.isEmpty { found = exact }
    }
    return withoutNestedDuplicates(found)
}

/// One element, or a clear error. Ambiguity is an error so nothing gets clicked by luck.
func resolve(_ args: Arguments) -> Node {
    let selector = Selector(args)
    var nodes = findNodes(args, selector)
    if nodes.isEmpty {
        // WebKit and Electron build their tree on the first request.
        pause(400)
        nodes = findNodes(args, selector)
    }
    guard !nodes.isEmpty else {
        die("no element matches \(selector.description). Check `macvm ui elements`; if the app exposes no such element, use `macvm screenshot` and coordinates", code: 3)
    }
    if let raw = args.options["index"] {
        guard let index = Int(raw), nodes.indices.contains(index) else { die("--index \(raw) is out of range (\(nodes.count) matches)") }
        return nodes[index]
    }
    guard nodes.count == 1 else {
        let listing = nodes.prefix(8).map { "[\($0.path) \($0.shortRole) \($0.label ?? "")]" }.joined(separator: " ")
        die("\(nodes.count) elements match \(selector.description); narrow it or pass --index: \(listing)", code: 8)
    }
    return nodes[0]
}

func bringToFront(_ app: NSRunningApplication) {
    guard !app.isActive else { return }
    app.activate(options: [])
    for _ in 0..<20 where !app.isActive { pause(100) }
}

func isSameOrRelated(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
    func descends(_ inner: AXUIElement, from outer: AXUIElement) -> Bool {
        var current: AXUIElement? = inner
        var steps = 0
        while let item = current, steps < 40 {
            if CFEqual(item, outer) { return true }
            current = element(item, kAXParentAttribute)
            steps += 1
        }
        return false
    }
    return descends(a, from: b) || descends(b, from: a)
}

/// What is really on top at a point, if it is not the target. A window-level test
/// app could otherwise pass with a click that no user could have made.
func coveringElement(at point: CGPoint, target: AXUIElement) -> String? {
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, 3)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
    if isSameOrRelated(hit, target) { return nil }
    var pid: pid_t = 0
    AXUIElementGetPid(hit, &pid)
    let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    let node = Node(hit, path: "", depth: 0)
    return "\(owner) \(node.shortRole) \"\(node.label ?? "")\""
}

// MARK: - The screen capture prompt

/// macOS asks now and then whether the guest agent may capture the screen directly,
/// and the dialog takes the front. macvm's own captures raise it, so macvm answers it.
/// It matches this exact prompt and presses nothing else.
func allowCapturePrompt() {
    let id = "com.apple.UserNotificationCenter"
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
        emit(["prompt": false])
        return
    }
    let root = axApp(app)
    var text = ""
    var allow: AXUIElement?
    let walker = Walker(includeOffscreen: true)
    for window in children(of: root, attribute: kAXWindowsAttribute) {
        walker.walk(window, path: "", depth: 0) { node in
            if node.role == "AXStaticText", let value = node.value { text += value + " " }
            if node.role == "AXButton", node.label == "Allow" { allow = node.element }
            return true
        }
    }
    guard text.contains("tart-guest-agent"), text.contains("private window picker"), let allow else {
        emit(["prompt": false])
        return
    }
    let result = AXUIElementPerformAction(allow, kAXPressAction as CFString)
    guard result == .success else { die("could not answer the screen capture prompt (\(result.rawValue))", code: 1) }
    emit(["prompt": true, "allowed": true])
}

// MARK: - Commands

func report(_ node: Node, extra: [String: Any] = [:]) {
    let fresh = Node(node.element, path: node.path, depth: node.depth)
    var out = fresh.json()
    extra.forEach { out[$0.key] = $0.value }
    emit(out)
}

func uiElements(_ args: Arguments) {
    let app = targetApp(args)
    let root = axApp(app)
    let limit = args.int("limit", default: 150)
    let query = args.options["query"].map(fold)
    let includeAll = args.flags.contains("all")

    func collect() -> (rows: [Node], total: Int, walker: Walker) {
        var rows: [Node] = []
        var total = 0
        let walker = Walker(includeOffscreen: includeAll)
        var starts = reachableRoots(root, allWindows: includeAll)
        if let bar = element(root, kAXMenuBarAttribute) { starts.append((bar, "m")) }
        for (start, path) in starts {
            walker.walk(start, path: path, depth: 0) { node in
                guard isControl(node), node.role != "AXMenuBar" else { return true }
                // An unnamed control is noise unless it takes text.
                guard node.label != nil || node.identifier != nil || textRoles.contains(node.role) else { return true }
                if let query, ![node.label, node.value, node.identifier, node.shortRole].contains(where: { fold($0 ?? "").contains(query) }) {
                    return true
                }
                total += 1
                if rows.count < limit { rows.append(node) }
                return true
            }
        }
        return (rows, total, walker)
    }

    var result = collect()
    // WebKit and Electron build the tree on the first request, so an empty read gets a second chance.
    if result.rows.filter({ $0.role != "AXMenuBarItem" }).isEmpty {
        pause(400)
        result = collect()
    }
    let windowTitle = reachableRoots(root, allWindows: false).first.flatMap { stringAttribute($0.0, kAXTitleAttribute) }
    emit(["app": app.localizedName ?? "", "bundleId": app.bundleIdentifier ?? "", "window": windowTitle ?? "",
          "count": result.total, "truncated": result.total > result.rows.count || result.walker.truncated])
    withoutNestedDuplicates(result.rows).forEach { emit($0.json()) }
    if query == nil, result.rows.filter({ $0.role != "AXMenuBarItem" }).isEmpty {
        FileHandle.standardError.write(Data("macvm-helper: this window exposes no accessible controls; use `macvm screenshot` and coordinates\n".utf8))
    }
}

func uiTree(_ args: Arguments) {
    let root = axApp(targetApp(args))
    let walker = Walker(maxDepth: args.int("depth", default: 8), includeOffscreen: true)
    var starts = reachableRoots(root, allWindows: args.flags.contains("all"))
    if args.flags.contains("menu"), let bar = element(root, kAXMenuBarAttribute) { starts.append((bar, "m")) }
    for (start, path) in starts {
        walker.walk(start, path: path, depth: 0) { node in
            var out = node.json()
            out["depth"] = node.depth
            emit(out)
            return true
        }
    }
    if walker.truncated { emit(["truncated": true]) }
}

/// The window's text in reading order, including what is scrolled out of view.
func uiText(_ args: Arguments) {
    let root = axApp(targetApp(args))
    func read() -> [String] {
        var lines: [String] = []
        let walker = Walker(budget: 12000, includeOffscreen: true)
        for (start, path) in reachableRoots(root, allWindows: false) {
            walker.walk(start, path: path, depth: 0) { node in
                switch node.role {
                case "AXStaticText", "AXHeading":
                    if let text = node.value ?? node.label, lines.last != text { lines.append(text) }
                case "AXTextField", "AXTextArea", "AXComboBox":
                    if let text = node.value, lines.last != text { lines.append(node.label.map { "\($0): \(text)" } ?? text) }
                default: break
                }
                return true
            }
        }
        return lines
    }
    var lines = read()
    if lines.isEmpty {
        pause(400)
        lines = read()
    }
    let limit = args.int("limit", default: 12000)
    var used = 0
    for line in lines {
        used += line.count
        if used > limit { print("[truncated at \(limit) characters]"); break }
        print(line)
    }
}

func uiClick(_ args: Arguments) {
    let app = targetApp(args)
    let node = resolve(args)
    let force = args.flags.contains("force")
    guard node.enabled || force else {
        die("the element is disabled: \(node.shortRole) \"\(node.label ?? "")\"", code: 6)
    }
    let right = args.flags.contains("right")
    let count = args.flags.contains("double") ? 2 : 1

    func press() {
        let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        guard result == .success else { die("AXPress failed (\(result.rawValue)); use `macvm screenshot` and coordinates", code: 1) }
        report(node, extra: ["method": "press"])
    }
    if args.flags.contains("press") { press(); return }

    func scrollIntoView() {
        AXUIElementPerformAction(node.element, "AXScrollToVisible" as CFString)
        pause(300)
    }
    if frame(of: node.element).map({ !$0.intersects(screenBounds) }) ?? false { scrollIntoView() }
    func centre() -> CGPoint? {
        guard let rect = frame(of: node.element), rect.width >= 1, rect.height >= 1 else { return nil }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        return screenBounds.contains(point) ? point : nil
    }
    guard var point = centre() else {
        // Not on screen, so no mouse could reach it.
        if actions(of: node.element).contains(kAXPressAction as String) && !right && count == 1 { press(); return }
        die("the element is not on screen and has no press action", code: 7)
    }
    bringToFront(app)
    if !force, coveringElement(at: point, target: node.element) != nil {
        // Inside a scroll view, an element scrolled away still reports a frame on screen.
        scrollIntoView()
        if let moved = centre() { point = moved }
        if let cover = coveringElement(at: point, target: node.element) {
            die("the element is covered at \(Int(point.x)),\(Int(point.y)) by \(cover). Deal with that first, or pass --force", code: 7)
        }
    }
    click(at: point, right: right, count: count)
    pause(100)
    report(node, extra: ["method": "mouse", "point": [Int(point.x), Int(point.y)]])
}

func focus(_ node: Node, app: NSRunningApplication) {
    bringToFront(app)
    AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    pause(80)
    if boolAttribute(node.element, kAXFocusedAttribute) != true, let rect = frame(of: node.element) {
        click(at: CGPoint(x: rect.midX, y: rect.midY), right: false, count: 1)
        pause(80)
    }
    if boolAttribute(node.element, kAXFocusedAttribute) != true {
        die("could not focus \(node.shortRole) \"\(node.label ?? "")\"", code: 1)
    }
}

/// Types real keystrokes by default, so the app's change handlers run as they would for a user.
func uiType(_ args: Arguments) {
    guard let text = args.positional.first, args.positional.count == 1 else { die("ui type needs SELECTOR and one TEXT argument") }
    let app = targetApp(args)
    let node = resolve(args)
    guard node.enabled else { die("the element is disabled: \(node.shortRole) \"\(node.label ?? "")\"", code: 6) }
    if args.flags.contains("set") {
        let result = AXUIElementSetAttributeValue(node.element, kAXValueAttribute as CFString, text as CFString)
        guard result == .success else { die("setting the value failed (\(result.rawValue)); try without --set", code: 1) }
    } else {
        focus(node, app: app)
        if args.flags.contains("replace") { pressKey(combo: "cmd+a") }
        typeText(text)
        pause(100)
    }
    report(node)
}

/// `ui menu File "Save As…"`: walks from the menu bar, opening each level with AXPress.
func uiMenu(_ args: Arguments) {
    guard !args.positional.isEmpty else { die("ui menu needs at least a menu name and an item") }
    let app = targetApp(args)
    let root = axApp(app)
    bringToFront(app)
    guard let bar = element(root, kAXMenuBarAttribute) else { die("the app has no menu bar", code: 3) }
    var level = children(of: bar)
    var last: Node?
    for (index, name) in args.positional.enumerated() {
        let wanted = fold(name)
        let items = level.map { Node($0, path: "m", depth: index) }
        guard let item = items.first(where: { fold($0.label ?? "") == wanted }) ?? items.first(where: { fold($0.label ?? "").contains(wanted) }) else {
            let names = items.compactMap(\.label).prefix(30).joined(separator: ", ")
            die("no menu item \"\(name)\". Available: \(names)", code: 3)
        }
        last = item
        if index == args.positional.count - 1 {
            guard item.enabled else { die("the menu item is disabled: \(name)", code: 6) }
            let result = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            guard result == .success else { die("pressing \"\(name)\" failed (\(result.rawValue))", code: 1) }
        } else {
            // A submenu's children are readable without opening it.
            guard let menu = children(of: item.element).first else { die("\"\(name)\" has no submenu", code: 3) }
            level = children(of: menu)
        }
    }
    if let last { emit(["menu": args.positional, "pressed": last.label ?? ""]) }
}

/// Polls until a selector matches (or stops matching with --gone).
func uiWait(_ args: Arguments) {
    let selector = Selector(args)
    let deadline = Date().addingTimeInterval(Double(args.int("timeout", default: 20)))
    let gone = args.flags.contains("gone")
    repeat {
        if let id = args.options["app"], findApp(id) == nil {
            if gone { emit(["gone": true]); return }
        } else {
            let nodes = findNodes(args, selector)
            if gone, nodes.isEmpty { emit(["gone": true]); return }
            if !gone, let node = nodes.first { emit(node.json()); return }
        }
        pause(250)
    } while Date() < deadline
    die("timed out waiting for \(gone ? "the absence of " : "")\(selector.description)", code: 3)
}

func uiCommand(_ raw: [String]) {
    guard let action = raw.first else { die("ui needs a subcommand: elements tree text find click type menu focus wait") }
    let args = Arguments(Array(raw.dropFirst()),
                         valueOptions: ["app", "role", "label", "id", "value", "path", "index", "depth", "limit", "query", "timeout"],
                         flagOptions: ["all", "menu", "press", "force", "right", "double", "set", "replace", "gone"])
    switch action {
    case "elements": uiElements(args)
    case "tree": uiTree(args)
    case "text": uiText(args)
    case "find":
        let nodes = findNodes(args, Selector(args))
        if nodes.isEmpty { die("no element matches \(Selector(args).description)", code: 3) }
        nodes.forEach { emit($0.json()) }
    case "click": uiClick(args)
    case "type": uiType(args)
    case "focus":
        let node = resolve(args)
        focus(node, app: targetApp(args))
        report(node)
    case "menu": uiMenu(args)
    case "wait": uiWait(args)
    default: die("unknown ui subcommand \(action)")
    }
}
