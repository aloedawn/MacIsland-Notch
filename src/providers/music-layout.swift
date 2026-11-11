import SwiftUI

/// Apple supplies artwork, metadata, a spacer and a trailing accessory in this order.
/// The enclosing view owns the native header tap target, timeline and transport row.
struct NotchMusicHeader: Layout {
  let cutoutWidth: CGFloat
  let cutoutHeight: CGFloat

  private struct Positions {
    let size: CGSize
    let art: CGRect
    let metadata: CGRect
    let accessory: CGRect
  }

  private func positions(width: CGFloat?, subviews: Subviews) -> Positions {
    let art = subviews[0].sizeThatFits(.unspecified)
    let accessory = subviews[3].sizeThatFits(.unspecified)
    recordMeasuredMusicWingContent(max(art.width, accessory.width))
    let idealMetadata = subviews[1].sizeThatFits(.unspecified)
    let idealWidth = max(idealMetadata.width, cutoutWidth + 2 * max(art.width, accessory.width))
    let width = width.flatMap { $0.isFinite ? max($0, 0) : nil } ?? idealWidth
    let textWidth = min(width, cutoutWidth)
    let text = subviews[1].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
    let wing = max(0, (width - cutoutWidth) / 2)
    let gap = max(0, subviews[0].spacing.distance(to: subviews[1].spacing, along: .vertical))
    // Contents with large Dynamic Type or a narrow proposal flow under the camera.
    let fits = max(art.width, accessory.width) <= wing + 0.5
    let top = fits ? 0 : cutoutHeight
    let rowHeight = max(art.height, accessory.height, fits ? cutoutHeight : 0)
    let artX: CGFloat = 0
    let accessoryX = max(0, width - accessory.width)
    let stacksAccessory = !fits && art.width + accessory.width > width
    let metadataTop = cutoutHeight + gap
    let artY =
      fits
      ? max(cutoutHeight, metadataTop + (text.height - art.height) / 2)
      : top + (rowHeight - art.height) / 2
    let artFrame = CGRect(origin: CGPoint(x: artX, y: artY), size: art)
    let textY =
      fits
      ? max(metadataTop, artFrame.midY - text.height / 2)
      : top + (stacksAccessory ? art.height + accessory.height : rowHeight) + gap
    let accessoryY = stacksAccessory ? artFrame.maxY : artFrame.midY - accessory.height / 2
    let accessoryFrame = CGRect(
      origin: CGPoint(x: accessoryX, y: max(fits ? 0 : top, accessoryY)), size: accessory)
    let titleX = fits ? wing : 0
    return Positions(
      size: CGSize(
        width: width, height: max(artFrame.maxY, accessoryFrame.maxY, textY + text.height)),
      art: artFrame, metadata: CGRect(x: titleX, y: textY, width: textWidth, height: text.height),
      accessory: accessoryFrame)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    positions(width: proposal.width, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = positions(width: bounds.width, subviews: subviews)
    for (index, rect) in [(0, result.art), (1, result.metadata), (3, result.accessory)] {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: rect.width, height: index == 1 ? nil : rect.height))
    }
    subviews[2].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
  }
}
