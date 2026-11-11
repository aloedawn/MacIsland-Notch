import AppKit
import Darwin
import SwiftUI
import os

private let sessionMangle = "12NowPlayingUI0aB19ActivitySessionViewV"
private let defaultExpandedArtworkWidth: CGFloat = 52
// Space between the artwork (or trailing accessory) and the camera housing.
private let notchClearance: CGFloat = 12

// Apple's artwork carries its own fixed frame. The surface width is chosen
// before the session lays out, so remember the latest required wing item width.
private let wingContentWidth = OSAllocatedUnfairLock<CGFloat?>(initialState: nil)
// Track whether NowPlayingActivitySurface stripped top notch padding on the
// current evaluation so fallback states never render behind the camera cutout.
private let surfaceAdjustment = OSAllocatedUnfairLock<(applied: Bool, strippedTop: CGFloat)>(
  initialState: (false, 0))

func recordMeasuredMusicWingContent(_ measured: CGFloat) {
  guard measured.isFinite, measured > 0, measured <= 96 else { return }
  wingContentWidth.withLock { current in
    if current == nil || measured > (current ?? 0) + 0.5 {
      current = measured
    }
  }
}

private func fixedWidth(_ value: Any) -> CGFloat? {
  var current = value
  while valueName(current).hasPrefix("SwiftUI.ModifiedContent<") {
    if let modifier = child(current, "modifier"), valueName(modifier) == "SwiftUI._FrameLayout",
      let field = child(modifier, "width") as? CGFloat?, let width = field, width.isFinite,
      width > 0
    {
      return width
    }
    guard let next = child(current, "content") else { return nil }
    current = next
  }
  return nil
}

private struct HeaderParts {
  let children: [AnyView]
  let modifiers: [any ViewModifier]
  init?(_ header: Any) {
    var stack = header
    var mods: [any ViewModifier] = []
    while valueName(stack).hasPrefix("SwiftUI.ModifiedContent<") {
      guard let next = child(stack, "content"),
        let mod = child(stack, "modifier") as? any ViewModifier
      else { return nil }
      mods.append(mod)
      stack = next
    }
    guard valueName(stack).hasPrefix("SwiftUI.HStack<"), let parts = stackChildren(stack),
      parts.count == 4,
      valueName(parts[0]).contains("NowPlayingUI.FlippingArtworkView"),
      valueName(parts[1]).contains("NowPlayingUI.MetadataView"),
      valueName(parts[2]) == "SwiftUI.Spacer",
      valueName(parts[3]).contains("NowPlayingUI.Waveform")
    else { return nil }
    // Keep the active native accessory and its playback modifiers.
    guard let storage = child(parts[3], "storage"),
      let selected = Mirror(reflecting: storage).children.first?.value,
      let accessory = anyView(selected)
    else { return nil }
    let vs = parts.prefix(3).compactMap(anyView) + [accessory]
    guard vs.count == 4 else { return nil }
    children = vs
    modifiers = mods.reversed()
    if let width = fixedWidth(parts[0]) { recordMeasuredMusicWingContent(width) }
  }
  @MainActor func build(size: CGSize) -> AnyView {
    let layout = NotchMusicHeader(cutoutWidth: size.width, cutoutHeight: size.height)
    var row = AnyView(
      layout {
        children[0]
        children[1]
        children[2]
        HStack(spacing: 0) { children[3].fixedSize() }
      })
    func apply<M: ViewModifier>(_ modifier: M, _ value: AnyView) -> AnyView {
      AnyView(value.modifier(modifier))
    }
    for modifier in modifiers { row = apply(modifier, row) }
    return row
  }
}

// The loader reads readiness after it detaches, on a separate debugger thread.
private let musicReadiness = OSAllocatedUnfairLock<Int32>(initialState: 0)

// The full music session receives compact mode before the host finishes
// dismissing it. Its artwork and transport still belong to the outgoing panel.
// Apple's separate leading/trailing compact scenes use their own view types.
private func panelCutout(_ context: Any) -> (size: CGSize, screen: NSScreen)? {
  guard let mode = child(context, "layoutMode"),
    ["expanded", "compact"].contains(String(describing: mode)),
    let metrics = child(context, "obstructionMetrics"),
    let size = child(metrics, "size") as? CGSize, let screen = cutoutScreen(size)
  else { return nil }
  return (size, screen)
}

