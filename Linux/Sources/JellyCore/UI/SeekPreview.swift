import CGtk
import Foundation

/// Over the seek bar while the pointer is on it: the frame at that point, from the
/// server's trickplay tiles, and its time.
///
/// A tile is one image of many thumbnails, so the picture is the whole tile, moved inside
/// a clipped window the size of one thumbnail. The window is an overlay: an overlay is as
/// big as its main child, here an empty one of a thumbnail's size, whatever is laid over
/// it; a fixed container alone would take the whole tile's size.
@MainActor
final class SeekPreview {
    let root: Widget
    private let window: Widget
    private let sizer = Bin()
    private let fixed = Widget(gtk_fixed_new()!)
    private let picture = Picture()
    private let time = Label("", "seek-preview-time", "numeric")
    private var tile: URL?

    init() {
        gtk_widget_set_overflow(fixed.widget, GTK_OVERFLOW_HIDDEN)
        // Its natural size, the tile's: it is placed, not fitted.
        gtk_picture_set_can_shrink(picture.widget.cast(), 0)
        picture.fit(GTK_CONTENT_FIT_FILL)
        gtk_fixed_put(fixed.widget.cast(), picture.widget, 0, 0)
        let window = Overlay(sizer).add(fixed)
        gtk_overlay_set_clip_overlay(window.widget.cast(), fixed.widget, 1)
        gtk_widget_set_overflow(window.widget, GTK_OVERFLOW_HIDDEN)
        let time = self.time.halign(GTK_ALIGN_CENTER)
        self.window = window
        root = Box.vertical(spacing: 4) {
            window
            time
        }.css("seek-preview")
        root.halign(GTK_ALIGN_START).valign(GTK_ALIGN_END).canTarget(false).visible(false)
    }

    /// Shows the time, and the thumbnail when there is one, centred on `x` and standing
    /// `bottom` above the bottom of a parent `width` wide.
    func show(seconds: Double, preview: TrickplayPreview?, x: Double, bottom: Double, width: Double) {
        time.text = Ticks.clock(seconds)
        if let preview {
            window.visible(true)
            sizer.size(width: Int32(preview.frame.width), height: Int32(preview.frame.height))
            gtk_fixed_move(fixed.widget.cast(), picture.widget, Double(-preview.frame.x), Double(-preview.frame.y))
            if preview.tile != tile {
                tile = preview.tile
                picture.load(preview.tile)
            }
        } else {
            window.visible(false)
        }
        // The box's own padding is 6 on each side.
        let boxWidth = Double(preview?.frame.width ?? 56) + 12
        let start = min(max(8, x - boxWidth / 2), max(8, width - boxWidth - 8))
        root.margins(bottom: Int32(bottom), start: Int32(start))
        root.visible(true)
    }

    func hide() {
        root.visible(false)
    }
}
