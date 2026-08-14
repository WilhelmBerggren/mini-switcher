import Cocoa
import Carbon

// Private SkyLight symbols — always resident because NSApplication loads the framework.

// Disables/enables symbolic hotkeys (⌘Tab = 1, ⌘Shift+Tab = 2) system-wide.
// IMPORTANT: the effect persists after the process exits, so we must restore on quit/signal.
@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int, _ isEnabled: Bool) -> Int32

// Window-server connection and property reader — no Screen Recording or AX permission needed.
typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyWindowProperty") @discardableResult
func CGSCopyWindowProperty(_ cid: CGSConnectionID, _ wid: CGWindowID,
                            _ property: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>) -> CGError

// Space enumeration. CGWindowListCopyWindowInfo cannot tell a real window sitting on another
// Space apart from an app's never-shown placeholder window — both are simply "not on screen".
// The window server knows: only real windows are placed in a Space.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID, _ owner: UInt32, _ spaces: CFArray,
                                       _ options: UInt32, _ setTags: UnsafeMutablePointer<UInt64>,
                                       _ clearTags: UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?

// Maps an AXUIElement to its CGWindowID. The "AXWindowID" attribute does NOT exist
// in the public AX API — this private symbol is the only reliable way to correlate
// an AX window with a window from CGWindowListCopyWindowInfo.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

func setSystemCmdTab(enabled: Bool) {
    CGSSetSymbolicHotKeyEnabled(1, enabled) // ⌘Tab
    CGSSetSymbolicHotKeyEnabled(2, enabled) // ⌘Shift+Tab
}

// MARK: - Model

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let isMinimized: Bool
    // Single-window apps often title their window after themselves ("Claude — Claude"), and
    // the app name is all we have for a window on another Space, so both collapse to one name.
    var label: String {
        title.isEmpty || title.caseInsensitiveCompare(appName) == .orderedSame
            ? appName
            : "\(title) — \(appName)"
    }
}

// MARK: - Jump Keys

// The type-ahead letter for one row, and where to underline it in the row's label.
struct JumpKey {
    let key: Character  // lowercased — what the user types
    let offset: Int     // character offset into `label`
}

// Assigns each row a letter, unique across the list, in two passes: every app picks once
// before any app picks twice. Otherwise a run of windows from one app eats the initials of
// apps further down — three Zed windows would take "z", "e", "d" and leave DBeaver on "b".
//
// Claims are made in alphabetical order, never list order. The list is sorted by recency, so
// letting it drive the claims would hand "s" to whichever of Slack and Signal you used last;
// going alphabetically means a letter keeps belonging to the same window between switches.
func assignJumpKeys(_ windows: [WindowInfo]) -> [JumpKey?] {
    var taken = Set<Character>()
    var keys = [JumpKey?](repeating: nil, count: windows.count)
    let alphabetical = windows.indices.sorted {
        (windows[$0].appName.lowercased(), windows[$0].label.lowercased(), $0)
            < (windows[$1].appName.lowercased(), windows[$1].label.lowercased(), $1)
    }

    var appsWithAPick = Set<String>()
    for row in alphabetical where appsWithAPick.insert(windows[row].appName).inserted {
        keys[row] = jumpKey(for: windows[row], taken: &taken)
    }
    for row in alphabetical where keys[row] == nil {
        keys[row] = jumpKey(for: windows[row], taken: &taken)
    }
    return keys
}

// The best letter still going for one row. Preference goes to the app name: you reach for
// "s" thinking of Slack, not of the channel name its title happens to start with.
private func jumpKey(for window: WindowInfo, taken: inout Set<Character>) -> JumpKey? {
    let chars = Array(window.label)
    // A label is either the app name alone or "title — appName", so the app name is always
    // the tail; searching it first needs no string matching.
    let appStart = max(0, chars.count - window.appName.count)
    for i in Array(appStart..<chars.count) + Array(0..<appStart) {
        guard let c = chars[i].lowercased().first, c.isLetter || c.isNumber,
              taken.insert(c).inserted else { continue }
        return JumpKey(key: c, offset: i)
    }
    return nil // every letter in this row is already claimed
}

// MARK: - Window Discovery

