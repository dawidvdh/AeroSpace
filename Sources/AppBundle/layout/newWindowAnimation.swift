import AppKit
import Common

// macOS doesn't allow window managers to intercept window creation. The app creates the window on its own, picks
// the frame on its own, and only then we get notified. Resizing the window forces the app to re-layout and redraw,
// which is slow and ugly. That's why we do the ugly part off-screen:
// 1. Move the new window behind the edge of the monitor (cheap, macOS just moves the already drawn window)
// 2. Resize the window to the size of its tile while nobody sees it
// 3. Bring the window to its tile. Either instantly ('place'), or by changing only the position in a short
//    animation ('slide'). Position only changes are cheap, because the app doesn't need to redraw.
//
// 'popin' goes further and animates snapshots of the windows instead of the windows (see NewWindowChoreography).
// The snapshots are animated by GPU, the apps don't participate in the animation:
// - We can't prevent the new window from appearing at the frame picked by the app, but we can make it the first frame
//   of the animation. Hiding the window and showing it at the tile later looks like flickering (on -> off -> on).
//   As soon as we get notified about the window, we cover it with its own snapshot (nothing changes visually), move
//   the real window off-screen, and the snapshot smoothly travels to the tile
// - The windows that make room for the new window are also covered with their own snapshots, the real windows are
//   resized while nobody sees them, and the snapshots smoothly travel to the new frames
// - Once the animation is finished, the real windows replace the snapshots

private let newWindowAnimationDuration: TimeInterval = 0.16
private let newWindowAnimationFrameInterval: Duration = .milliseconds(8)
private let newWindowMaxAge: TimeInterval = 2
private let choreographyDuration: TimeInterval = 0.24
private let popinInitialScale: CGFloat = 0.87
// The tail of the ease-out animation is imperceptible. Don't wait for it, start the hand-off to the real windows earlier
private let handOffProgress: Double = 0.7
private let freshSnapshotProgress: Double = 0.45
// GPU rendered apps (terminals, browsers) redraw themselves asynchronously after the resize
private let redrawDelay: Duration = .milliseconds(30)
// Let macOS composite the snapshot/the real window before the real window/the snapshot is removed
private let swapDelay: Duration = .milliseconds(25)
private let earlyPhaseWatchdogDelay: Duration = .seconds(1)

@MainActor private var isScreenCaptureAccessRequested = false

@MainActor private var newWindowDetectionTimes: [UInt32: Date] = [:]
/// Layout doesn't touch these windows. The animation is responsible for them
@MainActor private var animatedWindowIds: Set<UInt32> = []

/// The windows that were moved behind the edge of the monitor before we even registered them
private struct EarlyPhase {
    let original: Rect
    /// 'popin' only. The snapshot that covers the original frame of the window
    let overlay: WindowSnapshotOverlay?
}
@MainActor private var earlyPhases: [UInt32: EarlyPhase] = [:]
@MainActor private var earlyPhaseTasks: [UInt32: Task<(), Never>] = [:]

func windowCreatedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    var pid: pid_t = 0
    let isPidKnown = unsafe AXUIElementGetPid(ax, &pid) == .success
    let notif = notif as String
    Task.startUnstructured { @MainActor [pid] in
        if !TrayMenuModel.shared.isEnabled { return }
        if let windowId, isPidKnown { startEarlyPhaseIfPossible(pid: pid, windowId: windowId) }
        scheduleCancellableCompleteRefreshSession(.ax(notif))
    }
}

