import AppKit
import Darwin
import MachO
import SwiftUI

@_silgen_name("mi_store_optional_tag") private func rawStoreOptionalTag(
  _ enumAddr: UnsafeMutableRawPointer, _ whichCase: UInt32, _ wrappedMetadata: UnsafeRawPointer
)

@_silgen_name("mi_get_type_by_mangled_name") private func rawGetTypeByMangledName(
  _ start: UnsafePointer<UInt8>, _ length: Int
) -> UnsafeRawPointer?

private func clockBinaryHostSpecializations() -> [String: Any.Type] {
  var hosts: [String: Any.Type] = [:]
  for imageIndex in 0..<_dyld_image_count() {
    guard let imageName = _dyld_get_image_name(imageIndex),
      String(cString: imageName).hasSuffix("/ClockAngel"),
      let header = _dyld_get_image_header(imageIndex)
    else { continue }
    let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
    var constSize: UInt = 0
    var typerefSize: UInt = 0
    guard
      let constSec = getsectiondata(header64, "__TEXT", "__const", &constSize),
      let typerefSec = getsectiondata(header64, "__TEXT", "__swift5_typeref", &typerefSize)
    else { break }
    let constBase = Int(bitPattern: constSec)
    let typerefStart = Int(bitPattern: typerefSec)
    let typerefEnd = typerefStart + Int(typerefSize)
    var off = 0
    while off + 8 <= Int(constSize) {
      let entry = UnsafeRawPointer(constSec).advanced(by: off)
      let rel = Int(entry.load(as: Int32.self))
      let rawLen = Int(entry.advanced(by: 4).load(as: Int32.self))
      let length = abs(rawLen)
      let target = constBase + off + rel
      if length > 6, length < 512, target >= typerefStart, target + length < typerefEnd,
        let ptr = UnsafePointer<UInt8>(bitPattern: target),
        ptr[length] == 0,
        (ptr[0] == 0x01 || ptr[0] == 0x02),
        ptr[5] == 0x79,
        ptr[length - 1] == 0x47,
        let meta = rawGetTypeByMangledName(ptr, length)
      {
        let resolved = unsafeBitCast(meta, to: Any.Type.self)
        let reflected = String(reflecting: resolved)
        for prefix in [
          "ClockAngel.TimerHost<", "ClockAngel.AlarmHost<", "ClockAngel.StopwatchHost<",
        ] where reflected.hasPrefix(prefix) {
          hosts[prefix] = resolved
        }
      }
      off += 4
    }
    break
  }
  return hosts
}

