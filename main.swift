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
    var label: String { title.isEmpty ? appName : "\(title) — \(appName)" }
}

// MARK: - Window Discovery

func fetchWindows() -> [WindowInfo] {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[CFString: Any]] else { return [] }

    let myPID = Int(ProcessInfo.processInfo.processIdentifier)
    let conn = CGSMainConnectionID()
    var seenIDs = Set<CGWindowID>()
    // AXUIElementCreateApplication + kAXWindowsAttribute is expensive; cache per pid
    // so apps with many windows aren't queried repeatedly.
    var axWindowCache: [pid_t: [AXUIElement]] = [:]

    return list.compactMap { d in
        guard
            let layer  = d[kCGWindowLayer]    as? Int,    layer == 0,
            let pidInt = d[kCGWindowOwnerPID] as? Int,    pidInt != myPID,
            let winID  = d[kCGWindowNumber]   as? CGWindowID,
            let app    = d[kCGWindowOwnerName] as? String,
            seenIDs.insert(winID).inserted
        else { return nil }

        let pid = pid_t(pidInt)
        let title = windowTitle(pid: pid, winID: winID, conn: conn, cache: &axWindowCache)
        return WindowInfo(id: winID, pid: pid, appName: app, title: title)
    }
}

// Best-effort title: AX first (most reliable), CGS window-server property as fallback.
private func windowTitle(pid: pid_t, winID: CGWindowID, conn: CGSConnectionID,
                         cache: inout [pid_t: [AXUIElement]]) -> String {
    // AX title (requires Accessibility permission).
    if AXIsProcessTrusted() {
        let wins: [AXUIElement]
        if let cached = cache[pid] {
            wins = cached
        } else {
            var winsRef: CFTypeRef?
            let axApp = AXUIElementCreateApplication(pid)
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
               let w = winsRef as? [AXUIElement] {
                wins = w
            } else {
                wins = []
            }
            cache[pid] = wins
        }
        for axWin in wins {
            var id = CGWindowID(0)
            guard _AXUIElementGetWindow(axWin, &id) == .success, id == winID else { continue }
            var tRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &tRef) == .success,
               let t = tRef as? String, !t.isEmpty {
                return t
            }
            break
        }
    }

    // CGS fallback: reads from the window server, no permission needed
    // (often empty for other apps' windows on recent macOS).
    var cgsRef: CFTypeRef?
    CGSCopyWindowProperty(conn, winID, "kCGSWindowTitle" as CFString, &cgsRef)
    return cgsRef as? String ?? ""
}

// MARK: - Window Activation

func raiseWindow(_ w: WindowInfo) {
    let axApp = AXUIElementCreateApplication(w.pid)
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
       let wins = ref as? [AXUIElement] {
        for axWin in wins {
            var id = CGWindowID(0)
            guard _AXUIElementGetWindow(axWin, &id) == .success, id == w.id else { continue }
            AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
            break
        }
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

    func configure(with window: WindowInfo) {
        textField?.stringValue = window.label
        iconView.image = NSRunningApplication(processIdentifier: window.pid)?.icon
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

// Selects the row under the cursor as the mouse moves, so hover-then-commit
// (click, Return, or ⌘ release) acts on the window you're pointing at.
final class HoverTableView: NSTableView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, row != selectedRow else { return }
        selectRowIndexes([row], byExtendingSelection: false)
    }
}

// MARK: - Switcher Panel

final class SwitcherPanel: NSPanel {
    private static let padding: CGFloat = 6      // equal gap above first / below last row
    private static let maxVisibleRows = 14       // cap height; rows beyond this scroll

    private let table = HoverTableView()
    private var windows: [WindowInfo] = []

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
        table.reloadData()

        // Size the window first, so the row scroll below is computed against the final clip height.
        let rowsVisible = min(windows.count, SwitcherPanel.maxVisibleRows)
        let height = CGFloat(rowsVisible) * table.rowHeight + SwitcherPanel.padding * 2
        setContentSize(NSSize(width: 560, height: height))
        center()

        let row = min(selectIndex, windows.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        makeKeyAndOrderFront(nil)
    }

    func selectNext()     { select(by: 1) }
    func selectPrevious() { select(by: -1) }

    private func select(by delta: Int) {
        guard !windows.isEmpty else { return }
        let row = (table.selectedRow + delta + windows.count) % windows.count
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
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
        default:            super.keyDown(with: event)
        }
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
        cell.configure(with: windows[row])
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

            // Shift pressed while Cmd is held → navigate backwards
            if AppDelegate.cmdIsDown && cmdNow && shiftNow && !AppDelegate.shiftWasDown && panelUp {
                AppDelegate.shared.panel.selectPrevious()
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
