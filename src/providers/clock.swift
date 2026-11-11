import AppKit
import Darwin
import MachO
import SwiftUI
import os

// Pure B안 (Wing-Preserving Dynamic Notch) layout for ClockAngel's three
// stock activities: Timer, Alarm, and Stopwatch.
// Each expanded view stays anchored at y = 0 with 494pt width on a 222pt
// canonical notch (136pt per wing): 84x38pt dual controls in the left wing,
// and vertically centered digits/status in the right wing.
private let clockWingSpan: CGFloat = 136
private let clockOuterMargin: CGFloat = 18
private let clockControlsWidth: CGFloat = 84
private let clockNotchClearance: CGFloat = 12
private let clockStopwatchInnerTrailing: CGFloat = 5
// BaselineRow.placeSubviews selects centeredBaselineY only when topInset > 0.
private let clockCenteredBaselineTopInset: CGFloat = 0.01

private typealias ClockBodyHandler = (UnsafeRawPointer, UnsafeMutableRawPointer) -> Void

private struct ClockPatchSpec {
  let index: UInt32
  let slot: UnsafeMutablePointer<UInt>
  let original: UInt
  let replacement: UInt
  let handler: ClockBodyHandler
}

private let clockReadiness = OSAllocatedUnfairLock<Int32>(initialState: 0)
private nonisolated(unsafe) var clockHandlers: [ClockBodyHandler?] = Array(repeating: nil, count: 7)
private nonisolated(unsafe) var clockInstalledSlots: [(UnsafeMutablePointer<UInt>, UInt, UInt)] = []

private func makeModifiedViewType(
  _ content: any View.Type, _ modifier: any ViewModifier.Type
) -> any View.Type {
  func openContent<C: View>(_: C.Type) -> any View.Type {
    func openModifier<M: ViewModifier>(_: M.Type) -> any View.Type {
      ModifiedContent<C, M>.self
    }
    return openModifier(modifier)
  }
  return openContent(content)
}

private func clockTypeDescriptors() -> [String: UnsafeRawPointer] {
  var found: [String: UnsafeRawPointer] = [:]
  let wanted: Set<String> = [
    "ElementObstructionRectModifier", "TimerHost", "AlarmHost", "StopwatchHost",
  ]
  for imageIndex in 0..<_dyld_image_count() {
    guard let imageName = _dyld_get_image_name(imageIndex),
      String(cString: imageName).hasSuffix("/ClockAngel"),
      let header = _dyld_get_image_header(imageIndex)
    else { continue }
    let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
    var size: UInt = 0
    guard let section = getsectiondata(header64, "__TEXT", "__swift5_types", &size) else {
      continue
    }
    let relOffsets = UnsafeRawPointer(section).assumingMemoryBound(to: Int32.self)
    let count = Int(size) / MemoryLayout<Int32>.size
    for idx in 0..<count {
      let slotAddr = Int(bitPattern: relOffsets + idx)
      guard let desc = UnsafeRawPointer(bitPattern: slotAddr + Int(relOffsets[idx])) else {
        continue
      }
      let nameRel = desc.advanced(by: 8).load(as: Int32.self)
      let namePtr = desc.advanced(by: 8 + Int(nameRel)).assumingMemoryBound(to: CChar.self)
      let name = String(cString: namePtr)
      if wanted.contains(name) {
        found[name] = desc
      }
    }
    break
  }
  return found
}

private func resolveConcreteModifierType(_ desc: UnsafeRawPointer) -> (any ViewModifier.Type)? {
  let flags = desc.load(as: UInt32.self)
  guard (flags & 0x80) == 0 else { return nil }
  let accessRel = desc.advanced(by: 12).load(as: Int32.self)
  guard accessRel != 0,
    let fnPtr = UnsafeRawPointer(bitPattern: Int(bitPattern: desc.advanced(by: 12)) + Int(accessRel))
  else { return nil }
  let meta = callMetadataAccessor(fnPtr, 0)
  return unsafeBitCast(meta, to: Any.Type.self) as? any ViewModifier.Type
}

