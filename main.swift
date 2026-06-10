import Cocoa
import Carbon

// Private SkyLight symbol — always resident because NSApplication loads the framework.
// Disables/enables symbolic hotkeys (⌘Tab = 1, ⌘Shift+Tab = 2) system-wide.
// IMPORTANT: the effect persists after the process exits, so we must restore on quit/signal.
@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int, _ isEnabled: Bool) -> Int32

func setSystemCmdTab(enabled: Bool) {
    CGSSetSymbolicHotKeyEnabled(1, enabled) // ⌘Tab
    CGSSetSymbolicHotKeyEnabled(2, enabled) // ⌘Shift+Tab
}

// MARK: - Model

struct WindowInfo {
    let pid: pid_t
    let appName: String
    let title: String
    var label: String { title.isEmpty ? appName : "\(appName)  —  \(title)" }
}

// MARK: - Window Discovery

func fetchWindows() -> [WindowInfo] {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[CFString: Any]] else { return [] }

    let myPID = Int(ProcessInfo.processInfo.processIdentifier)
    var seenIDs = Set<CGWindowID>()

    // If accessibility is granted, pre-fetch AX windows per PID so we can read
    // window titles without needing Screen Recording permission.
    var axWindowsByPID: [pid_t: [AXUIElement]] = [:]
    var countByPID:     [pid_t: Int] = [:]
    if AXIsProcessTrusted() {
        let pids: Set<pid_t> = Set(list.compactMap { d in
            guard let layer = d[kCGWindowLayer] as? Int, layer == 0,
                  let pidInt = d[kCGWindowOwnerPID] as? Int, pidInt != myPID
            else { return nil }
            return pid_t(pidInt)
        })
        for pid in pids {
            let axApp = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
               let wins = ref as? [AXUIElement] { axWindowsByPID[pid] = wins }
        }
    }

    return list.compactMap { d in
        guard
            let layer  = d[kCGWindowLayer]    as? Int,        layer == 0,
            let pidInt = d[kCGWindowOwnerPID] as? Int,        pidInt != myPID,
            let winID  = d[kCGWindowNumber]   as? CGWindowID,
            let app    = d[kCGWindowOwnerName] as? String,
            seenIDs.insert(winID).inserted          // deduplicate by window ID
        else { return nil }

        let pid = pid_t(pidInt)
        let idx = countByPID[pid, default: 0]
        countByPID[pid] = idx + 1

        // Prefer AX title (no Screen Recording needed); fall back to CGWindowName.
        var title = d[kCGWindowName] as? String ?? ""
        if title.isEmpty, let wins = axWindowsByPID[pid], idx < wins.count {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(wins[idx], kAXTitleAttribute as CFString, &t)
            title = t as? String ?? ""
        }

        return WindowInfo(pid: pid, appName: app, title: title)
    }
}

// MARK: - Window Activation

func raiseWindow(_ w: WindowInfo) {
    let axApp = AXUIElementCreateApplication(w.pid)
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
       let wins = ref as? [AXUIElement] {
        for axWin in wins {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &t)
            if (t as? String ?? "") == w.title {
                AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
                break
            }
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 14)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tf)
        textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - Switcher Panel

final class SwitcherPanel: NSPanel {
    private let table = NSTableView()
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
        table.rowHeight = 36
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(commitAndClose)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: fx.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -6),
            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
        ])
        contentView = fx
    }

    // selectIndex 1 = macOS convention: start on previously-used window
    func present(selectIndex: Int = 0) {
        windows = fetchWindows()
        guard !windows.isEmpty else { return }
        table.reloadData()
        let row = min(selectIndex, windows.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        let rowsVisible = min(windows.count, 14)
        setContentSize(NSSize(width: 560, height: CGFloat(rowsVisible) * table.rowHeight + 12))
        center()
        makeKeyAndOrderFront(nil)
    }

    func selectNext() {
        let row = min(windows.count - 1, table.selectedRow + 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func selectPrevious() {
        let row = max(0, table.selectedRow - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc func commitAndClose() {
        let row = table.selectedRow
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
        cell.textField?.stringValue = windows[row].label
        return cell
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Statics accessed by @convention(c) callbacks
    static var shared: AppDelegate!
    static var cmdIsDown = false
    static var eventTap: CFMachPort?
    static var hotKeyRef: EventHotKeyRef?
    static var hotKeyRefBack: EventHotKeyRef?
    static var hotKeyHandlerRef: EventHandlerRef?

    private let panel = SwitcherPanel()
    private var statusItem: NSStatusItem!
    private var runLoopSource: CFRunLoopSource?

    // CGEvent tap callback: handles only flagsChanged (Cmd release → close panel)
    // and re-enables the tap if macOS disables it. @convention(c) compatible: no captures.
    private static let tapCallback: CGEventTapCallBack = { _, type, cgEvent, _ in
        switch type {
        case .flagsChanged:
            let cmdNow = cgEvent.flags.contains(.maskCommand)
            DispatchQueue.main.async {
                let wasDown = AppDelegate.cmdIsDown
                AppDelegate.cmdIsDown = cmdNow
                if wasDown && !cmdNow && AppDelegate.shared.panel.isVisible {
                    AppDelegate.shared.panel.commitAndClose()
                }
            }
            return Unmanaged.passUnretained(cgEvent)
        case .tapDisabledByUserInput, .tapDisabledByTimeout:
            if let tap = AppDelegate.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(cgEvent)
        default:
            return Unmanaged.passUnretained(cgEvent)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        requestAccessibility()
        // Disable the system ⌘Tab switcher so our Carbon hotkey can take over.
        // Must be restored on exit — the effect persists across process restarts.
        setSystemCmdTab(enabled: false)
        setupHotKeys()
        setupEventTap()
        installSignalHandlers()
    }

    func applicationWillTerminate(_: Notification) {
        setSystemCmdTab(enabled: true)
    }

    // Called from the Carbon hotkey handler on the main thread.
    // id 1 = ⌘Tab (forward), id 2 = ⌘Shift+Tab (backward).
    func handleHotKey(id: UInt32) {
        AppDelegate.cmdIsDown = true  // Cmd is held whenever this hotkey fires
        if panel.isVisible {
            id == 1 ? panel.selectNext() : panel.selectPrevious()
        } else {
            // Start at index 1 so the first press selects the previously used window,
            // matching macOS ⌘Tab convention. Backward starts at the end of the list.
            panel.present(selectIndex: id == 2 ? Int.max : 1)
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
            let hotKeyID = id.id
            DispatchQueue.main.async { AppDelegate.shared.handleHotKey(id: hotKeyID) }
            return noErr
        }, 1, &spec, nil, &AppDelegate.hotKeyHandlerRef)

        let sig: OSType = 0x4D534E57
        // ⌘Tab (forward, id 1)
        let fwdID = EventHotKeyID(signature: sig, id: 1)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey),
                            fwdID, target, 0, &AppDelegate.hotKeyRef)
        // ⌘Shift+Tab (backward, id 2)
        let bwdID = EventHotKeyID(signature: sig, id: 2)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey | shiftKey),
                            bwdID, target, 0, &AppDelegate.hotKeyRefBack)
    }

    private func setupEventTap() {
        // Tap only needs flagsChanged to detect when Cmd is released while panel is showing.
        // Requires Accessibility permission; if unavailable, panel must be closed manually.
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: AppDelegate.tapCallback,
            userInfo: nil
        ) else {
            print("CGEvent tap failed — grant Accessibility in System Settings, then restart")
            return
        }
        AppDelegate.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit MiniSwitcher",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu
    }

    @objc private func showPanel() { panel.present() }

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