/// Performance optimization. The complete refresh session takes ~80ms to reach the layout of the new window.
/// All that time the new window is visible at the frame picked by the app. Move the window behind the edge of the
/// monitor as soon as we get notified about it
@MainActor
private func startEarlyPhaseIfPossible(pid: pid_t, windowId: UInt32) {
    guard config.newWindowAnimation != .off,
          !isStartup,
          !isLeftMouseButtonDown, // Tabs that are dragged out to create new windows
          MacWindow.allWindowsMap[windowId] == nil,
          earlyPhaseTasks[windowId] == nil,
          let app = MacApp.allAppsMap[pid],
          app.appId != .zoom
    else { return }
    let workspace = focus.workspace // New windows are always bound to the focused workspace
    let monitor = workspace.workspaceMonitor.rect
    let otherMonitors = monitorInfos.map(\.rect).filter { $0.topLeftCorner != monitor.topLeftCorner }
    let windowLevel = getWindowLevel(for: windowId)
    earlyPhaseTasks[windowId] = Task { @MainActor in
        if !(await mayOnWindowDetectedCallbackMatch(app, windowId, workspace)),
           let original = try? await app.getNewTilingWindowRect(windowId, windowLevel),
           let offscreen = getNewWindowAnimationStart(target: original, monitor: monitor, otherMonitors: otherMonitors)
        {
            let overlay = await coverWithSnapshotIfPossible(windowId, original, monitor: monitor)
            if (try? await app.setAxPositionAndWait(windowId, offscreen, .cancellable)) == true {
                earlyPhases[windowId] = EarlyPhase(original: original, overlay: overlay)
            } else {
                overlay?.close()
            }
        }
        earlyPhaseTasks[windowId] = nil
    }
    // Watchdog. Make sure that the window doesn't stay behind the edge of the monitor if it turns out that the
    // window isn't going to be animated (e.g. the window wasn't recognized as a tiling window)
    Task.startUnstructured { @MainActor in
        try? await Task.sleep(for: earlyPhaseWatchdogDelay)
        if isNewWindowAnimationInProgress(windowId) { return } // The animation is responsible for the window now
        guard let early = earlyPhases.removeValue(forKey: windowId) else { return }
        early.overlay?.close()
        let original = early.original
        let isVisibleTile = MacWindow.allWindowsMap[windowId].map { $0.parent is TilingContainer && $0.nodeWorkspace?.isVisible == true } == true
        if !isVisibleTile { app.setAxFrame(windowId, original.topLeftCorner, nil) }
        scheduleCancellableCompleteRefreshSession(.newWindowAnimation)
    }
}

/// 'popin' only. Cover the window with its own snapshot. Nothing changes visually, but the real window can be moved
/// away now
@MainActor
private func coverWithSnapshotIfPossible(_ windowId: UInt32, _ rect: Rect, monitor: Rect) async -> WindowSnapshotOverlay? {
    guard config.newWindowAnimation == .popin, let image = captureWindowSnapshot(windowId, expectedSize: rect.size) else { return nil }
    let overlay = WindowSnapshotOverlay(image, rect, monitor: monitor, isVisible: true)
    try? await Task.sleep(for: swapDelay) // Let macOS composite the snapshot
    return overlay
}

/// on-window-detected callbacks may make the window floating, move it to another workspace, etc.
/// We can't cheaply predict the result, that's why we don't deal with such windows early
@MainActor
private func mayOnWindowDetectedCallbackMatch(_ app: MacApp, _ windowId: UInt32, _ workspace: Workspace) async -> Bool {
    var title: String?? = nil // Lazy. Most of the callbacks don't need the title
    for callback in config.onWindowDetected {
        switch callback.matcher {
            case .command: return true // Can't evaluate the command for the window that isn't registered yet
            case .legacy(let matcher):
                if matcher.duringAeroSpaceStartup == true { continue }
                if let appId = matcher.appId, appId != app.rawAppBundleId { continue }
                if let regex = matcher.appNameRegexSubstring, !(app.name ?? "").contains(caseInsensitiveRegex: regex) { continue }
                if let name = matcher.workspace, name != workspace.name { continue }
                if let regex = matcher.windowTitleRegexSubstring {
                    if title == nil { title = .some(try? await app.getAxTitle(windowId, .cancellable)) }
                    // Unknown title => can't be sure
                    if let knownTitle = title ?? nil, !knownTitle.contains(caseInsensitiveRegex: regex) { continue }
                }
                return true
        }
    }
    return false
}

@MainActor
func markAsNewWindowForAnimation(_ windowId: UInt32) {
    if config.newWindowAnimation == .off { return }
    newWindowDetectionTimes = newWindowDetectionTimes.filter { $0.value.distance(to: .now) < newWindowMaxAge }
    newWindowDetectionTimes[windowId] = .now
}

@MainActor
func isNewWindowAnimationInProgress(_ windowId: UInt32) -> Bool { animatedWindowIds.contains(windowId) }

