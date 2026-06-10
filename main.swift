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
        cell.configure(with: windows[row])
        return cell
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
            title: "Quit MiniSwitcher",
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
        // Ad-hoc signing ties the TCC entry to the binary hash, so each rebuild revokes
        // the permission. Prompt only on the very first launch; after that the user can
        // re-grant via "Grant Accessibility Access…" in the menu bar.
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasPromptedAccessibility") else { return }
        defaults.set(true, forKey: "hasPromptedAccessibility")
        let key = "AXTrustedCheckOptionPrompt" as CFString
        AXIsProcessTrustedWithOptions([key: kCFBooleanTrue] as CFDictionary)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