@_cdecl("mi_clock_self_test") public func clockSelfTest() -> Int32 {
  guard installAllClockPatches() == 1, installAllClockPatches() == 1 else { return -10 }
  guard let types = resolveClockTypes().types else { return -11 }

  let binaryHosts = clockBinaryHostSpecializations()
  guard
    let binTimer = binaryHosts["ClockAngel.TimerHost<"],
    let binAlarm = binaryHosts["ClockAngel.AlarmHost<"],
    let binStopwatch = binaryHosts["ClockAngel.StopwatchHost<"],
    binTimer == (types.timerHost as Any.Type),
    binAlarm == (types.alarmHost as Any.Type),
    binStopwatch == (types.stopwatchHost as Any.Type)
  else { return -12 }

  guard
    let notched = NSScreen.screens.first(where: {
      $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil && $0.safeAreaInsets.top > 0
    }),
    let left = notched.auxiliaryTopLeftArea,
    let right = notched.auxiliaryTopRightArea
  else {
    // Non-notched machine: patch installation succeeded; skip screen-dependent assertion.
    return 1
  }
  let canonicalSize = CGSize(
    width: (right.minX - left.maxX) + 2, height: notched.safeAreaInsets.top + 2)

  func verifyHost(_ viewType: any View.Type, index: UInt32, kind: ClockActivityKind) -> Int32 {
    func open<H: View>(_: H.Type) -> Int32 {
      let hostSize = MemoryLayout<H>.size
      let bodySize = MemoryLayout<H.Body>.size
      guard
        let obs = resolveHostObstructionSpec(H.self, hostSize: hostSize),
        let flex = findHostFlexFrameSpec(H.Body.self, baseOffset: 0, totalSize: bodySize)
      else { return -13 }

      let nativeBuf = UnsafeMutableRawPointer.allocate(
        byteCount: max(hostSize, 16), alignment: 16)
      let outBuf = UnsafeMutableRawPointer.allocate(
        byteCount: max(bodySize, 16), alignment: 16)
      defer {
        nativeBuf.deallocate()
        outBuf.deallocate()
      }
      nativeBuf.initializeMemory(as: UInt8.self, repeating: 0, count: max(hostSize, 16))
      // Non-zero fill ensures pointer/reference extra inhabitants inside H.Body (e.g. LazyState.Storage)
      // do not encode Optional.none before the target _FlexFrameLayout fields are initialized.
      outBuf.initializeMemory(as: UInt8.self, repeating: 1, count: max(bodySize, 16))

      // Mark any Optional payloads in H.Body as .some, and initialize stock maxWidth = 260.
      for optGuard in flex.optionalGuards {
        rawStoreOptionalTag(
          outBuf.advanced(by: optGuard.offset), 0,
          unsafeBitCast(optGuard.wrappedType, to: UnsafeRawPointer.self))
      }
      outBuf.advanced(by: flex.minW).assumingMemoryBound(to: CGFloat?.self).initialize(to: nil)
      outBuf.advanced(by: flex.idealW).assumingMemoryBound(to: CGFloat?.self).initialize(to: nil)
      outBuf.advanced(by: flex.maxW).assumingMemoryBound(to: CGFloat?.self).initialize(to: 260.0)

      // 1. Element scene state: legacy obstructionRect == .zero, integrated obstruction == .some(canonicalSize).
      nativeBuf.storeBytes(of: CGRect.zero, toByteOffset: obs.legacyRectOffset, as: CGRect.self)
      nativeBuf.storeBytes(
        of: CGRect(origin: CGPoint(x: 81, y: 0), size: canonicalSize),
        toByteOffset: obs.integratedRectOffset, as: CGRect.self)
      rawStoreOptionalTag(
        nativeBuf.advanced(by: obs.integratedOptOffset), 0,
        unsafeBitCast(obs.integratedWrappedType, to: UnsafeRawPointer.self))

      adjustClockBody(index, UnsafeRawPointer(nativeBuf), outBuf)

      let expectedWidth = canonicalSize.width + 2 * clockWingSpan
      guard
        let patchedMin = outBuf.advanced(by: flex.minW).assumingMemoryBound(to: CGFloat?.self)
          .pointee,
        let patchedIdeal = outBuf.advanced(by: flex.idealW).assumingMemoryBound(to: CGFloat?.self)
          .pointee,
        let patchedMax = outBuf.advanced(by: flex.maxW).assumingMemoryBound(to: CGFloat?.self)
          .pointee,
        abs(patchedMin - expectedWidth) < 0.001,
        abs(patchedIdeal - expectedWidth) < 0.001,
        abs(patchedMax - expectedWidth) < 0.001,
        clockHostCutoutSizes[kind.rawValue] == canonicalSize
      else { return -14 }

      // 2. Non-notched / detached state: integrated obstruction == .none, legacy == .zero -> stays 260pt and clears cache.
      outBuf.advanced(by: flex.maxW).assumingMemoryBound(to: CGFloat?.self).pointee = 260.0
      rawStoreOptionalTag(
        nativeBuf.advanced(by: obs.integratedOptOffset), 1,
        unsafeBitCast(obs.integratedWrappedType, to: UnsafeRawPointer.self))
      adjustClockBody(index, UnsafeRawPointer(nativeBuf), outBuf)
      guard
        let untouchedMax = outBuf.advanced(by: flex.maxW).assumingMemoryBound(to: CGFloat?.self)
          .pointee,
        abs(untouchedMax - 260.0) < 0.001,
        clockHostCutoutSizes[kind.rawValue] == nil
      else { return -15 }

      return 2
    }
    return open(viewType)
  }

  for (host, idx, kind) in [
    (types.timerHost, UInt32(1), ClockActivityKind.timer),
    (types.alarmHost, UInt32(2), ClockActivityKind.alarm),
    (types.stopwatchHost, UInt32(3), ClockActivityKind.stopwatch),
  ] {
    let rc = verifyHost(host, index: idx, kind: kind)
    if rc != 2 { return rc }
  }
  return 2
}
