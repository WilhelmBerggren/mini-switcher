import Cocoa

// Tests for the parts of Fonsterbyte that are decidable without a running window server:
// how a row is labelled, which entries of the window list count as switchable, how jump
// keys are handed out, and how the list is ordered across Spaces.
//
// Run with `make test`, which compiles this file together with main.swift under -DTESTS —
// see the entry point there. XCTest is deliberately not used: it would need a test bundle
// and a package manifest, and the whole project is meant to build with swiftc and make.
//
// What is NOT covered, because it needs real windows, Spaces and Accessibility permission:
// window discovery itself (fetchWindows), titles, raising a window, and the hotkey handling.

// MARK: - Harness

final class Tester {
    private var passed = 0
    private var failed: [String] = []
    private var group = ""

    func group(_ name: String) {
        group = name
        print("\n\(name)")
    }

    func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String) {
        if actual == expected {
            passed += 1
            print("  ✓ \(what)")
        } else {
            failed.append("\(group): \(what)")
            print("  ✗ \(what)")
            print("      expected: \(expected)")
            print("      actual:   \(actual)")
        }
    }

    func expect(_ condition: Bool, _ what: String) { expect(condition, true, what) }

    func summary() -> Bool {
        print("")
        guard failed.isEmpty else {
            print("\(failed.count) failed, \(passed) passed")
            failed.forEach { print("  ✗ \($0)") }
            return false
        }
        print("all \(passed) passed")
        return true
    }
}

// Terse constructors so a test reads as a list of windows rather than a wall of arguments.
private func win(_ app: String, _ title: String = "", id: CGWindowID = 0) -> WindowInfo {
    WindowInfo(id: id, pid: 0, appName: app, title: title, isMinimized: false)
}

private func cgEntry(id: CGWindowID = 1, pid: Int = 42, app: String = "Zed",
                     layer: Int = 0, alpha: Double? = 1) -> [CFString: Any] {
    var d: [CFString: Any] = [
        kCGWindowNumber: id, kCGWindowOwnerPID: pid, kCGWindowOwnerName: app, kCGWindowLayer: layer,
    ]
    if let alpha { d[kCGWindowAlpha] = alpha }
    return d
}

// MARK: - Labels

private func testLabels(_ t: Tester) {
    t.group("WindowInfo.label")
    t.expect(win("Zed", "main.swift").label, "main.swift — Zed", "title and app name are joined")
    t.expect(win("Firefox").label, "Firefox", "no title falls back to the app name")
    t.expect(win("Claude", "Claude").label, "Claude", "a title equal to the app name shows once")
    t.expect(win("Firefox", "firefox").label, "Firefox",
             "the two name sources disagree on case, so the match ignores it")
    t.expect(win("Slack", "Slack — Slack").label, "Slack — Slack — Slack",
             "only an exact match collapses; a title that merely contains it is left alone")

    // The row is drawn from these two pieces, and jump-key offsets are measured against their
    // concatenation — so a split that didn't rebuild the label would underline the wrong letter.
    t.expect(win("Zed", "main.swift").titlePart, "main.swift", "the title piece is the title")
    t.expect(win("Zed", "main.swift").appPart, " — Zed", "the app piece carries the separator")
    t.expect(win("Claude", "Claude").titlePart, "", "a collapsed row has no title piece")
    t.expect(win("Claude", "Claude").appPart, "Claude", "and its app piece is the whole row")
    for w in [win("Zed", "main.swift"), win("Claude", "Claude"), win("Firefox")] {
        t.expect(w.titlePart + w.appPart, w.label, "the pieces reassemble into \"\(w.label)\"")
    }
}

// MARK: - Window List Filtering

