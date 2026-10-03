import Combine
import Foundation

/// One imaging rig: scope + camera. Field of view and pixel scale are
/// derived from the optics — never hardcoded — so a reducer or a new
/// camera just changes the inputs.
struct RigPreset: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var focalLengthMM: Double
    var focalRatio: Double
    var sensorWidthMM: Double
    var sensorHeightMM: Double
    var pixelMicrons: Double
    var isBuiltin: Bool

    var fieldWidthDeg: Double {
        2 * atan(sensorWidthMM / 2 / focalLengthMM) * AstroMath.rad2deg
    }
    var fieldHeightDeg: Double {
        2 * atan(sensorHeightMM / 2 / focalLengthMM) * AstroMath.rad2deg
    }
    var pixelScaleArcsecPerPx: Double {
        206.265 * pixelMicrons / focalLengthMM
    }
    /// Half the frame diagonal — worst-case distance from field centre.
    var cornerRadiusDeg: Double {
        hypot(fieldWidthDeg, fieldHeightDeg) / 2
    }

    enum Framing {
        case unknown, small, fits, fills, tight, mosaic
    }

    /// How the target's catalogued size compares to this rig's frame.
    func framing(sizeArcmin: Double?) -> Framing {
        guard let s = sizeArcmin else { return .unknown }
        let d = s / 60.0
        let w = fieldWidthDeg
        if d < 0.30 * w { return .small }
        if d < 0.90 * w { return .fits }
        if d < 1.05 * w { return .fills }
        if d < 1.60 * w { return .tight }
        return .mosaic
    }

    /// Plain-text badge wording, matching the UI badge in the detail view.
    func framingLabel(sizeArcmin: Double?) -> String {
        switch framing(sizeArcmin: sizeArcmin) {
        case .unknown: return "size unknown"
        case .small: return "small in frame"
        case .fits: return "fits with room"
        case .fills: return "fills the frame"
        case .tight: return "tight — consider a mosaic"
        case .mosaic: return "mosaic target"
        }
    }

    var specLine: String {
        String(format: "%.2f° × %.2f° · %.2f″/px · f/%.1f · %.0f mm",
               fieldWidthDeg, fieldHeightDeg,
               pixelScaleArcsecPerPx, focalRatio, focalLengthMM)
    }

    // MARK: - Built-ins (Mathias's actual gear)

    /// Stock Celestron NexStar 6SE (1500 mm f/10) + Canon EOS Rebel T7i
    /// (APS-C 22.3 × 14.9 mm, 3.72 µm pixels) → 0.85° × 0.57°, 0.51″/px.
    static let stock6SE = RigPreset(
        id: "builtin-stock", name: "6SE + T7i (f/10)",
        focalLengthMM: 1500, focalRatio: 10,
        sensorWidthMM: 22.3, sensorHeightMM: 14.9,
        pixelMicrons: 3.72, isBuiltin: true)

    /// Same scope + camera behind a 0.63× f/6.3 reducer: 1500 × 0.63 =
    /// 945 mm. Field and scale below are *derived* by the computed
    /// properties above (≈ 1.35° × 0.90°, ≈ 0.81″/px), not hardcoded.
    static let reducer6SE = RigPreset(
        id: "builtin-reducer", name: "6SE + T7i + f/6.3 reducer",
        focalLengthMM: 945, focalRatio: 6.3,
        sensorWidthMM: 22.3, sensorHeightMM: 14.9,
        pixelMicrons: 3.72, isBuiltin: true)
}

/// The user's rig presets: the two built-ins plus their own customs.
/// Selection and customs persist in UserDefaults.
///
/// Threading: main-thread mutations only (SwiftUI actions) — same
/// deliberate non-@MainActor pattern as the other stores.
final class RigStore: ObservableObject {
    @Published var selectedID: String {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: Self.idKey)
        }
    }
    @Published private(set) var customs: [RigPreset] {
        didSet { saveCustoms() }
    }

    private static let idKey = "AstroTonight.rigPresetID"
    private static let customKey = "AstroTonight.rigPresets"

    init() {
        selectedID = UserDefaults.standard.string(forKey: Self.idKey)
            ?? RigPreset.stock6SE.id
        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let decoded = try? JSONDecoder().decode([RigPreset].self,
                                                   from: data)
        {
            customs = decoded
        } else {
            customs = []
        }
    }

    var presets: [RigPreset] {
        [RigPreset.stock6SE, RigPreset.reducer6SE] + customs
    }

    var selected: RigPreset {
        presets.first { $0.id == selectedID } ?? RigPreset.stock6SE
    }

    var selectedIsCustom: Bool {
        customs.contains { $0.id == selectedID }
    }

    func addCustom(_ preset: RigPreset) {
        customs.append(preset)
        selectedID = preset.id
    }

    func deleteSelectedCustom() {
        customs.removeAll { $0.id == selectedID }
        selectedID = RigPreset.stock6SE.id
    }

    private func saveCustoms() {
        if let data = try? JSONEncoder().encode(customs) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
    }
}