private func resolveDynamicPath(
  _ root: Any.Type, _ names: [String], baseOffset: Int = 0
) -> (offset: Int, type: Any.Type)? {
  var current = root
  var offset = baseOffset
  for name in names {
    guard let (childOffset, childType) = fieldInfo(current, name) else { return nil }
    offset += childOffset
    current = childType
  }
  return (offset, current)
}

private func findModifiedFlexFrameOffsets(
  _ root: Any.Type, baseOffset: Int, totalSize: Int
) -> (minW: Int, idealW: Int, maxW: Int)? {
  var current = root
  var offset = baseOffset
  while String(reflecting: current).hasPrefix("SwiftUI.ModifiedContent<") {
    guard let contentField = fieldInfo(current, "content"),
      let modField = fieldInfo(current, "modifier")
    else { return nil }
    if modField.1 == _FlexFrameLayout.self {
      let modBase = offset + modField.0
      guard let minField = fieldInfo(modField.1, "minWidth"), minField.1 == CGFloat?.self,
        let idealField = fieldInfo(modField.1, "idealWidth"), idealField.1 == CGFloat?.self,
        let maxField = fieldInfo(modField.1, "maxWidth"), maxField.1 == CGFloat?.self
      else { return nil }
      let minW = modBase + minField.0
      let idealW = modBase + idealField.0
      let maxW = modBase + maxField.0
      let optSize = MemoryLayout<CGFloat?>.size
      let optAlign = MemoryLayout<CGFloat?>.alignment
      guard minW >= 0, idealW >= 0, maxW >= 0,
        minW % optAlign == 0, idealW % optAlign == 0, maxW % optAlign == 0,
        max(minW, idealW, maxW) + optSize <= totalSize
      else { return nil }
      return (minW, idealW, maxW)
    }
    offset += contentField.0
    current = contentField.1
  }
  return nil
}

private func findPaddingFields(
  _ modType: Any.Type, baseOffset: Int, totalSize: Int
) -> (edges: Int, insets: Int)? {
  guard String(reflecting: modType) == "SwiftUI._PaddingLayout",
    let edgesField = fieldInfo(modType, "edges"), edgesField.1 == Edge.Set.self,
    let insetsField = fieldInfo(modType, "insets"), insetsField.1 == EdgeInsets?.self
  else { return nil }
  let edgesOff = baseOffset + edgesField.0
  let insetsOff = baseOffset + insetsField.0
  guard edgesOff >= 0, insetsOff >= 0,
    edgesOff % MemoryLayout<Edge.Set>.alignment == 0,
    insetsOff % MemoryLayout<EdgeInsets?>.alignment == 0,
    edgesOff + MemoryLayout<Edge.Set>.size <= totalSize,
    insetsOff + MemoryLayout<EdgeInsets?>.size <= totalSize
  else { return nil }
  return (edgesOff, insetsOff)
}

private struct OptionalPayloadGuard {
  let offset: Int
  let wrappedType: Any.Type
}

private struct HostFlexFrameSpec {
  let minW: Int
  let idealW: Int
  let maxW: Int
  let optionalGuards: [OptionalPayloadGuard]
}

