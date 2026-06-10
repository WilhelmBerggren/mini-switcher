import Cocoa
import Carbon

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
    var seen = Set<String>()

    return list.compactMap { d in
        guard
            let layer = d[kCGWindowLayer] as? Int, layer == 0,
            let pidInt = d[kCGWindowOwnerPID] as? Int, pidInt != myPID,
            let app = d[kCGWindowOwnerName] as? String
        else { return nil }

        let title = d[kCGWindowName] as? String ?? ""
        guard seen.insert("\(pidInt):\(title)").inserted else { return nil }
        return WindowInfo(pid: pid_t(pidInt), appName: app, title: title)
    }
}

// MARK: - Window Activation

func raiseWindow(_ w: WindowInfo) {
    // Try to bring the specific window to front via Accessibility
    let axApp = AXUIElementCreateApplication(w.pid)
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
       let wins = ref as? [AXUIElement] {
        for axWin in wins {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &t)
            if (t as? String ?? "") == w.title {
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
        table.doubleAction = #selector(commitSelection)

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

    func present() {
        windows = fetchWindows()
        guard !windows.isEmpty else { return }
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)

        let rowsVisible = min(windows.count, 14)
        setContentSize(NSSize(width: 560, height: CGFloat(rowsVisible) * table.rowHeight + 12))
        center()
        makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            orderOut(nil)
        case kVK_Return:
            commitSelection()
        case kVK_UpArrow:
            let row = max(0, table.selectedRow - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        case kVK_DownArrow:
            let row = min(windows.count - 1, table.selectedRow + 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func commitSelection() {
        let row = table.selectedRow
        guard row >= 0, row < windows.count else { return }
        orderOut(nil)
        raiseWindow(windows[row])
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
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let panel = SwitcherPanel()

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibility()
        registerHotKey()
    }

    func togglePanel() {
        panel.isVisible ? panel.orderOut(nil) : panel.present()
    }

    private func registerHotKey() {
        let id = EventHotKeyID(signature: 0x4D534E57, id: 1)
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx -> OSStatus in
            Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue().togglePanel()
            return noErr
        }, 1, &spec, ctx, &handlerRef)
        // ⌥Tab: kVK_Tab = 48, optionKey modifier = 2048
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        AXIsProcessTrustedWithOptions([key: kCFBooleanTrue] as CFDictionary)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
