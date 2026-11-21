import AppKit
import Darwin
import SwiftUI
import os

private let bannerContainerMangle = "14SystemBannerUI24CenterHUDBannerContainerV"
private let bannerReadiness = OSAllocatedUnfairLock<Int32>(initialState: 0)

@_silgen_name("mi_get_type_by_mangled_name")
private func getTypeByMangledName(_ start: UnsafePointer<CChar>, _ len: Int) -> UnsafeRawPointer?

private enum BatteryBannerStyle {
  case charging
  case warning

  var stockWidthRange: ClosedRange<CGFloat> {
    switch self {
    case .charging: return 180.0...240.0
    case .warning: return 260.0...305.0
    }
  }

  var stockHeightRange: ClosedRange<CGFloat> {
    switch self {
    case .charging: return 44.0...56.0
    case .warning: return 54.0...66.0
    }
  }

  var sideSpan: CGFloat {
    switch self {
    case .charging: return 162.0
    case .warning: return 242.0
    }
  }
}

private struct BannerPatchPlan {
  let controllerOffset: Int
  let wrappedControllerOffset: Int
  let resolvedSizeOffset: Int?
  let gestureFeatureEnabled: Bool?
}

private nonisolated(unsafe) var bannerPlan: BannerPatchPlan?
private nonisolated(unsafe) var bannerSlot: (UnsafeMutablePointer<UInt>, UInt, UInt)?
private nonisolated(unsafe) var bannerHandler:
  ((UnsafeRawPointer, UnsafeMutableRawPointer) -> Void)?

private func resolveBannerContainerType() -> (any View.Type)? {
  let path = "/System/Library/PrivateFrameworks/SystemBannerUI.framework/SystemBannerUI"
  guard dlopen(path, RTLD_LAZY) != nil else { return nil }
  let bytes = Array(bannerContainerMangle.utf8CString)
  let raw = bytes.withUnsafeBufferPointer { buf -> UnsafeRawPointer? in
    guard let base = buf.baseAddress else { return nil }
    return getTypeByMangledName(base, bannerContainerMangle.utf8.count)
  }
  guard let raw else { return nil }
  return unsafeBitCast(raw, to: Any.Type.self) as? any View.Type
}

private func resolveGestureContainerGraphEnabled() -> Bool? {
  guard
    let uiCore = dlopen(
      "/System/Library/PrivateFrameworks/SwiftUICore.framework/SwiftUICore", RTLD_LAZY),
    let sym = dlsym(uiCore, "$s7SwiftUI28GestureContainerGraphFeatureV9isEnabledSbvgZ")
  else { return nil }
  let fn = unsafeBitCast(sym, to: (@convention(thin) () -> Bool).self)
  return fn()
}

private func findEnvironmentCGSizeOffset(_ bodyType: Any.Type) -> Int? {
  var current = bodyType
  var base = 0
  for _ in 0..<8 {
    if let mod = fieldInfo(current, "modifier"),
      String(reflecting: mod.1) == "SwiftUI._EnvironmentKeyWritingModifier<__C.CGSize>",
      let val = fieldInfo(mod.1, "value"), val.1 == CGSize.self
    {
      return base + mod.0 + val.0
    }
    guard let next = fieldInfo(current, "content") else { break }
    base += next.0
    current = next.1
  }
  return nil
}

private func readPublishedContentValue(_ publishedValue: Any) -> Any? {
  guard let storage = child(publishedValue, "storage") else { return nil }
  if let direct = child(storage, "value") {
    return direct
  }
  if let pub = child(storage, "publisher"),
    let subject = child(pub, "subject"),
    let current = child(subject, "currentValue")
  {
    return current
  }
  return nil
}

private func unwrapOptionalValue(_ value: Any) -> Any? {
  let mirror = Mirror(reflecting: value)
  guard mirror.displayStyle == .optional else { return value }
  return mirror.children.first?.value
}