private func testSwitchableWindow(_ t: Tester) {
    t.group("switchableWindow")
    let mine: pid_t = 99

    t.expect(switchableWindow(cgEntry(), myPID: mine)?.id, 1, "an ordinary window is switchable")
    t.expect(switchableWindow(cgEntry(layer: 25), myPID: mine) == nil,
             "menus and panels live above layer 0")
    t.expect(switchableWindow(cgEntry(alpha: 0), myPID: mine) == nil,
             "a fully transparent window is dropped — Firefox leaves one on screen in full-screen")
    t.expect(switchableWindow(cgEntry(pid: 99), myPID: mine) == nil, "our own panel is skipped")
    t.expect(switchableWindow(cgEntry(alpha: nil), myPID: mine)?.id, 1,
             "a missing alpha counts as opaque rather than as transparent")
    t.expect(switchableWindow([:], myPID: mine) == nil, "an entry missing everything is not a window")

    let w = switchableWindow(cgEntry(id: 7, pid: 3, app: "Slack"), myPID: mine)
    t.expect(w?.pid, 3, "the owning pid is carried through")
    t.expect(w?.app, "Slack", "the app name is carried through")
}

// MARK: - Jump Keys

private func keys(_ windows: [WindowInfo]) -> [Character?] {
    assignJumpKeys(windows).map { $0?.key }
}

private func testJumpKeys(_ t: Tester) {
    t.group("assignJumpKeys")

    t.expect(keys([win("Slack", "platform-notifications - humly - Slack")]), ["s"],
             "the key comes from the app name, not from the title the row starts with")
    t.expect(keys([win("Zed", "a"), win("Zed", "b")]), ["z", "e"],
             "a second window of the same app takes the next free letter of that app's name")
    t.expect(keys([win("Zed", "a"), win("Zed", "b"), win("Zed", "vinga")]), ["z", "e", "d"],
             "and keeps going through the app name before looking at the title")

    // The reported case: a run of windows from one app must not eat another app's initial.
    let manyZed = [win("Zed", "a"), win("Zed", "b"), win("Zed", "c"), win("DBeaver", "x")]
    t.expect(keys(manyZed), ["z", "e", "c", "d"],
             "every app claims a letter before any app claims a second")

    // Claims go in alphabetical order, so two apps wanting the same letter resolve the same
    // way every time — Signal takes "s" from Slack because "Signal" sorts first.
    t.expect(keys([win("Slack", "a"), win("Signal")]), ["l", "s"],
             "the alphabetically first app wins a contested letter, whatever the list order")
    t.expect(keys([win("Signal"), win("Slack", "a")]), ["s", "l"],
             "and the same letters are handed out when the list order is reversed")

    t.expect(keys([win("A", "A"), win("A", "A")]), ["a", nil],
             "a row with no free letter left gets no key at all")

    let assigned = assignJumpKeys([win("Zed", "a"), win("Zed", "b"), win("Slack", "c"), win("Signal")])
    t.expect(Set(assigned.compactMap { $0?.key }).count, 4, "keys are unique across the list")
}

private func testJumpKeyUnderlines(_ t: Tester) {
    t.group("assignJumpKeys underlines")

    let windows = [win("Slack", "platform-notifications - humly - Slack"), win("Zed", "main.swift")]
    for (window, jump) in zip(windows, assignJumpKeys(windows)) {
        guard let jump else { continue }
        let underlined = Array(window.label)[jump.offset]
        t.expect(underlined.lowercased().first, jump.key,
                 "'\(jump.key)' underlines the character it selects in \"\(window.label)\"")
    }

    // The app name is the tail of the label, so the offset must land there — this title also
    // contains "Slack", and underlining that earlier copy would look like the wrong letter.
    let slack = win("Slack", "platform-notifications - humly - Slack")
    let appStart = slack.label.count - slack.appName.count
    t.expect(assignJumpKeys([slack])[0].map { $0.offset >= appStart } ?? false,
             "the underline sits on the app name, not the title's copy of it")
}

