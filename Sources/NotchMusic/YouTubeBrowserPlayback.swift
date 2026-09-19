import AppKit
import ApplicationServices

struct YouTubeBrowserSnapshot: Sendable {
    let processID: pid_t
    let title: String
    let artist: String
    let elapsed: Double
    let duration: Double
    let playing: Bool
}

// Accessibility notifications are the primary invalidation path. A bounded
// refresh remains as a safety net for browser versions that do not publish a
// notification when their web content changes.
struct YouTubeBrowserCachePolicy {
    static let playingRefreshInterval: TimeInterval = 10
    static let pausedRefreshInterval: TimeInterval = 30

    static func canReuseSnapshot(
        playing: Bool,
        age: TimeInterval,
        invalidated: Bool
    ) -> Bool {
        guard !invalidated, age >= 0 else { return false }
        return age < (playing ? playingRefreshInterval : pausedRefreshInterval)
    }
}

// Monotonic deadlines also make retries deterministic in regression checks.
struct YouTubeBrowserRetryPolicy {
    private(set) var failures = 0
    private(set) var nextAttempt: TimeInterval = 0
    mutating func failed(at now: TimeInterval) {
        failures = min(failures + 1, 4)
        nextAttempt = now + min(5 * pow(2, Double(failures - 1)), 30)
    }
    mutating func reset() { failures = 0; nextAttempt = 0 }
    func allowsAttempt(at now: TimeInterval) -> Bool { now >= nextAttempt }
}

private let youtubeAXCallback: AXObserverCallback = { _, element, notification, _ in
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }
    let name = notification as String
    let structure = [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
                     kAXUIElementDestroyedNotification].contains(name)
    Task { await YouTubeBrowserPlayback.shared.invalidate(processID: pid, structure: structure, layout: name == kAXLayoutChangedNotification) }
}