private func detectBatteryBannerStyle(fromController controller: AnyObject) -> BatteryBannerStyle? {
  guard let published = child(controller, "_content"),
    let rawOptional = readPublishedContentValue(published),
    let content = unwrapOptionalValue(rawOptional)
  else { return nil }
  guard valueName(content).contains("LowBatterySystemBannerContent") else { return nil }
  guard let style = child(content, "style") else { return nil }
  let desc = String(describing: style)
  if desc.contains("charging") { return .charging }
  if desc.contains("warning") { return .warning }
  return nil
}

private func activeMainDisplayNotch() -> (width: CGFloat, centeredDisplayWidth: CGFloat)? {
  guard let main = NSScreen.main,
    main.safeAreaInsets.top > 0,
    let left = main.auxiliaryTopLeftArea,
    let right = main.auxiliaryTopRightArea
  else { return nil }
  let width = right.minX - left.maxX
  guard width > 0 else { return nil }
  let mid = (left.maxX + right.minX) * 0.5
  let centeredWidth = 2 * min(mid - main.frame.minX, main.frame.maxX - mid)
  guard centeredWidth > 0 else { return nil }
  return (width, centeredWidth)
}

private func readViewAsAny(_ ptr: UnsafeRawPointer, type: Any.Type) -> Any? {
  guard let viewType = type as? any View.Type else { return nil }
  func load<V: View>(_: V.Type) -> Any {
    ptr.assumingMemoryBound(to: V.self).pointee
  }
  return load(viewType)
}