func fetchWindows() -> [WindowInfo] {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let conn = CGSMainConnectionID()
    var seenIDs = Set<CGWindowID>()
    // AXUIElementCreateApplication + kAXWindowsAttribute is expensive; cache per pid
    // so apps with many windows aren't queried repeatedly.
    var axWindowCache: [pid_t: [AXUIElement]] = [:]
    // Windows of the active Space carry live z-order; everything else has to be ranked from
    // the remembered order, so the two are collected separately and merged at the end.
    var current: [WindowInfo] = []
    var others: [WindowInfo] = []

    // 1. On-screen windows of the active Space, in front-to-back z-order. This is the only
    //    list that carries z-order, which is what makes ⌘Tab land on the previous window.
    if let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[CFString: Any]] {
        for d in list {
            guard let w = switchableWindow(d, myPID: myPID), seenIDs.insert(w.id).inserted
            else { continue }
            let title = windowTitle(pid: w.pid, winID: w.id, conn: conn, cache: &axWindowCache)
            current.append(WindowInfo(id: w.id, pid: w.pid, appName: w.app,
                                      title: title, isMinimized: false))
        }
    }

    // 2. Minimized windows, found via the AX API (which still sees them), appended after.
    if AXIsProcessTrusted() {
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != myPID {
            let pid = app.processIdentifier
            for axWin in axWindows(pid: pid, cache: &axWindowCache) {
                var minRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minRef) == .success,
                      (minRef as? Bool) == true else { continue }
                var winID = CGWindowID(0)
                guard _AXUIElementGetWindow(axWin, &winID) == .success, seenIDs.insert(winID).inserted else { continue }

                let title = windowTitle(pid: pid, winID: winID, conn: conn, cache: &axWindowCache)
                others.append(WindowInfo(id: winID, pid: pid, appName: app.localizedName ?? "",
                                         title: title, isMinimized: true))
            }
        }
    }

    // 3. Windows on other Spaces — another desktop, or an app that went full-screen (which
    //    gives it a Space of its own). Neither earlier pass can see them: .optionOnScreenOnly
    //    covers the active Space only, and kAXWindowsAttribute returns nothing for an app
    //    whose windows are all elsewhere. So take the unfiltered window list and keep the
    //    entries the window server has actually placed in a Space, which is what separates
    //    a real window on another desktop from an app's never-shown placeholder window.
    let spaceWindows = windowsInAllSpaces(conn: conn)
    if !spaceWindows.isEmpty,
       let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
        as? [[CFString: Any]] {
        // Helper processes ("Firefox GPU Help", "AutoFill") own layer-0 windows too; only
        // ordinary foreground apps can own a window worth switching to.
        let regularPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { $0.processIdentifier })
        for d in list {
            guard let w = switchableWindow(d, myPID: myPID),
                  spaceWindows.contains(w.id), regularPIDs.contains(w.pid),
                  seenIDs.insert(w.id).inserted
            else { continue }
            let title = windowTitle(pid: w.pid, winID: w.id, conn: conn, cache: &axWindowCache)
            others.append(WindowInfo(id: w.id, pid: w.pid, appName: w.app,
                                     title: title, isMinimized: false))
        }
    }

    // Window IDs are not reused, so anything not listed this time is gone for good.
    titleCache = titleCache.filter { seenIDs.contains($0.key) }
    knownAXWindows = knownAXWindows.filter { seenIDs.contains($0.key) }
    return orderByRecentUse(current: current, others: others)
}

// The order the switcher last presented, most-recently-used first.
private var mruOrder: [CGWindowID] = []

// Ranks every window by how recently it was used. The window server only exposes z-order for
// the active Space, so a window on another desktop carries no hint of its own — without a
// memory it can only be appended last, however recently you were in it.
//
// Windows of the active Space fill their remembered slots in live z-order, so raising one by
// any means (clicking it, another switcher) still ranks it correctly; windows elsewhere keep
// the position they had. With everything on one Space this reduces to plain z-order.
private func orderByRecentUse(current: [WindowInfo], others: [WindowInfo]) -> [WindowInfo] {
    let currentIDs = Set(current.map(\.id))
    var pending = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0) })
    var zOrder = current[...]
    var result: [WindowInfo] = []

    for id in mruOrder {
        if currentIDs.contains(id) {
            if let next = zOrder.popFirst() { result.append(next) }
        } else if let window = pending.removeValue(forKey: id) {
            result.append(window)
        }
        // Anything else has been closed since we last looked.
    }
    result += zOrder                                        // opened since the last look
    result += others.filter { pending[$0.id] != nil }       // ditto, and not on this Space

    // Whatever is frontmost in the active Space is what the user is looking at right now, so
    // it heads the list — this is what puts the Space you just came from second, not last.
    if let front = current.first, let i = result.firstIndex(where: { $0.id == front.id }), i > 0 {
        result.insert(result.remove(at: i), at: 0)
    }

    mruOrder = result.map(\.id)
    return result
}