private func findHostFlexFrameSpec(
  _ type: Any.Type, baseOffset: Int, totalSize: Int
) -> HostFlexFrameSpec? {
  let name = String(reflecting: type)
  if name.hasPrefix("SwiftUI.ModifiedContent<") {
    guard let contentField = fieldInfo(type, "content"),
      let modField = fieldInfo(type, "modifier")
    else { return nil }
    if modField.1 == _FlexFrameLayout.self {
      let modBase = baseOffset + modField.0
      guard let minField = fieldInfo(modField.1, "minWidth"), minField.1 == CGFloat?.self,
        let idealField = fieldInfo(modField.1, "idealWidth"), idealField.1 == CGFloat?.self,
        let maxField = fieldInfo(modField.1, "maxWidth"), maxField.1 == CGFloat?.self
      else { return nil }
      let minW = modBase + minField.0
      let idealW = modBase + idealField.0
      let maxW = modBase + maxField.0
      let optSize = MemoryLayout<CGFloat?>.size
      let optAlign = MemoryLayout<CGFloat?>.alignment
      guard minW >= 0, idealW >= 0, maxW >= 0,
        minW % optAlign == 0, idealW % optAlign == 0, maxW % optAlign == 0,
        max(minW, idealW, maxW) + optSize <= totalSize
      else { return nil }
      return HostFlexFrameSpec(minW: minW, idealW: idealW, maxW: maxW, optionalGuards: [])
    }
    return findHostFlexFrameSpec(
      contentField.1, baseOffset: baseOffset + contentField.0, totalSize: totalSize)
  }
  if name.hasPrefix("Swift.Optional<") {
    let optSize = typeLayoutSize(type)
    let wrapped = genericTypeArguments(type, count: 1)[0]
    let wrappedSize = typeLayoutSize(wrapped)
    guard baseOffset >= 0, optSize >= wrappedSize, baseOffset + optSize <= totalSize,
      let inner = findHostFlexFrameSpec(wrapped, baseOffset: baseOffset, totalSize: totalSize)
    else { return nil }
    let guards = [OptionalPayloadGuard(offset: baseOffset, wrappedType: wrapped)] + inner.optionalGuards
    return HostFlexFrameSpec(
      minW: inner.minW, idealW: inner.idealW, maxW: inner.maxW, optionalGuards: guards)
  }
  if let next = fieldInfo(type, "content") ?? fieldInfo(type, "_tree") {
    return findHostFlexFrameSpec(
      next.1, baseOffset: baseOffset + next.0, totalSize: totalSize)
  }
  return nil
}

private func prepareHostPatch<T: View>(
  _ hostType: T.Type, index: UInt32, discriminator: UInt32
) -> ClockPatchSpec? {
  let hostSize = MemoryLayout<T>.size
  let bodySize = MemoryLayout<T.Body>.size
  guard
    let obsField = resolveDynamicPath(
      T.self, ["content", "modifier", "metrics", "obstructionMetrics", "obstructionRect"]),
    obsField.type == CGRect.self,
    obsField.offset >= 0,
    obsField.offset % MemoryLayout<CGRect>.alignment == 0,
    obsField.offset + MemoryLayout<CGRect>.size <= hostSize,
    let flex = findHostFlexFrameSpec(T.Body.self, baseOffset: 0, totalSize: bodySize)
  else { return nil }

  let slot = witnessTable(hostType) + 6
  guard isWritableRegion(slot, bytes: MemoryLayout<UInt>.size) else { return nil }
  let replacement = prepareWitnessBody(index, slot, discriminator)
  guard replacement != 0 else { return nil }

  let obsOffset = obsField.offset
  let optionalGuards = flex.optionalGuards
  let handler: ClockBodyHandler = { native, out in
    for optGuard in optionalGuards {
      guard isOptionalSome(out.advanced(by: optGuard.offset), optGuard.wrappedType) else { return }
    }
    let obsRect = native.load(fromByteOffset: obsOffset, as: CGRect.self)
    guard cutoutScreen(obsRect.size) != nil else { return }
    let maxPtr = out.advanced(by: flex.maxW).assumingMemoryBound(to: CGFloat?.self)
    guard let currentMax = maxPtr.pointee, abs(currentMax - 260) < 1 else { return }
    let targetWidth = obsRect.width + 2 * clockWingSpan
    out.advanced(by: flex.minW).assumingMemoryBound(to: CGFloat?.self).pointee = targetWidth
    out.advanced(by: flex.idealW).assumingMemoryBound(to: CGFloat?.self).pointee = targetWidth
    maxPtr.pointee = targetWidth
  }
  return ClockPatchSpec(
    index: index, slot: slot, original: slot.pointee, replacement: replacement, handler: handler)
}

