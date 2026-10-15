import AppKit

/// Keep each axis centered whenever the image is smaller than the viewport.
/// Bounds coordinates also account for NSScrollView's native magnification.
@MainActor
final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if documentView.frame.width < result.width {
            result.origin.x = documentView.frame.midX - result.width / 2
        }
        if documentView.frame.height < result.height {
            result.origin.y = documentView.frame.midY - result.height / 2
        }
        return result
    }
}
