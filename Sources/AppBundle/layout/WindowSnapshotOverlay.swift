import AppKit
import Common
import PrivateApi

/// A click-through window that shows a snapshot of another window. Unlike the real window of another app, we can
/// animate the snapshot smoothly, because the animation is rendered by GPU (Core Animation), and the app doesn't
/// need to redraw itself
@MainActor
final class WindowSnapshotOverlay {
    private static let cornerRadius: CGFloat = 12
    private let window: NSWindow
    private let monitor: Rect
    private var rect: Rect
    /// Pixels per point of the snapshot
    let scale: CGFloat
    /// The animated "frame of the window". Background + shadow
    private let box = CALayer()
    /// Clips the snapshot to the box
    private let clip = CALayer()
    /// The snapshot is never scaled (scaled text and UI look bad). It's pinned to the top left corner in its natural
    /// size and the box clips it, the same way as if the real window was being resized
    private let imageLayer = CALayer()

    /// - Parameter rect: Where to show the snapshot
    /// - Parameter monitor: The overlay covers the whole monitor, because the snapshot travels around the monitor
    init(_ image: CGImage, _ rect: Rect, monitor: Rect, isVisible: Bool) {
        self.monitor = monitor
        self.rect = rect
        self.scale = rect.width > 0 ? max(CGFloat(image.width) / rect.width, 1) : 1
        let frame = NSRect(
            x: monitor.minX,
            y: mainMonitorInfo.height - monitor.maxY, // Convert to the bottom-left based coordinate system
            width: monitor.width,
            height: monitor.height,
        )
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenAuxiliary]
        window.animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        window.contentView = view

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // AppKit owns geometryFlipped of the view's layer, that's why a dedicated host layer is used
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.isGeometryFlipped = true // Top-left based coordinates, the same as Rect

        let layerRect = toLayerCoordinates(rect)
        let bounds = CGRect(origin: .zero, size: layerRect.size)
        box.anchorPoint = .zero
        box.position = layerRect.origin
        box.bounds = bounds
        box.cornerRadius = WindowSnapshotOverlay.cornerRadius
        box.backgroundColor = getBackgroundColor(image)
        box.opacity = isVisible ? 1 : 0
        // Approximation of the macOS window shadow
        box.shadowOpacity = 0.35
        box.shadowRadius = 18
        box.shadowOffset = CGSize(width: 0, height: 10)
        box.shadowPath = shadowPath(bounds)

        clip.anchorPoint = .zero
        clip.position = .zero
        clip.bounds = bounds
        clip.cornerRadius = WindowSnapshotOverlay.cornerRadius
        clip.masksToBounds = true

        imageLayer.anchorPoint = .zero
        imageLayer.position = .zero
        imageLayer.bounds = bounds
        imageLayer.contents = image

        clip.addSublayer(imageLayer)
        box.addSublayer(clip)
        host.addSublayer(box)
        view.layer?.addSublayer(host)
        CATransaction.commit()

