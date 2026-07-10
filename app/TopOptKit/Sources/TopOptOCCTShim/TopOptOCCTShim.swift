// TopOptOCCTShim — the always-present anchor of the `TopOptOCCT` product (M7.1b).
//
// The iPad app's Xcode target links the SwiftPM product `TopOptOCCT` to pull in
// the iOS OpenCASCADE (and lib3mf) dynamic-framework xcframeworks so STEP import
// links + embeds on device/simulator. Those xcframeworks are optional — they
// exist only after `scripts/build_occt_ios.sh` has cross-built them — so the
// product needs a target that is ALWAYS present, otherwise the app's product
// dependency would fail to resolve on an OCCT-free checkout. This shim is that
// target: it carries no logic; when the frameworks are present, Package.swift
// adds them to the same product alongside this shim (see the generated
// `iosOCCTFrameworks` list there). Nothing needs to `import` it.
public enum TopOptOCCTShim {}