private struct SessionLayout<Native: View>: View {
  let native: Native
  var body: AnyView {
    let stock = native.body
    let rawFallback = AnyView(stock)
    guard let context = child(native, "context"), let cutout = panelCutout(context) else {
      return rawFallback
    }
    let (surfaceApplied, strippedTop) = surfaceAdjustment.withLock { $0 }
    guard surfaceApplied else {
      return rawFallback
    }
    let safeFallback =
      strippedTop > 0 ? AnyView(stock.padding(.top, strippedTop)) : rawFallback
    guard let rows = stackChildren(stock), rows.count == 3, let lead = anyView(rows[0]),
      let parts = HeaderParts(rows[1]), let tail = anyView(rows[2]),
      valueName(rows[2]).contains("NowPlayingUI.TimelineControl"),
      valueName(rows[2]).contains("NowPlayingUI.TransportControls")
    else { return safeFallback }
    let gap =
      child(stock, "_tree").flatMap { child($0, "root") }.flatMap { child($0, "spacing") }
      as? CGFloat

    return AnyView(
      VStack(spacing: gap) {
        lead
        parts.build(size: cutout.size)
        tail
      })
  }
}

extension View {
  fileprivate nonisolated var miProjectedSession: SessionLayout<Self> {
    SessionLayout(native: self)
  }
}

// SwiftUI invokes these signed witness entries with the native graph. Project
// the typed graph through a key path so its state and observation stay attached.
private struct Relay: View {
  nonisolated(unsafe) static var make: ((_GraphValue<Relay>, _ViewInputs) -> _ViewOutputs)!
  nonisolated(unsafe) static var list: ((_GraphValue<Relay>, _ViewListInputs) -> _ViewListOutputs)!
  var body: Never { fatalError("uninstantiated graph relay") }
  nonisolated static func _makeView(view: _GraphValue<Relay>, inputs: _ViewInputs) -> _ViewOutputs {
    return make(view, inputs)
  }
  nonisolated static func _makeViewList(view: _GraphValue<Relay>, inputs: _ViewListInputs)
    -> _ViewListOutputs
  { return list(view, inputs) }
}

private nonisolated(unsafe) var installed: (UnsafeMutablePointer<UInt>, UInt, UInt, UInt, UInt)?

private func install<T: View>(_ type: T.Type) -> Int {
  guard installed == nil else { return 1 }
  let name = String(reflecting: T.Body.self)
  guard name.hasPrefix("SwiftUI.VStack<SwiftUI.TupleContent<"),
    ["FlippingArtworkView", "MetadataView", "Waveform", "TimelineControl", "TransportControls"]
      .allSatisfy(name.contains)
  else { return -3 }
  let dest = witnessTable(type)
  let source = witnessTable(Relay.self)
  guard isWritableRegion(dest + 3, bytes: 2 * MemoryLayout<UInt>.size) else { return -4 }
  let requirements = [
    "$s7SwiftUI4ViewP05_makeC04view6inputsAA01_C7OutputsVAA11_GraphValueVyxG_AA01_C6InputsVtFZTq",
    "$s7SwiftUI4ViewP05_makeC4List4view6inputsAA01_cE7OutputsVAA11_GraphValueVyxG_AA01_cE6InputsVtFZTq",
  ]
  let disc = requirements.compactMap {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0)?.load(as: UInt32.self)
  }.map { $0 >> 16 }
  guard disc == [0xaeaf, 0x6ddd] else { return -5 }
  Relay.make = { graph, inputs in
    let typed = unsafeBitCast(graph, to: _GraphValue<T>.self)
    return SessionLayout<T>._makeView(view: typed[\.miProjectedSession], inputs: inputs)
  }
  Relay.list = { graph, inputs in
    let typed = unsafeBitCast(graph, to: _GraphValue<T>.self)
    return SessionLayout<T>._makeViewList(view: typed[\.miProjectedSession], inputs: inputs)
  }
  let make = signedEntry(source + 3, dest + 3, disc[0])
  let list = signedEntry(source + 4, dest + 4, disc[1])
  installed = (dest, dest[3], dest[4], make, list)
  dest[3] = make
  dest[4] = list
  return 1
}

// Look up the two native layout fields by reflection on this exact OS build.
// The assembly shim calls Apple's body getter first, retaining its stored state.
private func originalModifiers(_ type: Any.Type) -> (Int, Int)? {
  var current = type
  var base = 0
  var width: Int?
  var insets: Int?
  while String(reflecting: current).hasPrefix("SwiftUI.ModifiedContent<") {
    guard let c = fieldInfo(current, "content"), let m = fieldInfo(current, "modifier") else {
      return nil
    }
    if String(reflecting: m.1) == "SwiftUI._FrameLayout", let w = fieldInfo(m.1, "width"),
      w.1 == CGFloat?.self
    {
      width = base + m.0 + w.0
    }
    if String(reflecting: m.1) == "SwiftUI._PaddingLayout", let i = fieldInfo(m.1, "insets"),
      i.1 == EdgeInsets?.self
    {
      insets = base + m.0 + i.0
    }
    base += c.0
    current = c.1
  }
  guard let w = width, let i = insets else { return nil }
  return (w, i)
}