extension Window {
    /// Returns `true` if the animation is responsible for placing the window.
    /// The animation always follows the most recent `lastAppliedLayoutPhysicalRect`
    @MainActor
    func animateLayoutIfNeeded(old: Rect?, new target: Rect, _ workspace: Workspace, _ choreography: NewWindowChoreography?) -> Bool {
        if animatedWindowIds.contains(windowId) { return true }
        guard let window = self as? MacWindow else { return false }
        guard let detectedAt = newWindowDetectionTimes.removeValue(forKey: windowId) else {
            // Not a new window. The window might need to make room for the new window
            guard let choreography, let old, !old.isCloseTo(target) else { return false }
            choreography.siblings.append(.init(window: window, old: old))
            animatedWindowIds.insert(windowId)
            return true
        }
        guard config.newWindowAnimation != .off,
              detectedAt.distance(to: .now) < newWindowMaxAge,
              workspace.isVisible,
              window.macApp.appId != .zoom // Zoom jumps off on one pixel offsets https://github.com/nikitabobko/AeroSpace/issues/527
        else { return false }
        let monitor = workspace.workspaceMonitor.rect
        let otherMonitors = monitorInfos.map(\.rect).filter { $0.topLeftCorner != monitor.topLeftCorner }
        guard let start = getNewWindowAnimationStart(target: target, monitor: monitor, otherMonitors: otherMonitors) else { return false }
        animatedWindowIds.insert(windowId)
        if let choreography {
            choreography.newWindows.append(.init(window: window, start: start, size: target.size))
        } else {
            let animation: NewWindowAnimation = config.newWindowAnimation == .popin ? .slide : config.newWindowAnimation
            Task.startUnstructured { @MainActor in
                await runNewWindowAnimation(window, animation, start: start, size: target.size)
            }
        }
        return true
    }
}

/// 'place' and 'slide'
@MainActor
private func runNewWindowAnimation(_ window: MacWindow, _ animation: NewWindowAnimation, start: CGPoint, size: CGSize) async {
    let windowId = window.windowId
    await earlyPhaseTasks[windowId]?.value
    do {
        _ = try await window.macApp.moveAndThenResize(windowId, start, size, .cancellable)
        if animation == .slide {
            let startTime: Date = .now
            while let target = getAnimationTarget(window) {
                let progress = startTime.distance(to: .now) / newWindowAnimationDuration
                if progress >= 1 { break }
                let eased = 1 - pow(1 - progress, 3) // ease-out cubic
                let destination = target.topLeftCorner
                let point = CGPoint(x: start.x + (destination.x - start.x) * eased, y: start.y + (destination.y - start.y) * eased)
                window.macApp.setAxPosition(windowId, point)
                try await Task.sleep(for: newWindowAnimationFrameInterval)
            }
        }
    } catch {
        // Cancellation. Fallthrough to the final placement
    }
    finishAnimation(window)
}

/// Hand the window back to the regular layout
@MainActor
private func finishAnimation(_ window: MacWindow) {
    let windowId = window.windowId
    animatedWindowIds.remove(windowId)
    let early = earlyPhases.removeValue(forKey: windowId)
    early?.overlay?.close()
    let original = early?.original
    if let target = getAnimationTarget(window) {
        window.setAxFrame(target.topLeftCorner, target.size)
    } else if MacWindow.allWindowsMap[windowId] != nil {
        // The window is not a visible tile anymore (floating, fullscreen, another workspace, etc).
        // Make sure that the window doesn't stay behind the edge of the monitor
        if window.isFloating, let monitor = window.nodeWorkspace?.takeIf(\.isVisible)?.workspaceMonitor {
            window.setAxFrame(original?.topLeftCorner ?? monitor.visibleRect.topLeftCorner + CGPoint(x: 50, y: 50), nil)
        }
        scheduleCancellableCompleteRefreshSession(.newWindowAnimation)
    }
}

@MainActor
private func getAnimationTarget(_ window: MacWindow) -> Rect? {
    guard MacWindow.allWindowsMap[window.windowId] != nil,
          !window.isHiddenInCorner,
          window.windowId != currentlyManipulatedWithMouseWindowId,
          window.nodeWorkspace?.isVisible == true
    else { return nil }
    return window.lastAppliedLayoutPhysicalRect // nil for floating and fullscreen windows
}

/// 'popin'. Collects the participants during the layout pass, and then animates them all together
@MainActor
final class NewWindowChoreography {
    struct NewWindow {
        let window: MacWindow
        let start: CGPoint
        let size: CGSize
    }
    struct Sibling {
        let window: MacWindow
        let old: Rect
    }

    private let monitor: Rect
    var newWindows: [NewWindow] = []
    /// The windows that make room for the new windows
    var siblings: [Sibling] = []

    private init(monitor: Rect) { self.monitor = monitor }