private func resolveCutoutGeometry(
  _ native: UnsafeRawPointer, rectEnvOffset: Int, sizeEnvOffset: Int
) -> (notchMaxX: CGFloat, targetWidth: CGFloat)? {
  let rectOpt = native.advanced(by: rectEnvOffset)
    .assumingMemoryBound(to: Environment<CGRect?>.self).pointee.wrappedValue
  let fallbackSize = native.advanced(by: sizeEnvOffset)
    .assumingMemoryBound(to: Environment<CGSize>.self).pointee.wrappedValue
  let size = rectOpt?.size ?? fallbackSize
  guard cutoutScreen(size) != nil else { return nil }
  let targetWidth = size.width + 2 * clockWingSpan
  let centeredMaxX = (targetWidth + size.width) * 0.5
  let notchMaxX = max(rectOpt?.maxX ?? centeredMaxX, centeredMaxX)
  return (notchMaxX, targetWidth)
}

private func prepareTimerExpandedPatch<T: View>(
  _ viewType: T.Type, index: UInt32, discriminator: UInt32
) -> ClockPatchSpec? {
  let bodySize = MemoryLayout<T.Body>.size
  guard
    let obsSizeEnv = nestedFieldOffset(viewType, ["_obstructionSize"], Environment<CGSize>.self),
    let obsEnv = nestedFieldOffset(viewType, ["_obstructionRect"], Environment<CGRect?>.self),
    let outerMod = resolveDynamicPath(T.Body.self, ["content", "modifier"]),
    let pad = findPaddingFields(outerMod.type, baseOffset: outerMod.offset, totalSize: bodySize),
    let spacingField = resolveDynamicPath(
      T.Body.self, ["content", "content", "_tree", "root", "spacing"]),
    spacingField.type == CGFloat?.self,
    spacingField.offset >= 0,
    spacingField.offset + MemoryLayout<CGFloat?>.size <= bodySize,
    let condField = resolveDynamicPath(T.Body.self, ["content", "content", "_tree", "content"]),
    String(reflecting: condField.type).hasPrefix("SwiftUI._ConditionalContent<")
  else { return nil }

  let branches = genericTypeArguments(condField.type, count: 2)
  let condSize = typeLayoutSize(condField.type)
  let payloadSize = max(typeLayoutSize(branches[0]), typeLayoutSize(branches[1]))
  let tagOffset = condField.offset + payloadSize
  guard condSize == payloadSize + 1, tagOffset >= 0, tagOffset + 1 <= bodySize else { return nil }

  // FalseContent (tag == 1) is the active countdown HStack tuple: (Controls, Spacer, BaselineRow).
  let falseBranch = branches[1]
  guard
    let c0 = resolveDynamicPath(falseBranch, ["content", ".0"], baseOffset: condField.offset),
    String(reflecting: c0.type).contains("ClockAngel.TimerControlsView"),
    let spacerMin = resolveDynamicPath(
      falseBranch, ["content", ".1", "minLength"], baseOffset: condField.offset),
    spacerMin.type == CGFloat?.self,
    spacerMin.offset >= 0,
    spacerMin.offset % MemoryLayout<CGFloat?>.alignment == 0,
    spacerMin.offset + MemoryLayout<CGFloat?>.size <= bodySize,
    let c2 = resolveDynamicPath(falseBranch, ["content", ".2"], baseOffset: condField.offset)
  else { return nil }

  var baselineType = c2.type
  var baselineOffset = c2.offset
  while String(reflecting: baselineType).hasPrefix("SwiftUI.ModifiedContent<") {
    guard let next = fieldInfo(baselineType, "content") else { return nil }
    baselineOffset += next.0
    baselineType = next.1
  }
  if String(reflecting: baselineType).hasPrefix("SwiftUI._VariadicView.Tree<"),
    let layout = resolveDynamicPath(baselineType, ["root", "layout"], baseOffset: baselineOffset)
  {
    baselineOffset = layout.offset
    baselineType = layout.type
  }
  guard String(reflecting: baselineType).contains("ClockAngel.BaselineRow"),
    let topField = fieldInfo(baselineType, "topInset"), topField.1 == CGFloat.self,
    let limitField = fieldInfo(baselineType, "trailingLimit"), limitField.1 == CGFloat.self
  else { return nil }
  let topOff = baselineOffset + topField.0
  let limitOff = baselineOffset + limitField.0
  guard topOff >= 0, limitOff >= 0,
    topOff % MemoryLayout<CGFloat>.alignment == 0,
    limitOff % MemoryLayout<CGFloat>.alignment == 0,
    max(topOff, limitOff) + MemoryLayout<CGFloat>.size <= bodySize
  else { return nil }

  let slot = witnessTable(viewType) + 6
  guard isWritableRegion(slot, bytes: MemoryLayout<UInt>.size) else { return nil }
  let replacement = prepareWitnessBody(index, slot, discriminator)
  guard replacement != 0 else { return nil }

  let spacingOff = spacingField.offset
  let spacerOff = spacerMin.offset
  let handler: ClockBodyHandler = { native, out in
    guard
      let geom = resolveCutoutGeometry(
        native, rectEnvOffset: obsEnv, sizeEnvOffset: obsSizeEnv)
    else { return }
    // Keep tag == 0 (alerting/firing ViewThatFits) untouched below the notch.
    guard out.load(fromByteOffset: tagOffset, as: UInt8.self) == 1 else { return }

    let targetWidth = geom.targetWidth
    let notchMaxX = geom.notchMaxX
    let explicitGap = max(
      0, out.advanced(by: spacingOff).assumingMemoryBound(to: CGFloat?.self).pointee ?? 0)
    let minSpacer = max(
      8,
      (notchMaxX + clockNotchClearance) - (clockOuterMargin + clockControlsWidth)
        - 2 * explicitGap)
    let rightWingWidth = max(
      0, targetWidth - clockOuterMargin - (notchMaxX + clockNotchClearance))

    out.advanced(by: pad.edges).assumingMemoryBound(to: Edge.Set.self).pointee = .horizontal
    out.advanced(by: pad.insets).assumingMemoryBound(to: EdgeInsets?.self).pointee = EdgeInsets(
      top: 0, leading: clockOuterMargin, bottom: 0, trailing: clockOuterMargin)
    out.advanced(by: spacerOff).assumingMemoryBound(to: CGFloat?.self).pointee = minSpacer
    out.advanced(by: topOff).assumingMemoryBound(to: CGFloat.self).pointee =
      clockCenteredBaselineTopInset
    out.advanced(by: limitOff).assumingMemoryBound(to: CGFloat.self).pointee = rightWingWidth
  }
  return ClockPatchSpec(
    index: index, slot: slot, original: slot.pointee, replacement: replacement, handler: handler)
}