private nonisolated(unsafe) var surfaceResult:
  ((UnsafeRawPointer, UnsafeMutableRawPointer) -> Void)?
private nonisolated(unsafe) var surfaceSlot: (UnsafeMutablePointer<UInt>, UInt, UInt)?

private func installSurface<T: View>(_ t: T.Type) -> Bool {
  guard let (w, i) = originalModifiers(T.Body.self), w >= 0, i >= 0,
    w % MemoryLayout<CGFloat?>.alignment == 0, i % MemoryLayout<EdgeInsets?>.alignment == 0,
    w + MemoryLayout<CGFloat?>.size <= MemoryLayout<T.Body>.size,
    i + MemoryLayout<EdgeInsets?>.size <= MemoryLayout<T.Body>.size,
    let req = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s7SwiftUI4ViewP4body4BodyQzvgTq")
  else { return false }
  let slot = witnessTable(t) + 6
  guard isWritableRegion(slot, bytes: MemoryLayout<UInt>.size) else { return false }
  surfaceResult = { native, out in
    surfaceAdjustment.withLock { $0 = (false, 0) }
    let surface = native.assumingMemoryBound(to: T.self).pointee
    guard let context = child(surface, "context"), let cutout = panelCutout(context) else { return }
    let size = cutout.size
    let width = out.advanced(by: w).assumingMemoryBound(to: CGFloat?.self)
    let margins = out.advanced(by: i).assumingMemoryBound(to: EdgeInsets?.self)
    guard let nativeWidth = width.pointee, nativeWidth >= size.width,
      var pad = margins.pointee, pad.top >= size.height
    else { return }
    // Preserve the native root and its DynamicProperty storage. Give the
    // expanded session its actual scene proposal; it lays out its own safe
    // header, so top padding does not have to clear the notch a second time.
    // Advertising an unbounded frame makes this provider lay out against its
    // maximum offer, even while the host displays its smaller preferred size.
    // Like the iPhone layout, the artwork shares the timeline's leading edge:
    // each wing holds the content inset, the artwork and the notch clearance.
    let fallbackArt = max(
      defaultExpandedArtworkWidth, cutout.screen.safeAreaInsets.top + notchClearance)
    let art = wingContentWidth.withLock { $0 } ?? fallbackArt
    let wing = art + notchClearance + max(pad.leading, pad.trailing)
    let originalTop = pad.top
    let reducedTop = min(pad.leading, 4)
    width.pointee = max(nativeWidth, size.width + 2 * wing)
    pad.top = reducedTop
    margins.pointee = pad
    surfaceAdjustment.withLock { $0 = (true, max(0, originalTop - reducedTop)) }
  }
  let discriminator = req.load(as: UInt32.self) >> 16
  let ours = prepareWitnessBody(0, slot, discriminator)
  guard ours != 0 else { return false }
  surfaceSlot = (slot, slot.pointee, ours)
  slot.pointee = ours
  return true
}

@_cdecl("mi_music_enable") public func enableMusic() -> Int32 {
  guard rightBuild(), Bundle.main.bundleIdentifier == "com.apple.MediaRemoteUIService" else {
    return -1
  }
  DispatchQueue.main.async {
    guard let target = _typeByName(sessionMangle) as? any View.Type else {
      musicReadiness.withLock { $0 = -2 }
      return
    }
    if installed != nil {
      musicReadiness.withLock { $0 = 1 }
      return
    }
    guard let surface = _typeByName("12NowPlayingUI0aB15ActivitySurfaceV") as? any View.Type,
      installSurface(surface)
    else {
      musicReadiness.withLock { $0 = -6 }
      return
    }
    let result = install(target)
    if result < 0, let (slot, old, ours) = surfaceSlot, slot.pointee == ours {
      slot.pointee = old
      surfaceSlot = nil
    }
    musicReadiness.withLock { $0 = Int32(result) }
  }
  return 0
}

@_cdecl("mi_music_status") public func musicStatus() -> Int32 {
  musicReadiness.withLock { $0 }
}

@_cdecl("mi_music_surface_result") public func adjustMusicSurface(
  _ native: UnsafeRawPointer, _ out: UnsafeMutableRawPointer
) {
  surfaceResult?(native, out)
}