    static func newIfNeeded(_ workspace: Workspace) -> NewWindowChoreography? {
        guard config.newWindowAnimation == .popin,
              workspace.isVisible,
              currentlyManipulatedWithMouseWindowId == nil,
              workspace.rootTilingContainer.allLeafWindowsRecursive.contains(where: { newWindowDetectionTimes[$0.windowId] != nil })
        else { return nil }
        if !isScreenCaptureAllowed {
            if !isScreenCaptureAccessRequested {
                isScreenCaptureAccessRequested = true
                CGRequestScreenCaptureAccess() // AeroSpace restart is required after the permission is granted
            }
            return nil
        }
        return NewWindowChoreography(monitor: workspace.workspaceMonitor.rect)
    }

    /// Must be called once the layout pass is finished
    func start() {
        if newWindows.isEmpty { // Nothing to make room for
            siblings.forEach { finishAnimation($0.window) }
            return
        }
        Task.startUnstructured { @MainActor in await self.run() }
    }

    private func run() async {
        for newWindow in newWindows {
            await earlyPhaseTasks[newWindow.window.windowId]?.value
        }
        // The siblings and the new windows are animated independently. The siblings don't wait for the new windows
        // (it takes time to resize the new window off-screen and to take its snapshot)
        let siblingsTask = Task { @MainActor in await self.animateSiblings() }
        await animateNewWindows()
        await siblingsTask.value
    }

    private func animateSiblings() async {
        // 1. Cover the siblings with their own snapshots. Nothing changes visually
        var overlays: [(window: MacWindow, overlay: WindowSnapshotOverlay, old: Rect)] = []
        for sibling in siblings {
            if let image = captureWindowSnapshot(sibling.window.windowId, expectedSize: sibling.old.size) {
                overlays.append((sibling.window, WindowSnapshotOverlay(image, sibling.old, monitor: monitor, isVisible: true), sibling.old))
            } else {
                finishAnimation(sibling.window)
            }
        }
        if overlays.isEmpty { return }
        try? await Task.sleep(for: swapDelay)
        // 2. Resize the real siblings while nobody sees them
        let otherMonitors = monitorInfos.map(\.rect).filter { $0.topLeftCorner != monitor.topLeftCorner }
        var offscreenSiblings: [MacWindow] = []
        for (window, _, old) in overlays {
            guard let target = getAnimationTarget(window) else { continue }
            if !old.covers(target), let offscreen = getNewWindowAnimationStart(target: target, monitor: monitor, otherMonitors: otherMonitors) {
                // The snapshot doesn't cover the new frame all the time. Resize the real window off-screen
                _ = try? await window.macApp.moveAndThenResize(window.windowId, offscreen, target.size, .cancellable)
                offscreenSiblings.append(window)
            } else {
                window.setAxFrame(target.topLeftCorner, target.size) // Under the snapshot
            }
        }
        // 3. Animate the snapshots
        let startTime: Date = .now
        for (window, overlay, _) in overlays {
            guard let target = getAnimationTarget(window) else { continue }
            Task { @MainActor in await overlay.morph(to: target, duration: choreographyDuration) }
        }
        // 4. By this time the real siblings are already redrawn in the new size. Replace their snapshots
        await sleep(until: choreographyDuration * freshSnapshotProgress, since: startTime)
        for (window, overlay, _) in overlays {
            if let target = getAnimationTarget(window), let image = captureWindowSnapshot(window.windowId, expectedSize: target.size * 0.5) {
                overlay.updateSnapshot(image, size: CGSize(width: CGFloat(image.width) / overlay.scale, height: CGFloat(image.height) / overlay.scale))
            }
        }
        // 5. Hand-off. Put the real windows under the snapshots, and only then remove the snapshots
        await sleep(until: choreographyDuration * handOffProgress, since: startTime)
        for window in offscreenSiblings {
            if let target = getAnimationTarget(window) {
                _ = try? await window.macApp.moveAndThenResize(window.windowId, target.topLeftCorner, target.size, .cancellable)
            }
        }
        await sleep(until: choreographyDuration, since: startTime)
        overlays.forEach { finishAnimation($0.window) }
        try? await Task.sleep(for: swapDelay)
        overlays.forEach { $0.overlay.close() }
    }

    private func animateNewWindows() async {
        let tasks = newWindows.map { newWindow in Task { @MainActor in await self.animate(newWindow) } }
        for task in tasks { await task.value }
    }