// Shared filter for a CGWindowListCopyWindowInfo entry: a normal (non-panel, non-menu) window
// that is actually drawn. The alpha test matters for full-screen apps — Firefox leaves a
// transparent full-width strip on screen that would otherwise list as a titleless entry.
private func switchableWindow(_ d: [CFString: Any], myPID: pid_t)
    -> (id: CGWindowID, pid: pid_t, app: String)? {
    guard let layer = d[kCGWindowLayer]     as? Int, layer == 0,
          let pidInt = d[kCGWindowOwnerPID] as? Int,
          let id    = d[kCGWindowNumber]    as? CGWindowID,
          let app   = d[kCGWindowOwnerName] as? String,
          (d[kCGWindowAlpha] as? Double ?? 1) > 0,
          pid_t(pidInt) != myPID
    else { return nil }
    return (id, pid_t(pidInt), app)
}

// Every window the window server has placed in a Space, on all displays and all Spaces.
private func windowsInAllSpaces(conn: CGSConnectionID) -> Set<CGWindowID> {
    guard let displays = CGSCopyManagedDisplaySpaces(conn)?.takeRetainedValue() as? [NSDictionary]
    else { return [] }
    let spaceIDs = displays.flatMap { display in
        (display["Spaces"] as? [NSDictionary] ?? []).compactMap { $0["id64"] as? UInt64 }
    }
    guard !spaceIDs.isEmpty else { return [] }
    var setTags: UInt64 = 0, clearTags: UInt64 = 0
    guard let ids = CGSCopyWindowsWithOptionsAndTags(
        conn, 0, spaceIDs as CFArray, 0, &setTags, &clearTags
    )?.takeRetainedValue() as? [CGWindowID] else { return [] }
    return Set(ids)
}

// Per-app AX window list, cached (the lookup is expensive and reused across passes).
private func axWindows(pid: pid_t, cache: inout [pid_t: [AXUIElement]]) -> [AXUIElement] {
    if let cached = cache[pid] { return cached }
    var winsRef: CFTypeRef?
    let axApp = AXUIElementCreateApplication(pid)
    let wins = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success
        ? (winsRef as? [AXUIElement] ?? [])
        : []
    cache[pid] = wins
    return wins
}

// Remembered AX handles, one per window. kAXWindowsAttribute only ever lists the active
// Space, but a handle obtained from it keeps working once its window moves out of view —
// which is the only way to act on a specific window on another Space. Without it, all we
// could do is activate the app, and the app decides which of its windows that means.
private var knownAXWindows: [CGWindowID: AXUIElement] = [:]

// A window on another Space has no readable title at all: AX reports only the active Space,
// and the window server's title property comes back empty on recent macOS. Titles seen while
// a window was reachable are kept here so it still reads as more than a bare app name later.
private var titleCache: [CGWindowID: String] = [:]

// The AX handle for one window: found live if its Space is active, else the remembered one.
private func axWindow(pid: pid_t, winID: CGWindowID,
                      cache: inout [pid_t: [AXUIElement]]) -> AXUIElement? {
    if AXIsProcessTrusted() {
        for axWin in axWindows(pid: pid, cache: &cache) {
            var id = CGWindowID(0)
            guard _AXUIElementGetWindow(axWin, &id) == .success, id == winID else { continue }
            knownAXWindows[winID] = axWin
            return axWin
        }
    }
    return knownAXWindows[winID]
}

// Best-effort title: AX first (most reliable), CGS window-server property, then last-known.
private func windowTitle(pid: pid_t, winID: CGWindowID, conn: CGSConnectionID,
                         cache: inout [pid_t: [AXUIElement]]) -> String {
    // AX title (requires Accessibility permission).
    if let axWin = axWindow(pid: pid, winID: winID, cache: &cache) {
        var tRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &tRef) == .success,
           let t = tRef as? String, !t.isEmpty {
            titleCache[winID] = t
            return t
        }
    }

    // CGS fallback: reads from the window server, no permission needed
    // (often empty for other apps' windows on recent macOS).
    var cgsRef: CFTypeRef?
    CGSCopyWindowProperty(conn, winID, "kCGSWindowTitle" as CFString, &cgsRef)
    if let t = cgsRef as? String, !t.isEmpty {
        titleCache[winID] = t
        return t
    }

    return titleCache[winID] ?? ""
}