@discardableResult
func widenMatchingFrameLayoutsInMemory(
  _ ptr: UnsafeMutableRawPointer,
  type: Any.Type,
  stockWidth: ClosedRange<CGFloat>,
  stockHeight: ClosedRange<CGFloat>,
  targetWidth: CGFloat,
  gestureFeatureEnabled: Bool?,
  depth: Int = 0
) -> Int {
  guard depth < 24 else { return 0 }
  let reflected = String(reflecting: type)

  if reflected == "SwiftUI._FrameLayout" {
    guard let wf = fieldInfo(type, "width"), wf.1 == CGFloat?.self,
      let hf = fieldInfo(type, "height"), hf.1 == CGFloat?.self
    else { return 0 }
    let wPtr = ptr.advanced(by: wf.0).assumingMemoryBound(to: CGFloat?.self)
    let hPtr = ptr.advanced(by: hf.0).assumingMemoryBound(to: CGFloat?.self)
    guard let w = wPtr.pointee, let h = hPtr.pointee,
      stockWidth.contains(w), stockHeight.contains(h), w < targetWidth
    else { return 0 }
    wPtr.pointee = targetWidth
    return 1
  }

  if reflected == "SwiftUI.AnyView" {
    guard let view = readViewAsAny(ptr, type: AnyView.self),
      let storageObj = child(view, "storage") as AnyObject?,
      let cls = object_getClass(storageObj),
      let ivar = class_getInstanceVariable(cls, "view")
    else { return 0 }
    let ivarOffset = ivar_getOffset(ivar)
    guard ivarOffset > 0, let innerVal = child(storageObj, "view") else { return 0 }
    let innerPtr = Unmanaged.passUnretained(storageObj).toOpaque().advanced(by: ivarOffset)
    return widenMatchingFrameLayoutsInMemory(
      innerPtr, type: Swift.type(of: innerVal),
      stockWidth: stockWidth, stockHeight: stockHeight,
      targetWidth: targetWidth, gestureFeatureEnabled: gestureFeatureEnabled,
      depth: depth + 1)
  }

  if reflected.hasPrefix("SwiftUI.ModifiedContent<") {
    var total = 0
    if let cf = fieldInfo(type, "content") {
      total += widenMatchingFrameLayoutsInMemory(
        ptr.advanced(by: cf.0), type: cf.1,
        stockWidth: stockWidth, stockHeight: stockHeight,
        targetWidth: targetWidth, gestureFeatureEnabled: gestureFeatureEnabled,
        depth: depth + 1)
    }
    if let mf = fieldInfo(type, "modifier") {
      total += widenMatchingFrameLayoutsInMemory(
        ptr.advanced(by: mf.0), type: mf.1,
        stockWidth: stockWidth, stockHeight: stockHeight,
        targetWidth: targetWidth, gestureFeatureEnabled: gestureFeatureEnabled,
        depth: depth + 1)
    }
    return total
  }

  if reflected.hasPrefix("SwiftUI._VariadicView.Tree<") {
    guard let cf = fieldInfo(type, "content") else { return 0 }
    return widenMatchingFrameLayoutsInMemory(
      ptr.advanced(by: cf.0), type: cf.1,
      stockWidth: stockWidth, stockHeight: stockHeight,
      targetWidth: targetWidth, gestureFeatureEnabled: gestureFeatureEnabled,
      depth: depth + 1)
  }

  if reflected.hasPrefix("SwiftUI.StaticIf<") {
    guard let enabled = gestureFeatureEnabled else { return 0 }
    let fieldName = enabled ? "trueBody" : "falseBody"
    guard let bf = fieldInfo(type, fieldName) else { return 0 }
    return widenMatchingFrameLayoutsInMemory(
      ptr.advanced(by: bf.0), type: bf.1,
      stockWidth: stockWidth, stockHeight: stockHeight,
      targetWidth: targetWidth, gestureFeatureEnabled: gestureFeatureEnabled,
      depth: depth + 1)
  }

  if reflected.hasPrefix("Swift.Optional<") {
    let wrappedType = genericTypeArguments(type, count: 1)[0]
    guard isOptionalSome(ptr, wrappedType),
      typeLayoutSize(wrappedType) <= typeLayoutSize(type)
    else { return 0 }
    return widenMatchingFrameLayoutsInMemory(
      ptr, type: wrappedType,
      stockWidth: stockWidth, stockHeight: stockHeight,
      targetWidth: targetWidth, gestureFeatureEnabled: gestureFeatureEnabled,
      depth: depth + 1)
  }

  if reflected.hasPrefix("SwiftUI._ConditionalContent<") {
    guard let val = readViewAsAny(ptr, type: type),
      let storage = child(val, "storage"),
      let active = Mirror(reflecting: storage).children.first
    else { return 0 }
    let args = genericTypeArguments(type, count: 2)
    let activeType: Any.Type
    if active.label == "trueContent" {
      activeType = args[0]
    } else if active.label == "falseContent" {
      activeType = args[1]
    } else {
      return 0
    }
    guard typeLayoutSize(activeType) <= typeLayoutSize(type) else { return 0 }
    return widenMatchingFrameLayoutsInMemory(
      ptr, type: activeType,
      stockWidth: stockWidth, stockHeight: stockHeight,
      targetWidth: targetWidth, gestureFeatureEnabled: gestureFeatureEnabled,
      depth: depth + 1)
  }

  return 0
}