    private func animate(_ newWindow: NewWindow) async {
        let window = newWindow.window
        let windowId = window.windowId
        // The snapshot that covers the window at the frame where the window appeared
        var overlay = earlyPhases.removeValue(forKey: windowId)?.overlay
        if overlay == nil, let original = try? await window.getAxRect(.cancellable) {
            // The early phase didn't happen (e.g. it's the first window of the app that has just been launched, we
            // don't get AX notifications about such windows). Nobody has touched the window yet
            overlay = await coverWithSnapshotIfPossible(windowId, original, monitor: monitor)
        }
        overlay?.bringToFront() // The new window is above its siblings
        let startTime: Date = .now
        if let overlay, let target = getAnimationTarget(window) {
            Task { @MainActor in await overlay.morph(to: target, duration: choreographyDuration) }
        }
        // Resize the real window off-screen
        let prepared = try? await window.macApp.moveAndThenResize(windowId, newWindow.start, newWindow.size, .cancellable)
        try? await Task.sleep(for: redrawDelay)
        // The window might refuse to take the exact size (e.g. terminals snap to the cell grid)
        let size = prepared?.size ?? newWindow.size
        let image = captureWindowSnapshot(windowId, expectedSize: size)
        if let overlay {
            if let image { overlay.updateSnapshot(image, size: size) }
        } else if let image, let target = getAnimationTarget(window) {
            // Fallback. We failed to cover the window where it appeared. Scale and fade the snapshot in at the tile
            let rect = Rect(topLeftX: target.topLeftX, topLeftY: target.topLeftY, width: size.width, height: size.height)
            let popinOverlay = WindowSnapshotOverlay(image, rect, monitor: monitor, isVisible: false)
            overlay = popinOverlay
            Task { @MainActor in await popinOverlay.popIn(duration: choreographyDuration, initialScale: popinInitialScale) }
        }
        // Hand-off. Put the real window under the snapshot, and only then remove the snapshot
        if overlay != nil {
            await sleep(until: choreographyDuration * handOffProgress, since: startTime)
            if let target = getAnimationTarget(window) {
                _ = try? await window.macApp.moveAndThenResize(windowId, target.topLeftCorner, target.size, .cancellable)
            }
            try? await Task.sleep(for: swapDelay)
        }
        finishAnimation(window)
        overlay?.close()
    }

    private func sleep(until offset: TimeInterval, since start: Date) async {
        let remaining = offset - start.distance(to: .now)
        if remaining > 0 { try? await Task.sleep(for: .milliseconds(Int(remaining * 1000))) }
    }
}

/// The point behind the edge of the monitor, where the window of `target` size is (almost) not visible.
/// One pixel of the window is kept on the monitor, because macOS doesn't like windows that are completely off-screen.
/// The closest side edge is preferred. macOS doesn't allow to move windows behind the bottom edge completely (a strip
/// of the window stays visible), that's why the bottom edge is the last resort.
/// `nil` if all the edges are occupied by other monitors (the window would be visible there)
func getNewWindowAnimationStart(target: Rect, monitor: Rect, otherMonitors: [Rect]) -> CGPoint? {
    let sideEdges: [(start: CGPoint, distance: CGFloat)] = [
        (CGPoint(x: monitor.minX - target.width + 1, y: target.minY), target.maxX - monitor.minX), // left edge
        (CGPoint(x: monitor.maxX - 1, y: target.minY), monitor.maxX - target.minX), // right edge
    ]
    let bottomEdge = CGPoint(x: target.minX, y: monitor.maxY - 1)
    func isFree(_ start: CGPoint) -> Bool {
        let rect = Rect(topLeftX: start.x, topLeftY: start.y, width: target.width, height: target.height)
        return !otherMonitors.contains { rect.intersects($0) }
    }
    return sideEdges.filter { isFree($0.start) }.min { $0.distance < $1.distance }?.start ?? bottomEdge.takeIf(isFree)
}

extension Rect {
    fileprivate func intersects(_ other: Rect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    fileprivate func covers(_ other: Rect) -> Bool {
        minX <= other.minX + 1 && minY <= other.minY + 1 && maxX >= other.maxX - 1 && maxY >= other.maxY - 1
    }

    fileprivate func isCloseTo(_ other: Rect) -> Bool {
        abs(minX - other.minX) < 1 && abs(minY - other.minY) < 1 && abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}

extension CGSize {
    fileprivate static func * (size: CGSize, factor: CGFloat) -> CGSize { CGSize(width: size.width * factor, height: size.height * factor) }
}