// MARK: - Window Activation

func raiseWindow(_ w: WindowInfo) {
    // Raise before activating: activation follows the app's main window, so making the chosen
    // window main first is what stops an app with several windows from landing on the wrong
    // one. For a window on another Space this only works via the remembered AX handle — the
    // live lookup returns nothing there, which is exactly when picking the wrong window shows.
    var cache: [pid_t: [AXUIElement]] = [:]
    if let axWin = axWindow(pid: w.pid, winID: w.id, cache: &cache) {
        AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
    }
    if let runningApp = NSRunningApplication(processIdentifier: w.pid) {
        if #available(macOS 14.0, *) {
            runningApp.activate()
        } else {
            runningApp.activate(options: .activateIgnoringOtherApps)
        }
    }
}

// MARK: - Cell View

final class WindowCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("WindowCell")
    private let iconView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 14)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tf)
        textField = tf

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            tf.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(with window: WindowInfo, jump: JumpKey?) {
        let label = window.label
        if let jump, jump.offset < label.count {
            // No colour is set, so the text still inverts with the selection like a plain
            // string would; only the font has to be restated for the attributed path.
            let text = NSMutableAttributedString(
                string: label, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let start = label.index(label.startIndex, offsetBy: jump.offset)
            text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                              range: NSRange(start..<label.index(after: start), in: label))
            textField?.attributedStringValue = text
        } else {
            textField?.stringValue = label
        }
        iconView.image = NSRunningApplication(processIdentifier: window.pid)?.icon
        // Dim minimized windows so they read as inactive (selecting one un-minimizes it).
        iconView.alphaValue = window.isMinimized ? 0.4 : 1.0
    }
}

// MARK: - Row View

// The .plain table style draws a full-width rectangular selection. This restores the
// rounded, inset highlight the default (inset) style gave — without its phantom row padding.
final class WindowRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("WindowRow")

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 4, dy: 2)
        let color = isEmphasized ? NSColor.selectedContentBackgroundColor
                                 : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - Hover-Tracking Table

// Reports the row under the cursor as the mouse moves (so hover-then-commit acts on the
// window you're pointing at), and reports when the cursor leaves the list. The panel
// decides what to do — hover is a preview that reverts on exit.
final class HoverTableView: NSTableView {
    var onHover: ((Int) -> Void)?   // row under the cursor (always ≥ 0)
    var onHoverExit: (() -> Void)?  // cursor left the list area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHover?(row) }
    }

    override func mouseExited(with event: NSEvent) {
        onHoverExit?()
    }
}

// MARK: - Switcher Panel

final class SwitcherPanel: NSPanel {
    private static let padding: CGFloat = 6      // equal gap above first / below last row
    private static let maxVisibleRows = 14       // cap height; rows beyond this scroll

    private let table = HoverTableView()
    private var windows: [WindowInfo] = []
    private var jumpKeys: [JumpKey?] = []       // parallel to `windows`
    private var jumpRows: [Character: Int] = [:] // typed letter → row
    // The keyboard/⌘-driven selection. Hover changes the visible selection as a preview
    // only; if the cursor leaves the list without committing, we revert to this row.
    private var baseSelectedRow = 0