private func prepareAlarmExpandedPatch<T: View>(
  _ viewType: T.Type, index: UInt32, discriminator: UInt32
) -> ClockPatchSpec? {
  let bodySize = MemoryLayout<T.Body>.size
  guard
    let obsSizeEnv = nestedFieldOffset(viewType, ["_obstructionSize"], Environment<CGSize>.self),
    let obsEnv = nestedFieldOffset(viewType, ["_obstructionRect"], Environment<CGRect?>.self),
    let outerMod = resolveDynamicPath(T.Body.self, ["modifier"]),
    let pad = findPaddingFields(outerMod.type, baseOffset: outerMod.offset, totalSize: bodySize),
    let spacingField = resolveDynamicPath(T.Body.self, ["content", "_tree", "root", "spacing"]),
    spacingField.type == CGFloat?.self,
    spacingField.offset >= 0,
    spacingField.offset + MemoryLayout<CGFloat?>.size <= bodySize,
    let condField = resolveDynamicPath(T.Body.self, ["content", "_tree", "content"]),
    String(reflecting: condField.type).hasPrefix("SwiftUI._ConditionalContent<")
  else { return nil }

  let branches = genericTypeArguments(condField.type, count: 2)
  let condSize = typeLayoutSize(condField.type)
  let payloadSize = max(typeLayoutSize(branches[0]), typeLayoutSize(branches[1]))
  let tagOffset = condField.offset + payloadSize
  guard condSize == payloadSize + 1, tagOffset >= 0, tagOffset + 1 <= bodySize else { return nil }

  // TrueContent (tag == 0) is the snoozed/countdown wing layout: (AlarmControlsView, Spacer, VStack).
  let trueBranch = branches[0]
  guard
    let c0 = resolveDynamicPath(trueBranch, ["content", ".0"], baseOffset: condField.offset),
    String(reflecting: c0.type).contains("ClockAngel.AlarmControlsView"),
    let spacerMin = resolveDynamicPath(
      trueBranch, ["content", ".1", "minLength"], baseOffset: condField.offset),
    spacerMin.type == CGFloat?.self,
    spacerMin.offset >= 0,
    spacerMin.offset % MemoryLayout<CGFloat?>.alignment == 0,
    spacerMin.offset + MemoryLayout<CGFloat?>.size <= bodySize
  else { return nil }

  let slot = witnessTable(viewType) + 6
  guard isWritableRegion(slot, bytes: MemoryLayout<UInt>.size) else { return nil }
  let replacement = prepareWitnessBody(index, slot, discriminator)
  guard replacement != 0 else { return nil }

  let spacingOff = spacingField.offset
  let spacerOff = spacerMin.offset
  let handler: ClockBodyHandler = { native, out in
    guard
      let geom = resolveCutoutGeometry(
        native, rectEnvOffset: obsEnv, sizeEnvOffset: obsSizeEnv)
    else { return }
    // Keep tag == 1 (firing/ringing alarm) untouched.
    guard out.load(fromByteOffset: tagOffset, as: UInt8.self) == 0 else { return }

    let notchMaxX = geom.notchMaxX
    let explicitGap = max(
      0, out.advanced(by: spacingOff).assumingMemoryBound(to: CGFloat?.self).pointee ?? 0)
    let minSpacer = max(
      8,
      (notchMaxX + clockNotchClearance) - (clockOuterMargin + clockControlsWidth)
        - 2 * explicitGap)

    out.advanced(by: pad.edges).assumingMemoryBound(to: Edge.Set.self).pointee = .horizontal
    out.advanced(by: pad.insets).assumingMemoryBound(to: EdgeInsets?.self).pointee = EdgeInsets(
      top: 0, leading: clockOuterMargin, bottom: 0, trailing: clockOuterMargin)
    out.advanced(by: spacerOff).assumingMemoryBound(to: CGFloat?.self).pointee = minSpacer
  }
  return ClockPatchSpec(
    index: index, slot: slot, original: slot.pointee, replacement: replacement, handler: handler)
}

