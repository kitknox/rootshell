//
//  InputSourceCarbonShim.swift
//  rootshell
//
//  Hand-rolled Carbon HIToolbox bindings for Text Input Sources (TIS).
//
//  We can't `import Carbon.HIToolbox` directly: in this Xcode 26.x / macOS
//  26.x SDK combo, the Carbon umbrella header drags in stale subframework
//  headers (CommonPanels' CMCalibrator, SecurityHI's KeychainHI) whose
//  types are undefined on Mac Catalyst, so the module fails to precompile.
//
//  The TIS functions we need are stable C entry points in HIToolbox.framework
//  — perfectly callable from Catalyst once Carbon is linked at the linker
//  level (see xcconfig OTHER_LDFLAGS). The CFString property-key constants
//  are loaded at runtime via dlsym to avoid having to know their string
//  values, which aren't part of the public contract.
//
//  See VisorCarbonShim.swift for the same pattern applied to RegisterEventHotKey.
//

#if targetEnvironment(macCatalyst)

import Foundation
import CoreFoundation
import Darwin

// TIS input sources are CFType-backed. Treat the opaque reference as a
// CFTypeRef so Swift bridges retain/release semantics correctly.
typealias TISInputSourceRef = CFTypeRef

@_silgen_name("TISCopyInputSourceForLanguage")
func TISCopyInputSourceForLanguage(_ language: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("TISCopyCurrentKeyboardInputSource")
func TISCopyCurrentKeyboardInputSource() -> Unmanaged<CFTypeRef>?

@_silgen_name("TISCreateInputSourceList")
func TISCreateInputSourceList(
    _ properties: CFDictionary?,
    _ includeAllInstalled: Bool
) -> Unmanaged<CFArray>?

@_silgen_name("TISGetInputSourceProperty")
func TISGetInputSourceProperty(
    _ inputSource: TISInputSourceRef,
    _ propertyKey: CFString
) -> UnsafeMutableRawPointer?

@_silgen_name("TISSelectInputSource")
func TISSelectInputSource(_ inputSource: TISInputSourceRef) -> OSStatus

// MARK: - Property-key constants (resolved at runtime via dlsym)

/// Look up a `CFStringRef` constant exported from HIToolbox. dlsym returns
/// a pointer *to* the variable; we then load the CFString reference stored
/// at that address. `RTLD_DEFAULT` searches all loaded images, which is
/// fine because Carbon is linked at link time.
private func loadTISStringConstant(_ name: String) -> CFString? {
    let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(RTLD_DEFAULT, name) else { return nil }
    let raw = symbol.load(as: UnsafeRawPointer.self)
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
}

let kTISPropertyInputSourceID: CFString =
    loadTISStringConstant("kTISPropertyInputSourceID") ?? ("TISPropertyInputSourceID" as CFString)

let kTISPropertyInputSourceLanguages: CFString =
    loadTISStringConstant("kTISPropertyInputSourceLanguages") ?? ("TISPropertyInputSourceLanguages" as CFString)

let kTISPropertyInputSourceIsSelectCapable: CFString =
    loadTISStringConstant("kTISPropertyInputSourceIsSelectCapable") ?? ("TISPropertyInputSourceIsSelectCapable" as CFString)

let kTISPropertyInputSourceIsEnabled: CFString =
    loadTISStringConstant("kTISPropertyInputSourceIsEnabled") ?? ("TISPropertyInputSourceIsEnabled" as CFString)

let kTISPropertyInputSourceCategory: CFString =
    loadTISStringConstant("kTISPropertyInputSourceCategory") ?? ("TISPropertyInputSourceCategory" as CFString)

let kTISCategoryKeyboardInputSource: CFString =
    loadTISStringConstant("kTISCategoryKeyboardInputSource") ?? ("TISCategoryKeyboardInputSource" as CFString)

let kTISPropertyLocalizedName: CFString =
    loadTISStringConstant("kTISPropertyLocalizedName") ?? ("TISPropertyLocalizedName" as CFString)

let kTISPropertyInputSourceType: CFString =
    loadTISStringConstant("kTISPropertyInputSourceType") ?? ("TISPropertyInputSourceType" as CFString)

let kTISTypeKeyboardLayout: CFString =
    loadTISStringConstant("kTISTypeKeyboardLayout") ?? ("TISTypeKeyboardLayout" as CFString)

#endif
