import AppKit
import Darwin
import SwiftUI

let supportedOSBuild = "26C5035r"

@_silgen_name("mi_call_metadata_accessor") func callMetadataAccessor(
  _ rawFunction: UnsafeRawPointer, _ request: UInt
) -> UnsafeRawPointer

@_silgen_name("mi_get_generic_metadata") func getGenericTypeMetadata(
  _ request: UInt, _ arguments: UnsafeRawPointer, _ descriptor: UnsafeRawPointer
) -> UnsafeRawPointer

@_silgen_name("mi_type_layout_size") func typeLayoutSize(_ type: Any.Type) -> Int

@_silgen_name("mi_is_optional_some") private func rawIsOptionalSome(
  _ enumAddr: UnsafeRawPointer, _ wrappedMetadata: UnsafeRawPointer
) -> Bool

func isOptionalSome(_ enumAddr: UnsafeRawPointer, _ wrappedType: Any.Type) -> Bool {
  rawIsOptionalSome(enumAddr, unsafeBitCast(wrappedType, to: UnsafeRawPointer.self))
}

func genericTypeArguments(_ type: Any.Type, count: Int) -> [Any.Type] {
  let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
  return (0..<count).map { index in
    let arg = metadata.advanced(by: 16 + index * MemoryLayout<UnsafeRawPointer>.size)
      .load(as: UnsafeRawPointer.self)
    return unsafeBitCast(arg, to: Any.Type.self)
  }
}

func child(_ value: Any, _ name: String) -> Any? {
  Mirror(reflecting: value).children.first(where: { $0.label == name })?.value
}

func valueName(_ value: Any) -> String {
  String(reflecting: type(of: value))
}

func anyView(_ value: Any) -> AnyView? {
  guard let v = value as? any View else { return nil }
  return AnyView(v)
}

func stackChildren(_ value: Any) -> [Any]? {
  guard let tree = child(value, "_tree"), let tupleView = child(tree, "content"),
    let tuple = child(tupleView, "content")
  else { return nil }
  let fields = Mirror(reflecting: tuple)
  guard fields.displayStyle == .tuple else { return nil }
  return fields.children.map(\.value)
}

func rightBuild() -> Bool {
  var value = [CChar](repeating: 0, count: 64)
  var size = value.count
  return sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0
    && String(cString: value) == supportedOSBuild
}

func cutoutScreen(_ size: CGSize) -> NSScreen? {
  NSScreen.screens.first { screen in
    guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
      screen.safeAreaInsets.top > 0
    else { return false }
    return abs(right.minX - left.maxX - size.width) <= 4
      && abs(screen.safeAreaInsets.top - size.height) <= 4
  }
}

@_silgen_name("move_signed") func signedEntry(
  _ source: UnsafeMutablePointer<UInt>, _ destination: UnsafeMutablePointer<UInt>,
  _ discriminator: UInt32
) -> UInt

@_silgen_name("mi_prepare_witness_body") func prepareWitnessBody(
  _ index: UInt32, _ slot: UnsafeMutablePointer<UInt>, _ discriminator: UInt32
) -> UInt

func witnessTable(_ t: any View.Type) -> UnsafeMutablePointer<UInt> {
  var t = t
  return withUnsafeBytes(of: &t) {
    $0.load(
      fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UnsafeMutablePointer<UInt>.self)
  }
}

func isWritableRegion(_ p: UnsafeMutablePointer<UInt>, bytes: Int) -> Bool {
  guard bytes > 0 else { return false }
  var a = mach_vm_address_t(UInt(bitPattern: p))
  var size: mach_vm_size_t = 0
  var info = vm_region_basic_info_data_64_t()
  let start = a
  var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / 4)
  var obj = mach_port_t()
  let result = withUnsafeMutablePointer(to: &info) { q in
    q.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      mach_vm_region(mach_task_self_, &a, &size, VM_REGION_BASIC_INFO_64, $0, &count, &obj)
    }
  }
  if obj != 0 { mach_port_deallocate(mach_task_self_, obj) }
  return result == KERN_SUCCESS && info.protection & VM_PROT_WRITE != 0 && a <= start
    && start + mach_vm_address_t(bytes) <= a + size
}

@_silgen_name("swift_reflectionMirror_recursiveCount") private func fieldCount(_ type: Any.Type)
  -> Int
@_silgen_name("swift_reflectionMirror_recursiveChildMetadata") private func fieldType(
  _ t: Any.Type, _ i: Int, _ d: UnsafeMutableRawPointer
) -> Any.Type
@_silgen_name("swift_reflectionMirror_recursiveChildOffset") private func fieldOffset(
  _ t: Any.Type, _ i: Int
) -> Int

// _FieldReflectionMetadata from the Swift runtime's ReflectionMirror interface.
private struct ReflectionFieldMetadata {
  var name: UnsafePointer<CChar>? = nil
  var freeName: (@convention(c) (UnsafePointer<CChar>?) -> Void)? = nil
  var isStrong: Bool = false
  var isVar: Bool = false
}

func fieldInfo(_ type: Any.Type, _ name: String) -> (Int, Any.Type)? {
  for index in 0..<fieldCount(type) {
    var metadata = ReflectionFieldMetadata()
    let field = withUnsafeMutablePointer(to: &metadata) { fieldType(type, index, $0) }
    let matches = metadata.name.map { String(cString: $0) == name } ?? false
    if let free = metadata.freeName { free(metadata.name) }
    if matches { return (fieldOffset(type, index), field) }
  }
  return nil
}

func nestedFieldOffset<Root, Value>(
  _ root: Root.Type, _ names: [String], _ expected: Value.Type
) -> Int? {
  var type: Any.Type = root
  var offset = 0
  for name in names {
    guard let (childOffset, childType) = fieldInfo(type, name) else { return nil }
    offset += childOffset
    type = childType
  }
  guard type == expected, offset >= 0, offset % MemoryLayout<Value>.alignment == 0,
    offset + MemoryLayout<Value>.size <= MemoryLayout<Root>.size
  else { return nil }
  return offset
}