    convenience init() {
        self.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .transient]
        hidesOnDeactivate = false
        setupUI()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in self?.orderOut(nil) }
    }

    private func setupUI() {
        let fx = NSVisualEffectView()
        fx.material = .menu
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true

        let col = NSTableColumn(identifier: .init("col"))
        col.isEditable = false
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        // .automatic resolves to an inset style on macOS 11+, which pads the document
        // view taller than its rows and leaves a scrollable overflow that clips a row.
        table.style = .plain
        table.rowHeight = 36
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        // Single click commits immediately, so there is no double-click path to handle.
        table.action = #selector(handleClick)
        table.onHover = { [weak self] row in self?.hoverSelect(row) }
        table.onHoverExit = { [weak self] in self?.revertHoverSelection() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        // Otherwise AppKit adds a phantom top inset that shifts rows down and clips the last one.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(scroll)
        let pad = SwitcherPanel.padding
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: fx.topAnchor, constant: pad),
            scroll.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -pad),
            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -pad),
        ])
        contentView = fx
    }

    // selectIndex 1 = macOS convention: start on previously-used window
    func present(selectIndex: Int = 0) {
        windows = fetchWindows()
        guard !windows.isEmpty else { return }
        jumpKeys = assignJumpKeys(windows)
        jumpRows = [:]
        for (row, jump) in jumpKeys.enumerated() where jump != nil { jumpRows[jump!.key] = row }
        table.reloadData()

        // Size the window first, so the row scroll below is computed against the final clip height.
        let rowsVisible = min(windows.count, SwitcherPanel.maxVisibleRows)
        let height = CGFloat(rowsVisible) * table.rowHeight + SwitcherPanel.padding * 2
        setContentSize(NSSize(width: 560, height: height))
        centerOnCursorScreen()

        let row = min(selectIndex, windows.count - 1)
        baseSelectedRow = row
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        makeKeyAndOrderFront(nil)
    }

    // Appear where the user is looking: the screen holding the cursor. NSWindow.center()
    // would instead use NSScreen.main — the screen with the active window.
    private func centerOnCursorScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return center() }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.midY - frame.height / 2))
    }

    func selectNext()     { select(by: 1) }
    func selectPrevious() { select(by: -1) }

    private func select(by delta: Int) {
        guard !windows.isEmpty else { return }
        let row = (table.selectedRow + delta + windows.count) % windows.count
        baseSelectedRow = row
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // Hover previews a row without disturbing the row we revert to on exit.
    private func hoverSelect(_ row: Int) {
        guard row < windows.count, row != table.selectedRow else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    // Cursor left the list: undo the hover preview, back to the keyboard selection.
    private func revertHoverSelection() {
        guard baseSelectedRow >= 0, baseSelectedRow < windows.count,
              baseSelectedRow != table.selectedRow else { return }
        table.selectRowIndexes([baseSelectedRow], byExtendingSelection: false)
        table.scrollRowToVisible(baseSelectedRow)
    }

    @objc func commitAndClose() { commit(row: table.selectedRow) }

    // Single click commits the clicked row immediately — even while ⌘ is still held,
    // this beats the Cmd-release handler (the panel is gone by the time Cmd lifts).
    @objc func handleClick() { commit(row: table.clickedRow) }

    private func commit(row: Int) {
        orderOut(nil)
        guard row >= 0, row < windows.count else { return }
        raiseWindow(windows[row])
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:    orderOut(nil)
        case kVK_Return:    commitAndClose()
        case kVK_UpArrow:   selectPrevious()
        case kVK_DownArrow: selectNext()
        default:
            guard !jump(with: event) else { return }
            super.keyDown(with: event)
        }
    }

    // ⌘ is normally still held when a jump key is typed, and AppKit routes ⌘-modified keys
    // to performKeyEquivalent rather than keyDown — so the letters have to be caught here too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        isVisible && jump(with: event) ? true : super.performKeyEquivalent(with: event)
    }

    // Moves the selection only; ⌘ release (or Return) still commits, so a mistyped letter
    // costs nothing.
    private func jump(with event: NSEvent) -> Bool {
        guard let typed = event.charactersIgnoringModifiers?.lowercased().first,
              let row = jumpRows[typed] else { return false }
        baseSelectedRow = row
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        return true
    }
}

extension SwitcherPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { windows.count }
}

extension SwitcherPanel: NSTableViewDelegate {
    func tableView(_ t: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let cell = t.makeView(withIdentifier: WindowCell.id, owner: nil) as? WindowCell
            ?? WindowCell(frame: .zero)
        cell.identifier = WindowCell.id
        cell.configure(with: windows[row], jump: jumpKeys[row])
        return cell
    }

    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = t.makeView(withIdentifier: WindowRowView.id, owner: nil) as? WindowRowView
            ?? WindowRowView()
        view.identifier = WindowRowView.id
        return view
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Statics accessed by @convention(c) callbacks and the flags monitor closure
    static var shared: AppDelegate!
    static var cmdIsDown   = false
    static var shiftWasDown = false
    static var hotKeyRef: EventHotKeyRef?
    static var hotKeyHandlerRef: EventHandlerRef?