// Read only a verified music.youtube.com page, independently of the system's
// global Now Playing owner. All AX work runs off the main actor.
actor YouTubeBrowserPlayback {
    static let shared = YouTubeBrowserPlayback()
    enum Command: Sendable { case toggle, next, previous, seek(Double) }
    static func isMusicURL(_ url: URL?) -> Bool { url?.scheme == "https" && url?.host?.lowercased() == "music.youtube.com" }
    private struct Cache {
        var webArea: AXUIElement?
        var bar: AXUIElement?
        var nodes: [AXUIElement] = []
        var transport: AXUIElement?
        var observer: AXObserver?
        var snapshot: YouTubeBrowserSnapshot?
        var lastRead: TimeInterval = -.infinity
        var nodesRead: TimeInterval = -.infinity
        var refreshRequired = false
        var retry = YouTubeBrowserRetryPolicy()
    }
    static func playbackState(for label: String) -> Bool? {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "일시중지", "일시 중지", "일시 정지", "pause": return true
        case "재생", "play": return false
        default: return nil
        }
    }
    private var caches: [pid_t: Cache] = [:]
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func invalidate(processID: pid_t, structure: Bool, layout: Bool) {
        guard var cache = caches[processID] else { return }
        cache.refreshRequired = true
        if layout || structure {
            cache.nodes = []
            cache.nodesRead = -.infinity
        }
        // Window changes may reveal a new tab; rediscover only on these events.
        // Do not rescan the whole browser on playback progress notifications.
        if structure { cache.transport = nil; cache.webArea = nil; cache.bar = nil; cache.nodes = []; cache.snapshot = nil }
        cache.retry.reset()
        caches[processID] = cache
    }

    func retainProcesses(_ processIDs: Set<pid_t>) {
        for pid in Array(caches.keys) where !processIDs.contains(pid) {
            if let observer = caches.removeValue(forKey: pid)?.observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }

    private func observe(_ element: AXUIElement, with observer: AXObserver?, names: [String]) {
        guard let observer else { return }
        for name in names {
            // Unsupported notifications are expected; bounded polling is the fallback.
            AXObserverAddNotification(observer, element, name as CFString, nil)
        }
    }

    private func newCache(processID: pid_t) -> Cache {
        var cache = Cache()
        var observer: AXObserver?
        if AXObserverCreate(processID, youtubeAXCallback, &observer) == .success, let observer {
            cache.observer = observer
            let root = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(root, 0.12)
            observe(root, with: observer, names: [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification])
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        return cache
    }

    private func musicPage(_ element: AXUIElement) -> Bool {
        let raw = attr(element, kAXURLAttribute)
        return Self.isMusicURL((raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)))
    }

    private func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }
    private func text(_ element: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let value = attr(element, name) as? String, !value.isEmpty { return value }
        }
        return ""
    }
    private func toolbar(processID: pid_t) -> (AXUIElement, AXUIElement)? {
        guard AXIsProcessTrusted() else { return nil }
        let root = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(root, 0.12)
        let deadline = now + 2
        var pending: [(AXUIElement, AXUIElement?)] = [(root, nil)]
        var count = 0
        while let (element, verified) = pending.popLast(), count < 4500, now < deadline, !Task.isCancelled {
            count += 1
            let role = attr(element, kAXRoleAttribute) as? String ?? ""
            var inMusic = verified
            if role == "AXWebArea" {
                guard musicPage(element) else { continue }
                inMusic = element
            }
            if let webArea = inMusic, role == "AXToolbar", ["플레이어 바", "Player bar", "Player Bar"].contains(text(element)) { return (webArea, element) }
            if let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.reversed().map { ($0, inMusic) })
            }
        }
        return nil
    }
    private func descendants(_ root: AXUIElement) -> [AXUIElement] {
        var pending = [root], result: [AXUIElement] = []
        let deadline = now + 0.3
        while let e = pending.popLast(), result.count < 200, now < deadline, !Task.isCancelled {
            result.append(e)
            if let children = attr(e, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children.reversed()) }
        }
        return result
    }
    static func times(_ text: String) -> (Double, Double)? {
        let halves = text.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard halves.count == 2 else { return nil }
        func seconds(_ value: String) -> Double? {
            let components = value.split(separator: ":", omittingEmptySubsequences: false)
            let parts = components.compactMap { Double($0) }
            guard parts.count == components.count, parts.count >= 2, parts.count <= 3,
                  parts.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        guard let elapsed = seconds(halves[0]), let duration = seconds(halves[1]) else { return nil }
        return (elapsed, duration)
    }
    static func seekValue(
        seconds: Double,
        duration: Double,
        minimum: Double,
        maximum: Double
    ) -> Double? {
        guard seconds.isFinite, duration.isFinite, minimum.isFinite, maximum.isFinite,
              maximum > minimum else { return nil }
        let clampedSeconds = min(max(seconds, 0), max(duration, 0))
        if maximum - minimum <= 1.01, duration > 0 {
            return minimum + (clampedSeconds / duration) * (maximum - minimum)
        }
        return min(max(clampedSeconds, minimum), maximum)
    }
    private func player(processID: pid_t, cache: inout Cache) -> AXUIElement? {
        if let web = cache.webArea, let bar = cache.bar, musicPage(web),
           (attr(bar, kAXRoleAttribute) as? String) == "AXToolbar" { return bar }
        cache.webArea = nil
        cache.bar = nil
        cache.nodes = []
        cache.snapshot = nil
        guard cache.retry.allowsAttempt(at: now) else { return nil }
        // Rebuild subscriptions so closed tabs and old nodes are not retained.
        if let observer = cache.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        let retry = cache.retry
        cache = newCache(processID: processID)
        cache.retry = retry
        guard let (web, bar) = toolbar(processID: processID) else {
            cache.retry.failed(at: now)
            return nil
        }
        cache.retry.reset()
        cache.webArea = web
        cache.bar = bar
        observe(web, with: cache.observer, names: [kAXUIElementDestroyedNotification, kAXLayoutChangedNotification])
        observe(bar, with: cache.observer, names: [kAXUIElementDestroyedNotification, kAXLayoutChangedNotification])
        return bar
    }

    func read(processID: pid_t) -> YouTubeBrowserSnapshot? {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return nil }
        var cache = caches[processID] ?? Cache()
        defer { caches[processID] = cache }
        // Most one-second client polls only extrapolate the cached clock. AX is
        // touched again after an observed content/layout change or the bounded
        // safety refresh interval.
        if let snapshot = cache.snapshot,
           YouTubeBrowserCachePolicy.canReuseSnapshot(
               playing: snapshot.playing,
               age: now - cache.lastRead,
               invalidated: cache.refreshRequired
           ), let transport = cache.transport,
           Self.playbackState(for: text(transport)) == snapshot.playing {
            // Validate one control even when metadata is cached. Missing AX
            // notifications must not freeze pause/resume for 10–30 seconds.
            return .init(processID: processID, title: snapshot.title, artist: snapshot.artist,
                         elapsed: min(snapshot.duration, snapshot.elapsed + (snapshot.playing ? now - cache.lastRead : 0)),
                         duration: snapshot.duration, playing: snapshot.playing)
        }
        guard let bar = player(processID: processID, cache: &cache) else { return nil }
        if cache.nodes.isEmpty || now - cache.nodesRead >= 15 {
            cache.nodes = descendants(bar)
            cache.nodesRead = now
        }
        // Each node's text is fetched once, instead of once per metadata field.
        var values = cache.nodes.map { (node: $0, role: attr($0, kAXRoleAttribute) as? String ?? "", value: text($0)) }
        if values.contains(where: { $0.role.isEmpty }) || !values.contains(where: { $0.role == "AXHeading" }) {
            cache.nodes = descendants(bar)
            cache.nodesRead = now
            values = cache.nodes.map { (node: $0, role: attr($0, kAXRoleAttribute) as? String ?? "", value: text($0)) }
        }
        guard let heading = values.first(where: { $0.role == "AXHeading" }) else {
            cache.snapshot = nil
            cache.bar = nil
            cache.retry.failed(at: now)
            return nil
        }
        let title = heading.value.isEmpty ? descendants(heading.node).map(text).first(where: { !$0.isEmpty }) ?? "" : heading.value
        guard !title.isEmpty else { cache.snapshot = nil; cache.nodes = []; return nil }
        let artist = values.first(where: { $0.role == "AXLink" })?.value ?? ""
        let clock = values.lazy.compactMap { Self.times($0.value) }.first ?? (0, 0)
        guard let transportValue = values.first(where: {
            $0.role == "AXButton" && Self.playbackState(for: $0.value) != nil
        }), let playing = Self.playbackState(for: transportValue.value) else {
            // An incomplete accessibility tree is unknown, not a paused track.
            cache.nodes = []; cache.transport = nil; cache.refreshRequired = true
            return nil
        }
        cache.transport = transportValue.node
        let snapshot = YouTubeBrowserSnapshot(processID: processID, title: title, artist: artist, elapsed: clock.0, duration: clock.1, playing: playing)
        let metadataNodes = [values.first(where: { $0.role == "AXHeading" }),
                             values.first(where: { $0.role == "AXLink" })]
            .compactMap { $0?.node }
        let transportNode = values.first(where: {
            ["일시중지", "일시 정지", "Pause", "재생", "Play"].contains($0.value)
        })?.node
        for node in metadataNodes {
            observe(node, with: cache.observer, names: [kAXTitleChangedNotification,
                                                       kAXValueChangedNotification,
                                                       kAXUIElementDestroyedNotification])
        }
        if let transportNode {
            observe(transportNode, with: cache.observer, names: [kAXTitleChangedNotification,
                                                                kAXValueChangedNotification,
                                                                kAXUIElementDestroyedNotification])
        }
        // Keep only metadata/transport handles for the next lightweight read.
        // Rebuild the bounded player subtree on layout events or every 15 seconds.
        cache.nodes = [values.first(where: { $0.role == "AXHeading" }),
                       values.first(where: { $0.role == "AXLink" }),
                       values.first(where: { Self.times($0.value) != nil }),
                       values.first(where: { ["일시중지", "일시 정지", "Pause", "재생", "Play"].contains($0.value) })]
            .compactMap { $0?.node }
        cache.snapshot = snapshot
        cache.lastRead = now
        cache.refreshRequired = false
        return snapshot
    }
    func readLyrics(processID: pid_t) -> String? {
        guard AXIsProcessTrusted(), let cache = caches[processID], let web = cache.webArea else { return nil }
        let nodes = descendants(web)
        let texts = nodes.compactMap { node -> String? in
            let value = text(node).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count > 1, value.count < 500 else { return nil }
            return value
        }
        let candidates = texts.filter { value in
            value.components(separatedBy: .newlines).filter { !$0.isEmpty }.count >= 4
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.max { $0.count < $1.count }
    }

    func send(_ command: Command, processID: pid_t) -> Bool {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return false }
        var cache = caches[processID] ?? Cache()
        // Explicit controls may retry immediately and always use current controls.
        cache.retry.reset()
        defer { cache.refreshRequired = true; cache.nodes = []; caches[processID] = cache }
        guard let bar = player(processID: processID, cache: &cache) else { return false }
        if case .toggle = command, let transport = cache.transport,
           Self.playbackState(for: text(transport)) != nil,
           AXUIElementPerformAction(transport, kAXPressAction as CFString) == .success {
            return true
        }
        let nodes = descendants(bar)
        if case .seek(let seconds) = command {
            func number(_ element: AXUIElement, _ attribute: String) -> Double? {
                (attr(element, attribute) as? NSNumber)?.doubleValue
            }
            let controls = nodes.compactMap { element -> (AXUIElement, Int, Double, Double)? in
                let role = attr(element, kAXRoleAttribute) as? String ?? ""
                guard role == "AXSlider" || role == "AXProgressIndicator" else { return nil }
                let minimum = number(element, kAXMinValueAttribute) ?? 0
                let maximum = number(element, kAXMaxValueAttribute) ?? cache.snapshot?.duration ?? 0
                let label = text(element).lowercased()
                var score = role == "AXProgressIndicator" ? 2 : 0
                if label.contains("seek") || label.contains("playback") || label.contains("progress")
                    || label.contains("재생") || label.contains("탐색") { score += 8 }
                if maximum > 1.01 { score += 4 }
                if let duration = cache.snapshot?.duration, duration > 0,
                   abs(maximum - duration) < max(3, duration * 0.03) { score += 8 }
                return (element, score, minimum, maximum)
            }.sorted { $0.1 > $1.1 }
            for (seek, _, minimum, maximum) in controls {
                guard let value = Self.seekValue(
                    seconds: seconds,
                    duration: cache.snapshot?.duration ?? maximum,
                    minimum: minimum,
                    maximum: maximum
                ) else { continue }
                // Chromium has reported this attribute as non-settable on some
                // releases even though the subsequent write succeeds.
                if AXUIElementSetAttributeValue(
                    seek,
                    kAXValueAttribute as CFString,
                    NSNumber(value: value)
                ) == .success { return true }
            }
            return false
        }
        let names: [String]
        switch command {
        case .toggle: names = ["일시중지", "일시 정지", "Pause", "재생", "Play"]
        case .next: names = ["다음", "Next"]
        case .previous: names = ["이전", "Previous"]
        case .seek: return false
        }
        guard let button = nodes.first(where: { (attr($0, kAXRoleAttribute) as? String) == "AXButton" && names.contains(text($0)) }) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
}