private func testJumpKeyStability(_ t: Tester) {
    t.group("assignJumpKeys stability")

    // The list is ordered by recency, so the same windows arrive in a different order after
    // every switch. The keys must not move with them.
    let windows = [
        win("Zed", "fonsterbyte", id: 1), win("Zed", "humly", id: 2), win("Zed", "vinga", id: 3),
        win("Slack", "platform-notifications", id: 4), win("Slack", "threads", id: 5),
        win("Signal", id: 6), win("DBeaver", "activities", id: 7), win("Claude", "Claude", id: 8),
    ]
    func mapping(_ ws: [WindowInfo]) -> [CGWindowID: Character] {
        var out: [CGWindowID: Character] = [:]
        for (w, jump) in zip(ws, assignJumpKeys(ws)) { out[w.id] = jump?.key }
        return out
    }

    let baseline = mapping(windows)
    var reordered = windows
    var stable = true
    for step in 1...12 {
        reordered = Array(reordered.dropFirst()) + [reordered[0]]
        if step % 3 == 0 { reordered.swapAt(0, reordered.count - 1) }
        if mapping(reordered) != baseline { stable = false }
    }
    t.expect(stable, "every window keeps its key across 12 reorderings of the list")
}

// MARK: - Ordering

// Drives orderedByRecentUse the way the panel does: each call is one press of the switcher,
// carrying the previous result forward as the memory.
private final class Switcher {
    private var remembered: [CGWindowID] = []
    func present(current: [WindowInfo], others: [WindowInfo] = []) -> [String] {
        let ordered = orderedByRecentUse(current: current, others: others, remembered: remembered)
        remembered = ordered.map(\.id)
        return ordered.map(\.label)
    }
}

private func testOrdering(_ t: Tester) {
    t.group("orderedByRecentUse")

    let zed = win("Zed", id: 1), slack = win("Slack", id: 2), ghostty = win("Ghostty", id: 3)
    let full = win("Firefox", "YouTube", id: 130) // full-screen, so a Space of its own

    var s = Switcher()
    t.expect(s.present(current: [zed, slack, ghostty], others: [full]),
             ["Zed", "Slack", "Ghostty", "YouTube — Firefox"],
             "with no memory the active Space keeps z-order and the rest follows")

    t.expect(s.present(current: [full], others: [zed, slack, ghostty]),
             ["YouTube — Firefox", "Zed", "Slack", "Ghostty"],
             "inside the full-screen Space its window leads, the others keep their order")

    // The reported bug: coming back from another Space, that Space must be one press away.
    t.expect(s.present(current: [zed, slack, ghostty], others: [full]),
             ["Zed", "YouTube — Firefox", "Slack", "Ghostty"],
             "back on the desktop the Space just left is second, not last")

    _ = s.present(current: [full], others: [zed, slack, ghostty])
    t.expect(s.present(current: [zed, slack, ghostty], others: [full]),
             ["Zed", "YouTube — Firefox", "Slack", "Ghostty"],
             "switching back and forth keeps the pair at the top")

    t.expect(s.present(current: [slack, zed, ghostty], others: [full]),
             ["Slack", "YouTube — Firefox", "Zed", "Ghostty"],
             "raising a window outside the switcher is picked up from live z-order")

    let preview = win("Preview", id: 4)
    t.expect(s.present(current: [preview, slack, zed, ghostty], others: [full]),
             ["Preview", "YouTube — Firefox", "Slack", "Zed", "Ghostty"],
             "a newly opened window leads the list")

    t.expect(s.present(current: [preview, slack, zed, ghostty]),
             ["Preview", "Slack", "Zed", "Ghostty"],
             "a closed window leaves no gap behind")

    s = Switcher()
    _ = s.present(current: [zed, slack, ghostty])
    t.expect(s.present(current: [ghostty, zed, slack]), ["Ghostty", "Zed", "Slack"],
             "with everything on one Space this is plain z-order")

    t.expect(Switcher().present(current: [], others: [full]), ["YouTube — Firefox"],
             "an empty active Space still lists what is elsewhere")
}

// MARK: - Runner

func runTests() -> Bool {
    let t = Tester()
    testLabels(t)
    testSwitchableWindow(t)
    testJumpKeys(t)
    testJumpKeyUnderlines(t)
    testJumpKeyStability(t)
    testOrdering(t)
    return t.summary()
}