private func prepareBannerHook<V: View>(_ viewType: V.Type) -> Int32 {
  if bannerSlot != nil { return 1 }
  guard let ctrlField = fieldInfo(viewType, "_controller"),
    let wrappedField = fieldInfo(ctrlField.1, "wrappedValue"),
    let req = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s7SwiftUI4ViewP4body4BodyQzvgTq")
  else { return -3 }

  let plan = BannerPatchPlan(
    controllerOffset: ctrlField.0,
    wrappedControllerOffset: wrappedField.0,
    resolvedSizeOffset: findEnvironmentCGSizeOffset(V.Body.self),
    gestureFeatureEnabled: resolveGestureContainerGraphEnabled()
  )
  let slot = witnessTable(viewType) + 6
  guard isWritableRegion(slot, bytes: MemoryLayout<UInt>.size) else { return -4 }

  bannerPlan = plan
  bannerHandler = { selfPtr, resultPtr in
    guard let p = bannerPlan, let notch = activeMainDisplayNotch() else { return }
    let ctrlPtr = selfPtr.advanced(by: p.controllerOffset + p.wrappedControllerOffset)
    guard let controllerObj = ctrlPtr.assumingMemoryBound(to: AnyObject?.self).pointee,
      let style = detectBatteryBannerStyle(fromController: controllerObj)
    else { return }

    let targetWidth = min(notch.width + style.sideSpan, notch.centeredDisplayWidth)
    let wRange = style.stockWidthRange
    let hRange = style.stockHeightRange

    if let sizeOff = p.resolvedSizeOffset,
      sizeOff + MemoryLayout<CGSize>.size <= MemoryLayout<V.Body>.size
    {
      let sizePtr = resultPtr.advanced(by: sizeOff).assumingMemoryBound(to: CGSize.self)
      var currentSize = sizePtr.pointee
      if wRange.contains(currentSize.width), hRange.contains(currentSize.height),
        currentSize.width < targetWidth
      {
        currentSize.width = targetWidth
        sizePtr.pointee = currentSize
      }
    }

    widenMatchingFrameLayoutsInMemory(
      resultPtr, type: V.Body.self,
      stockWidth: wRange, stockHeight: hRange,
      targetWidth: targetWidth, gestureFeatureEnabled: p.gestureFeatureEnabled)
  }

  let discriminator = req.load(as: UInt32.self) >> 16
  let replacement = prepareWitnessBody(7, slot, discriminator)
  guard replacement != 0 else {
    bannerHandler = nil
    return -5
  }
  bannerSlot = (slot, slot.pointee, replacement)
  slot.pointee = replacement
  return 1
}

func installBannerPatches() -> Int32 {
  guard let target = resolveBannerContainerType() else { return -2 }
  func open<V: View>(_ t: V.Type) -> Int32 {
    prepareBannerHook(t)
  }
  return open(target)
}

@_cdecl("mi_banner_enable") public func enableBanner() -> Int32 {
  guard rightBuild(),
    Bundle.main.executablePath
      == "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
  else { return -1 }
  DispatchQueue.main.async {
    let result = installBannerPatches()
    bannerReadiness.withLock { $0 = result }
  }
  return 0
}

@_cdecl("mi_banner_status") public func bannerStatus() -> Int32 {
  bannerReadiness.withLock { $0 }
}

@_cdecl("mi_banner_body_result") public func adjustBannerBody(
  _ native: UnsafeRawPointer, _ out: UnsafeMutableRawPointer
) {
  bannerHandler?(native, out)
}

#if MACISLAND_TESTING
@_cdecl("mi_banner_self_test") public func runBannerSelfTest() -> Int32 {
  let first = installBannerPatches()
  let second = installBannerPatches()
  guard first == 1, second == 1 else { return -1 }

  @ViewBuilder func sampleBanner(charging: Bool, wrapped: Bool) -> some View {
    if wrapped {
      AnyView(Color.black.frame(width: charging ? 220 : 300, height: charging ? 50 : 60))
    } else {
      Color.black.frame(width: 309, height: 60)
    }
  }

  func verifyFrame<V: View>(_ initial: V, style: BatteryBannerStyle, expectedWidth: CGFloat, expectedHits: Int) -> Bool {
    var box = initial
    let count = withUnsafeMutablePointer(to: &box) { ptr -> Int in
      widenMatchingFrameLayoutsInMemory(
        UnsafeMutableRawPointer(ptr),
        type: V.self,
        stockWidth: style.stockWidthRange,
        stockHeight: style.stockHeightRange,
        targetWidth: expectedWidth,
        gestureFeatureEnabled: nil
      )
    }
    return count == expectedHits
  }

  // Charging (220x50 -> 382) and low-battery warning (300x60 -> 462) inside AnyView + ConditionalContent
  guard verifyFrame(sampleBanner(charging: true, wrapped: true), style: .charging, expectedWidth: 382, expectedHits: 1),
    verifyFrame(sampleBanner(charging: false, wrapped: true), style: .warning, expectedWidth: 462, expectedHits: 1),
    // Volume/Brightness HUD (309x60) must never be altered
    verifyFrame(sampleBanner(charging: false, wrapped: false), style: .warning, expectedWidth: 462, expectedHits: 0)
  else {
    return -10
  }

  return 1
}
#endif