        window.orderFrontRegardless()
        CATransaction.flush()
    }

    private func toLayerCoordinates(_ rect: Rect) -> CGRect {
        CGRect(x: rect.minX - monitor.minX, y: rect.minY - monitor.minY, width: rect.width, height: rect.height)
    }

    private func shadowPath(_ bounds: CGRect) -> CGPath {
        CGPath(roundedRect: bounds, cornerWidth: WindowSnapshotOverlay.cornerRadius, cornerHeight: WindowSnapshotOverlay.cornerRadius, transform: nil)
    }

    /// Scale and fade the snapshot in
    func popIn(duration: TimeInterval, initialScale: CGFloat) async {
        let center = CGPoint(x: box.bounds.midX, y: box.bounds.midY)
        var initial = CATransform3DMakeTranslation(center.x, center.y, 0) // Scale around the center
        initial = CATransform3DScale(initial, initialScale, initialScale, 1)
        initial = CATransform3DTranslate(initial, -center.x, -center.y, 0)
        await run(duration: duration) {
            self.animate(self.box, "transform", from: initial, to: CATransform3DIdentity)
            self.animate(self.box, "opacity", from: 0, to: 1)
            self.box.opacity = 1
        }
    }

    /// Move and resize the box to `target`
    func morph(to target: Rect, duration: TimeInterval) async {
        let from = toLayerCoordinates(rect)
        let to = toLayerCoordinates(target)
        let fromBounds = CGRect(origin: .zero, size: from.size)
        let toBounds = CGRect(origin: .zero, size: to.size)
        rect = target
        await run(duration: duration) {
            self.animate(self.box, "position", from: from.origin, to: to.origin)
            self.animate(self.box, "bounds", from: fromBounds, to: toBounds)
            self.animate(self.box, "shadowPath", from: self.shadowPath(fromBounds), to: self.shadowPath(toBounds))
            self.animate(self.clip, "bounds", from: fromBounds, to: toBounds)
            self.box.position = to.origin
            self.box.bounds = toBounds
            self.box.shadowPath = self.shadowPath(toBounds)
            self.clip.bounds = toBounds
        }
    }

    /// Replace the snapshot with the snapshot of the resized window
    func updateSnapshot(_ image: CGImage, size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(origin: .zero, size: size)
        imageLayer.contents = image
        box.backgroundColor = getBackgroundColor(image)
        CATransaction.commit()
    }

    private var currentDuration: TimeInterval = 0

    private func animate(_ layer: CALayer, _ keyPath: String, from: Any, to: Any) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = currentDuration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) // ease-out
        layer.add(animation, forKey: keyPath)
    }

    private func run(duration: TimeInterval, _ body: () -> ()) async {
        await withCheckedContinuation { (cont: CheckedContinuation<(), Never>) in
            CATransaction.begin()
            CATransaction.setDisableActions(true) // Model values are changed without implicit animations
            CATransaction.setCompletionBlock { cont.resume() }
            currentDuration = duration
            body()
            CATransaction.commit()
        }
    }

    func bringToFront() {
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

/// The color that fills the part of the box that isn't covered by the snapshot (when the window grows)
private func getBackgroundColor(_ image: CGImage) -> CGColor {
    var pixel = [UInt8](repeating: 0, count: 4)
    let fallback = CGColor(gray: 0.12, alpha: 1)
    // Sample the bottom part of the window. Most likely, it's the background rather than the toolbar
    let sample = CGRect(x: image.width / 4, y: image.height * 3 / 4, width: image.width / 2, height: image.height / 5)
    guard let crop = image.cropping(to: sample) else { return fallback }
    let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
        guard let context = unsafe CGContext(
            data: buffer.baseAddress,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return false }
        context.interpolationQuality = .low
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    if !drawn { return fallback }
    return CGColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
}

private let cgsCaptureIgnoreGlobalClipShape: UInt32 = 1 << 11
private let cgsCaptureBestResolution: UInt32 = 1 << 8
// Capture the whole window even if the window is (partially) off-screen. Found empirically
private let cgsCaptureFullSize: UInt32 = 1 << 15

var isScreenCaptureAllowed: Bool { CGPreflightScreenCaptureAccess() }

/// The capture is fast (several milliseconds). `nil` if the window can't be captured in its full size
@MainActor
func captureWindowSnapshot(_ windowId: UInt32, expectedSize: CGSize) -> CGImage? {
    if !isScreenCaptureAllowed { return nil }
    var windowId = windowId
    let options = cgsCaptureIgnoreGlobalClipShape | cgsCaptureBestResolution | cgsCaptureFullSize
    let images = unsafe CGSHWCaptureWindowList(CGSMainConnectionID(), &windowId, 1, options) as? [CGImage]
    guard let image = images?.first else { return nil }
    // Pixels vs points. The image can only be bigger than the window
    if CGFloat(image.width) < expectedSize.width * 0.9 || CGFloat(image.height) < expectedSize.height * 0.9 { return nil }
    return image
}