    private let panel = SwitcherPanel()
    private var statusItem: NSStatusItem!
    private var repeatTimer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        requestAccessibility()
        // Disable the system ⌘Tab switcher so our Carbon hotkey can take over.
        // Must be restored on exit — the effect persists across process restarts.
        setSystemCmdTab(enabled: false)
        setupHotKeys()
        setupFlagsMonitor()
        installSignalHandlers()
    }

    func applicationWillTerminate(_: Notification) {
        setSystemCmdTab(enabled: true)
    }

    // Called from the Carbon hotkey handler on the main thread (⌘Tab only).
    func handleHotKey() {
        AppDelegate.cmdIsDown = true
        if panel.isVisible {
            panel.selectNext()
        } else {
            panel.present(selectIndex: 1)
        }
        scheduleAutoRepeat()
    }

    // Neither trigger repeats on its own: a Carbon hotkey fires once per physical press, and
    // ⇧ only reports a flags-changed transition. So holding either would step a single row.
    // Drive the repeat ourselves instead — wait out the system's key-repeat delay, then tick
    // at its repeat interval for as long as the key is still held.
    private func scheduleAutoRepeat() {
        repeatTimer?.invalidate()
        schedule(after: NSEvent.keyRepeatDelay, repeats: false) { [weak self] in
            self?.schedule(after: NSEvent.keyRepeatInterval, repeats: true) { [weak self] in
                self?.autoRepeatTick()
            }
        }
    }

    private func autoRepeatTick() {
        // ⇧ via modifierFlags so either shift key counts; Tab via live key state (a held key
        // sends no events of its own). ⇧ wins when both are down — it's the backwards gesture.
        let shiftDown = NSEvent.modifierFlags.contains(.shift)
        let tabDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Tab))
        guard panel.isVisible, AppDelegate.cmdIsDown, shiftDown || tabDown else {
            repeatTimer?.invalidate()
            repeatTimer = nil
            return
        }
        if shiftDown { panel.selectPrevious() } else { panel.selectNext() }
    }

    private func schedule(after interval: TimeInterval, repeats: Bool, _ body: @escaping () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in body() }
        // .common so the repeat keeps ticking while the panel is tracking the mouse.
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func setupHotKeys() {
        // GetEventDispatcherTarget registers at the lowest Carbon level, which beats
        // the Dock's own ⌘Tab handler. GetApplicationEventTarget would lose that race.
        let target = GetEventDispatcherTarget()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(target, { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { AppDelegate.shared.handleHotKey() }
            return noErr
        }, 1, &spec, nil, &AppDelegate.hotKeyHandlerRef)

        let sig: OSType = 0x4D534E57
        let fwdID = EventHotKeyID(signature: sig, id: 1)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey),
                            fwdID, target, 0, &AppDelegate.hotKeyRef)
    }

    private func setupFlagsMonitor() {
        // Global monitor fires for events routed to OTHER apps (panel is not key).
        // Local monitor fires when OUR panel is the key window.
        // Both are needed because makeKeyAndOrderFront routes flagsChanged to us locally.
        let handle: (NSEvent) -> Void = { event in
            let flags     = event.modifierFlags
            let cmdNow    = flags.contains(.command)
            let shiftNow  = flags.contains(.shift)
            let panelUp   = AppDelegate.shared.panel.isVisible

            // Shift pressed while Cmd is held → navigate backwards, and keep going if it's held.
            if AppDelegate.cmdIsDown && cmdNow && shiftNow && !AppDelegate.shiftWasDown && panelUp {
                AppDelegate.shared.panel.selectPrevious()
                AppDelegate.shared.scheduleAutoRepeat()
            }

            let wasDown = AppDelegate.cmdIsDown
            AppDelegate.cmdIsDown   = cmdNow
            AppDelegate.shiftWasDown = shiftNow

            // Cmd released → commit selection
            if wasDown && !cmdNow && panelUp {
                AppDelegate.shared.panel.commitAndClose()
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event); return event
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.2.swap",
            accessibilityDescription: "Window Switcher"
        )
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Show Window Switcher", action: #selector(showPanel), keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Grant Accessibility Access…", action: #selector(openAccessibilityPrefs), keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Fonsterbyte",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu
    }

    @objc private func showPanel() { panel.present() }

    @objc private func openAccessibilityPrefs() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private func installSignalHandlers() {
        // Restore system ⌘Tab if the process is killed, so it doesn't stay disabled permanently.
        let handler: @convention(c) (Int32) -> Void = { _ in
            setSystemCmdTab(enabled: true)
            exit(0)
        }
        signal(SIGTERM, handler)
        signal(SIGINT,  handler)
    }

    private func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        let key = "AXTrustedCheckOptionPrompt" as CFString
        AXIsProcessTrustedWithOptions([key: kCFBooleanTrue] as CFDictionary)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