private func prepareStopwatchExpandedPatch<T: View>(
  _ viewType: T.Type, index: UInt32, discriminator: UInt32
) -> ClockPatchSpec? {
  let bodySize = MemoryLayout<T.Body>.size
  guard
    let obsSizeEnv = nestedFieldOffset(viewType, ["_obstructionSize"], Environment<CGSize>.self),
    let obsEnv = nestedFieldOffset(viewType, ["_obstructionRect"], Environment<CGRect?>.self),
    let outerMod = resolveDynamicPath(T.Body.self, ["content", "modifier"]),
    let pad = findPaddingFields(outerMod.type, baseOffset: outerMod.offset, totalSize: bodySize),
    let spacingField = resolveDynamicPath(
      T.Body.self, ["content", "content", "_tree", "root", "spacing"]),
    spacingField.type == CGFloat?.self,
    spacingField.offset >= 0,
    spacingField.offset + MemoryLayout<CGFloat?>.size <= bodySize,
    let tupleRoot = resolveDynamicPath(
      T.Body.self, ["content", "content", "_tree", "content", "content"]),
    let c0 = resolveDynamicPath(tupleRoot.type, [".0"], baseOffset: tupleRoot.offset),
    String(reflecting: c0.type).contains("ClockAngel.StopwatchControlsView"),
    let spacerMin = resolveDynamicPath(
      tupleRoot.type, [".1", "minLength"], baseOffset: tupleRoot.offset),
    spacerMin.type == CGFloat?.self,
    spacerMin.offset >= 0,
    spacerMin.offset % MemoryLayout<CGFloat?>.alignment == 0,
    spacerMin.offset + MemoryLayout<CGFloat?>.size <= bodySize,
    let c2 = resolveDynamicPath(tupleRoot.type, [".2"], baseOffset: tupleRoot.offset),
    let rightFlex = findModifiedFlexFrameOffsets(
      c2.type, baseOffset: c2.offset, totalSize: bodySize)
  else { return nil }

  let slot = witnessTable(viewType) + 6
  guard isWritableRegion(slot, bytes: MemoryLayout<UInt>.size) else { return nil }
  let replacement = prepareWitnessBody(index, slot, discriminator)
  guard replacement != 0 else { return nil }

  let spacingOff = spacingField.offset
  let spacerOff = spacerMin.offset
  let rightMaxWOff = rightFlex.maxW
  let outerTrailing = max(0, clockOuterMargin - clockStopwatchInnerTrailing)
  let handler: ClockBodyHandler = { native, out in
    guard
      let geom = resolveCutoutGeometry(
        native, rectEnvOffset: obsEnv, sizeEnvOffset: obsSizeEnv)
    else { return }

    let targetWidth = geom.targetWidth
    let notchMaxX = geom.notchMaxX
    let explicitGap = max(
      0, out.advanced(by: spacingOff).assumingMemoryBound(to: CGFloat?.self).pointee ?? 0)
    let minSpacer = max(
      8,
      (notchMaxX + clockNotchClearance) - (clockOuterMargin + clockControlsWidth)
        - 2 * explicitGap)
    let rightWingWidth = max(
      0, targetWidth - clockOuterMargin - (notchMaxX + clockNotchClearance))

    out.advanced(by: pad.edges).assumingMemoryBound(to: Edge.Set.self).pointee = .horizontal
    out.advanced(by: pad.insets).assumingMemoryBound(to: EdgeInsets?.self).pointee = EdgeInsets(
      top: 0, leading: clockOuterMargin, bottom: 0, trailing: outerTrailing)
    out.advanced(by: spacerOff).assumingMemoryBound(to: CGFloat?.self).pointee = minSpacer
    let maxWPtr = out.advanced(by: rightMaxWOff).assumingMemoryBound(to: CGFloat?.self)
    maxWPtr.pointee = max(maxWPtr.pointee ?? 0, rightWingWidth)
  }
  return ClockPatchSpec(
    index: index, slot: slot, original: slot.pointee, replacement: replacement, handler: handler)
}

