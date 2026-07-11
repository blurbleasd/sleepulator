import Metal
import os

/// Runtime availability of the app's `[[stitchable]]` Metal shaders — the diagnostic that keeps a
/// failed shader from becoming a silent black backdrop (visual-moat plan, finding F2).
///
/// SwiftUI gives no shader-failure hook: a `.layerEffect` / `.colorEffect` whose function isn't in
/// the compiled metallib just no-ops (or paints its base) with no trace, so a depth scene whose lens
/// didn't build would show a blank / near-black pane and nobody would know why. This preflights the
/// default library once, logs any required shader that's missing, and lets `DepthBackdrop` fall back
/// to its far-world scaffold instead of a broken effect.
///
/// **Fail-safe by construction.** If the library enumerates *none* of the known-shipping shaders,
/// stitchable-function enumeration isn't giving usable data on this runtime — so we can't tell a real
/// miss from an enumeration gap, and we treat every shader as available (never gate a working effect
/// off). The gate can only ever help; it can never break the working path. That property is the pure
/// `isAvailable(_:in:known:)` below, unit-tested off-device.
enum MetalShaders {
    /// The known-shipping stitchable functions — the sentinel + preflight set. If the library lists
    /// none of these, enumeration doesn't cover stitchables on this runtime (see the type doc). Keep
    /// roughly in sync as scenes are added; a name missing from here only means it isn't preflighted,
    /// never a crash.
    static let known: Set<String> = [
        "auroraField", "embersField", "deepSpaceField", "stillWaterField", "energyField",
        "rainGlassLens", "stillWaterLens",
    ]

    /// The default library's function names (loaded once, lazily). Empty when there's no Metal device.
    private static let names: Set<String> = {
        guard let lib = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary() else { return [] }
        return Set(lib.functionNames)
    }()

    private static let lock = NSLock()
    private static var logged = Set<String>()

    /// Pure decision (unit-tested off-device): treat `name` as available given the library's
    /// `libraryNames` and the sentinel `known` set. Fail-safe: if `libraryNames` lists none of
    /// `known`, enumeration isn't usable here → available (don't gate). Otherwise it's membership.
    static func isAvailable(_ name: String, in libraryNames: Set<String>, known: Set<String>) -> Bool {
        if libraryNames.isDisjoint(with: known) { return true }
        return libraryNames.contains(name)
    }

    /// Is `name` a compiled stitchable function? On the first *confirmed* miss for a name, logs it
    /// once so the failure is visible, not silent. Fail-safe (see the type doc).
    static func available(_ name: String) -> Bool {
        if isAvailable(name, in: names, known: known) { return true }
        lock.lock(); defer { lock.unlock() }
        if !logged.contains(name) {
            logged.insert(name)
            Log.scene.error("Metal shader '\(name, privacy: .public)' not in the default library — scene falls back to its far-world scaffold")
        }
        return false
    }

    /// Launch-time preflight: log every known shader that's missing, at once, so a broken metallib is
    /// obvious in the overnight trail even for the `.colorEffect` scenes (which have no scaffold to
    /// fall back to — they'd otherwise silent-black). No-op when enumeration isn't usable.
    static func preflight() {
        if names.isDisjoint(with: known) { return }   // enumeration gap → nothing trustworthy to report
        let missing = known.filter { !names.contains($0) }.sorted()
        if missing.isEmpty {
            Log.scene.info("Metal shader preflight: all \(known.count) known shaders present")
        } else {
            Log.scene.error("Metal shader preflight: MISSING \(missing.joined(separator: ", "), privacy: .public)")
        }
    }
}