private func installAllClockPatches() -> Int32 {
  if !clockInstalledSlots.isEmpty { return 1 }
  guard
    let timerView = _typeByName("10ClockAngel17TimerExpandedViewV") as? any View.Type,
    let alarmView = _typeByName("10ClockAngel17AlarmExpandedViewV") as? any View.Type,
    let stopwatchView = _typeByName("10ClockAngel21StopwatchExpandedViewV") as? any View.Type
  else { return -2 }

  let descriptors = clockTypeDescriptors()
  guard
    let obsDesc = descriptors["ElementObstructionRectModifier"],
    let timerHostDesc = descriptors["TimerHost"],
    let alarmHostDesc = descriptors["AlarmHost"],
    let stopwatchHostDesc = descriptors["StopwatchHost"],
    let obsModType = resolveConcreteModifierType(obsDesc),
    let req = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s7SwiftUI4ViewP4body4BodyQzvgTq")
  else { return -3 }

  let discriminator = req.load(as: UInt32.self) >> 16

  func instantiateHost(_ hostDesc: UnsafeRawPointer, _ expandedView: any View.Type) -> (any View.Type)? {
    let framed = makeModifiedViewType(expandedView, _FlexFrameLayout.self)
    let fullContent = makeModifiedViewType(framed, obsModType)
    let wt = witnessTable(fullContent)
    let args: [UnsafeRawPointer] = [
      unsafeBitCast(fullContent as Any.Type, to: UnsafeRawPointer.self),
      UnsafeRawPointer(wt),
    ]
    let raw = args.withUnsafeBufferPointer {
      getGenericTypeMetadata(0, UnsafeRawPointer($0.baseAddress!), hostDesc)
    }
    return unsafeBitCast(raw, to: Any.Type.self) as? any View.Type
  }

  guard
    let timerHost = instantiateHost(timerHostDesc, timerView),
    let alarmHost = instantiateHost(alarmHostDesc, alarmView),
    let stopwatchHost = instantiateHost(stopwatchHostDesc, stopwatchView)
  else { return -3 }

  func buildHost(_ v: any View.Type, _ idx: UInt32) -> ClockPatchSpec? {
    func open<V: View>(_ t: V.Type) -> ClockPatchSpec? {
      prepareHostPatch(t, index: idx, discriminator: discriminator)
    }
    return open(v)
  }
  func buildTimer(_ v: any View.Type, _ idx: UInt32) -> ClockPatchSpec? {
    func open<V: View>(_ t: V.Type) -> ClockPatchSpec? {
      prepareTimerExpandedPatch(t, index: idx, discriminator: discriminator)
    }
    return open(v)
  }
  func buildAlarm(_ v: any View.Type, _ idx: UInt32) -> ClockPatchSpec? {
    func open<V: View>(_ t: V.Type) -> ClockPatchSpec? {
      prepareAlarmExpandedPatch(t, index: idx, discriminator: discriminator)
    }
    return open(v)
  }
  func buildStopwatch(_ v: any View.Type, _ idx: UInt32) -> ClockPatchSpec? {
    func open<V: View>(_ t: V.Type) -> ClockPatchSpec? {
      prepareStopwatchExpandedPatch(t, index: idx, discriminator: discriminator)
    }
    return open(v)
  }

  guard
    let p1 = buildHost(timerHost, 1),
    let p2 = buildHost(alarmHost, 2),
    let p3 = buildHost(stopwatchHost, 3),
    let p4 = buildTimer(timerView, 4),
    let p5 = buildAlarm(alarmView, 5),
    let p6 = buildStopwatch(stopwatchView, 6)
  else { return -4 }

  let specs = [p1, p2, p3, p4, p5, p6]
  for spec in specs {
    clockHandlers[Int(spec.index)] = spec.handler
  }
  for spec in specs {
    spec.slot.pointee = spec.replacement
    clockInstalledSlots.append((spec.slot, spec.original, spec.replacement))
  }
  return 1
}

@_cdecl("mi_clock_enable") public func enableClock() -> Int32 {
  guard rightBuild(), Bundle.main.bundleIdentifier == "com.apple.ClockAngel" else { return -1 }
  DispatchQueue.main.async {
    let result = installAllClockPatches()
    clockReadiness.withLock { $0 = result }
  }
  return 0
}

@_cdecl("mi_clock_status") public func clockStatus() -> Int32 {
  clockReadiness.withLock { $0 }
}

@_cdecl("mi_clock_body_result") public func adjustClockBody(
  _ index: UInt32, _ native: UnsafeRawPointer, _ out: UnsafeMutableRawPointer
) {
  guard index >= 1, Int(index) < clockHandlers.count else { return }
  clockHandlers[Int(index)]?(native, out)
}
