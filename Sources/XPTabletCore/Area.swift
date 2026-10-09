import Foundation
import CoreGraphics

/// A rectangle in normalised 0...1 space (tablet surface, or a display).
public struct NormalizedRect: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Clamp into 0...1 with a minimum size, keeping the rect inside the surface.
    public func clamped(minimumSize: Double = 0.05) -> NormalizedRect {
        var w = min(max(width, minimumSize), 1)
        var h = min(max(height, minimumSize), 1)
        var x = min(max(self.x, 0), 1 - w)
        var y = min(max(self.y, 0), 1 - h)
        if x < 0 { x = 0; w = min(w, 1) }
        if y < 0 { y = 0; h = min(h, 1) }
        return NormalizedRect(x: x, y: y, width: w, height: h)
    }

    public var isFull: Bool {
        abs(x) < 1e-9 && abs(y) < 1e-9 && abs(width - 1) < 1e-9 && abs(height - 1) < 1e-9
    }

    public static let full = NormalizedRect()

    /// Tolerant decoding: any missing key falls back to the full rect, so a
    /// hand-edited or older config file never fails to load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 1
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 1
    }
}

/// How the active tablet area is projected onto the screen.
public enum MappingMode: String, Codable, CaseIterable {
    /// Fill the target display exactly; X and Y scale independently, so a circle
    /// drawn on the tablet becomes an ellipse if the aspect ratios differ.
    case stretch
    /// Largest rectangle inside the target display that keeps the tablet's aspect
    /// ratio, centred. Round things stay round (the vendor's "screen ratio").
    case fit
    /// Map onto an arbitrary rectangle inside the target display.
    case custom
    /// Treat every active display as one big surface (the vendor's "all screens").
    case allDisplays

    public var label: String {
        switch self {
        case .stretch: return "Fill display (may distort)"
        case .fit: return "Fit, keep proportions"
        case .custom: return "Custom screen area"
        case .allDisplays: return "All displays as one"
        }
    }
}

/// Mapping settings for one display.
///
/// Every display can have its own entry in `WorkspaceConfig.profiles`, so
/// switching the active display switches the whole mapping with it.
public struct DisplayProfile: Codable, Equatable {
    public var mode: MappingMode
    /// Sub-rectangle of the target display, used by `custom`.
    public var screenRect: NormalizedRect
    /// Active region of the tablet itself. Defaults to the whole surface.
    public var tabletRect: NormalizedRect
    /// 0, 90, 180 or 270.
    public var rotation: Int
    public var invertX: Bool
    public var invertY: Bool

    public init(
        mode: MappingMode = .stretch,
        screenRect: NormalizedRect = .full,
        tabletRect: NormalizedRect = .full,
        rotation: Int = 0,
        invertX: Bool = false,
        invertY: Bool = false
    ) {
        self.mode = mode
        self.screenRect = screenRect
        self.tabletRect = tabletRect
        self.rotation = rotation
        self.invertX = invertX
        self.invertY = invertY
    }

    public var isDefault: Bool { self == DisplayProfile() }

    /// Tolerant decoding so adding keys later cannot break existing config files.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(MappingMode.self, forKey: .mode) ?? .stretch
        screenRect = try container.decodeIfPresent(NormalizedRect.self, forKey: .screenRect) ?? .full
        tabletRect = try container.decodeIfPresent(NormalizedRect.self, forKey: .tabletRect) ?? .full
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        invertX = try container.decodeIfPresent(Bool.self, forKey: .invertX) ?? false
        invertY = try container.decodeIfPresent(Bool.self, forKey: .invertY) ?? false
    }
}

/// The complete tablet → screen mapping.
///
/// Displays are identified by their **`CGDirectDisplayID`**, not by their position
/// in the active-display list. Indices shift when a display is added, removed or
/// reordered, which would silently move everyone's settings onto the wrong
/// monitor; a display ID is stable for as long as that display is connected.
///
/// Older config files keyed by index ("0", "1") still load: `normalize(displays:)`
/// rewrites them to IDs once the real display list is known.
public struct WorkspaceConfig: Codable, Equatable {
    /// The targeted display, by `CGDirectDisplayID`.
    public var displayID: UInt32?
    /// Legacy index-based target, migrated by `normalize(displays:)`.
    public var display: Int?
    /// Displays the Switch action cycles, by ID. Empty = every active display.
    public var switchDisplayIDs: [UInt32]
    /// Legacy index-based switch list, migrated by `normalize(displays:)`.
    public var switchDisplays: [Int]
    /// Per-display settings, keyed by display ID as a decimal string.
    public var profiles: [String: DisplayProfile]

    /// Shared defaults, used by any display without its own profile.
    public var mode: MappingMode
    public var screenRect: NormalizedRect
    public var tabletRect: NormalizedRect
    public var rotation: Int
    public var invertX: Bool
    public var invertY: Bool

    public init(
        displayID: UInt32? = nil,
        display: Int? = nil,
        switchDisplayIDs: [UInt32] = [],
        switchDisplays: [Int] = [],
        profiles: [String: DisplayProfile] = [:],
        mode: MappingMode = .stretch,
        screenRect: NormalizedRect = .full,
        tabletRect: NormalizedRect = .full,
        rotation: Int = 0,
        invertX: Bool = false,
        invertY: Bool = false
    ) {
        self.displayID = displayID
        self.display = display
        self.switchDisplayIDs = switchDisplayIDs
        self.switchDisplays = switchDisplays
        self.profiles = profiles
        self.mode = mode
        self.screenRect = screenRect
        self.tabletRect = tabletRect
        self.rotation = rotation
        self.invertX = invertX
        self.invertY = invertY
    }

    // MARK: - Resolution against a live display list

    /// The display being targeted. Falls back to the first active display when the
    /// stored one is gone (unplugged, or the config came from another machine).
    public func resolvedDisplayID(_ displays: [AreaMapper.DisplayBounds]) -> UInt32? {
        if let id = displayID, displays.contains(where: { $0.displayID == id }) { return id }
        if let index = display, displays.indices.contains(index) { return displays[index].displayID }
        return displays.first?.displayID
    }

    public func targetIndex(_ displays: [AreaMapper.DisplayBounds]) -> Int {
        guard let id = resolvedDisplayID(displays) else { return 0 }
        return displays.firstIndex { $0.displayID == id } ?? 0
    }

    /// Rewrite legacy index keys to display IDs and drop the now-redundant indices.
    /// Idempotent, and safe to call whenever the display list changes.
    public func normalize(_ displays: [AreaMapper.DisplayBounds]) -> WorkspaceConfig {
        guard !displays.isEmpty else { return self }
        var result = self

        // Target display: index -> ID
        if let index = result.display {
            if result.displayID == nil, displays.indices.contains(index) {
                result.displayID = displays[index].displayID
            }
            result.display = nil
        } else if let id = result.displayID, !displays.contains(where: { $0.displayID == id }) {
            result.displayID = displays.first?.displayID
        }

        // Switch list: indices -> IDs. An empty list means "all", keep it empty.
        if !result.switchDisplays.isEmpty {
            let mapped = result.switchDisplays.compactMap { index -> UInt32? in
                displays.indices.contains(index) ? displays[index].displayID : nil
            }
            result.switchDisplayIDs = Array(Set(result.switchDisplayIDs + mapped)).sorted()
            result.switchDisplays = []
        }
        // Drop switch entries whose display is no longer connected.
        let live = Set(displays.map(\.displayID))
        result.switchDisplayIDs = result.switchDisplayIDs.filter { live.contains($0) }

        // Profiles. A config that has no `displayID` yet predates display-ID keying,
        // so its keys are indices — re-key them by index. Otherwise the keys are
        // IDs, and any key that is not a live display is stale and dropped, so it
        // cannot resurface on an unrelated monitor later.
        //
        // The distinction matters: an index such as "1" can also parse as a number,
        // so "does this key look like a display ID?" is not a safe test on its own.
        let keysAreIndices = (displayID == nil && display != nil) || !switchDisplays.isEmpty
        var rewritten: [String: DisplayProfile] = [:]
        for (key, profile) in result.profiles {
            if keysAreIndices {
                if let index = Int(key), displays.indices.contains(index) {
                    let newKey = String(displays[index].displayID)
                    if rewritten[newKey] == nil { rewritten[newKey] = profile }
                }
            } else if let id = UInt32(key), live.contains(id) {
                rewritten[key] = profile
            }
        }
        result.profiles = rewritten
        return result
    }

    // MARK: - Profiles

    public func profile(forDisplayID id: UInt32) -> DisplayProfile {
        profiles[String(id)] ?? DisplayProfile(
            mode: mode, screenRect: screenRect, tabletRect: tabletRect,
            rotation: rotation, invertX: invertX, invertY: invertY)
    }

    public func profile(for displays: [AreaMapper.DisplayBounds]) -> DisplayProfile {
        guard let id = resolvedDisplayID(displays) else { return DisplayProfile() }
        return profile(forDisplayID: id)
    }

    public mutating func setProfile(_ profile: DisplayProfile, forDisplayID id: UInt32) {
        profiles[String(id)] = profile
    }

    public mutating func updateProfile(forDisplayID id: UInt32, _ change: (inout DisplayProfile) -> Void) {
        var profile = profile(forDisplayID: id)
        change(&profile)
        setProfile(profile, forDisplayID: id)
    }

    /// Update the profile of whichever display is currently targeted.
    public mutating func updateCurrentProfile(_ displays: [AreaMapper.DisplayBounds],
                                              _ change: (inout DisplayProfile) -> Void) {
        guard let id = resolvedDisplayID(displays) else { return }
        updateProfile(forDisplayID: id, change)
    }

    public func hasProfile(forDisplayID id: UInt32) -> Bool {
        profiles[String(id)] != nil
    }

    public func hasProfile(for displays: [AreaMapper.DisplayBounds]) -> Bool {
        guard let id = resolvedDisplayID(displays) else { return false }
        return hasProfile(forDisplayID: id)
    }

    public mutating func removeProfile(forDisplayID id: UInt32) {
        profiles.removeValue(forKey: String(id))
    }

    // MARK: - Switching

    /// Display IDs the Switch action cycles. Empty means every active display.
    public func switchOrder(_ displays: [AreaMapper.DisplayBounds]) -> [UInt32] {
        let live = displays.map(\.displayID)
        let configured = switchDisplayIDs.filter { live.contains($0) }
        return configured.isEmpty ? live : configured
    }

    /// The next display after the current one, wrapping around.
    public func nextDisplayID(_ displays: [AreaMapper.DisplayBounds]) -> UInt32? {
        let order = switchOrder(displays)
        guard !order.isEmpty else { return nil }
        guard let current = resolvedDisplayID(displays),
              let position = order.firstIndex(of: current) else { return order[0] }
        return order[(position + 1) % order.count]
    }

    /// Tolerant decoding. Every key is optional so an older or hand-edited file
    /// loads and simply contributes fallback values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try container.decodeIfPresent(UInt32.self, forKey: .displayID)
        display = try container.decodeIfPresent(Int.self, forKey: .display)
        switchDisplayIDs = try container.decodeIfPresent([UInt32].self, forKey: .switchDisplayIDs) ?? []
        switchDisplays = try container.decodeIfPresent([Int].self, forKey: .switchDisplays) ?? []
        profiles = try container.decodeIfPresent([String: DisplayProfile].self, forKey: .profiles) ?? [:]
        mode = try container.decodeIfPresent(MappingMode.self, forKey: .mode) ?? .stretch
        screenRect = try container.decodeIfPresent(NormalizedRect.self, forKey: .screenRect) ?? .full
        tabletRect = try container.decodeIfPresent(NormalizedRect.self, forKey: .tabletRect) ?? .full
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        invertX = try container.decodeIfPresent(Bool.self, forKey: .invertX) ?? false
        invertY = try container.decodeIfPresent(Bool.self, forKey: .invertY) ?? false
    }
}

/// Maps raw tablet coordinates onto the screen according to a `WorkspaceConfig`.
///
/// The shape of the transform matches the vendor's
/// `CEventPort::TabletPointToScreenPoint` (0x100014a5e):
///
///     screen = targetRect.origin + (raw − activeMin) ÷ activeExtent × targetRect.size
public struct AreaMapper {

    public struct DisplayBounds: Equatable {
        public let originX: Double
        public let originY: Double
        public let width: Double
        public let height: Double
        public let displayID: CGDirectDisplayID

        public init(originX: Double, originY: Double, width: Double, height: Double, displayID: CGDirectDisplayID) {
            self.originX = originX
            self.originY = originY
            self.width = width
            self.height = height
            self.displayID = displayID
        }

        public var rect: CGRect {
            CGRect(x: originX, y: originY, width: width, height: height)
        }

        public static func main() -> DisplayBounds {
            bounds(for: CGMainDisplayID())
        }

        public static func bounds(for id: CGDirectDisplayID) -> DisplayBounds {
            let b = CGDisplayBounds(id)
            return DisplayBounds(originX: Double(b.origin.x), originY: Double(b.origin.y),
                                 width: Double(b.size.width), height: Double(b.size.height),
                                 displayID: id)
        }

        public static func activeDisplays() -> [DisplayBounds] {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
            return Array(ids.prefix(Int(count))).map { bounds(for: $0) }
        }
    }

    public let workspace: WorkspaceConfig
    public let displays: [DisplayBounds]
    public let maxX: UInt32
    public let maxY: UInt32
    public let tabletAspect: Double

    public init(workspace: WorkspaceConfig,
                displays: [DisplayBounds],
                maxX: UInt32 = Device.maxX,
                maxY: UInt32 = Device.maxY,
                tabletAspect: Double = Device.activeWidthMM / Device.activeHeightMM) {
        self.workspace = workspace
        self.displays = displays.isEmpty ? [.main()] : displays
        self.maxX = max(maxX, 1)
        self.maxY = max(maxY, 1)
        self.tabletAspect = tabletAspect
    }

    /// Index of the targeted display within `displays`.
    public var targetIndex: Int { workspace.targetIndex(displays) }

    /// The targeted display.
    public var targetDisplay: DisplayBounds { displays[min(targetIndex, displays.count - 1)] }

    /// Settings in force for the targeted display.
    public var profile: DisplayProfile { workspace.profile(for: displays) }

    /// The rectangle all displays together occupy, in global coordinates.
    public var unionRect: CGRect {
        displays.dropFirst().reduce(displays[0].rect) { $0.union($1.rect) }
    }

    /// The screen rectangle the tablet area is projected onto, in global
    /// coordinates. This is what the UI draws.
    public var targetRect: CGRect {
        let profile = self.profile
        let base: CGRect
        switch profile.mode {
        case .allDisplays:
            base = unionRect
        case .stretch, .fit, .custom:
            base = targetDisplay.rect
        }

        switch profile.mode {
        case .custom:
            return CGRect(
                x: base.origin.x + profile.screenRect.x * base.width,
                y: base.origin.y + profile.screenRect.y * base.height,
                width: profile.screenRect.width * base.width,
                height: profile.screenRect.height * base.height
            )
        case .fit:
            // Letterbox: largest rect with the tablet's aspect ratio, centred.
            let aspect = rawAspectRatio
            var width = base.width
            var height = width / aspect
            if height > base.height {
                height = base.height
                width = height * aspect
            }
            return CGRect(x: base.origin.x + (base.width - width) / 2,
                          y: base.origin.y + (base.height - height) / 2,
                          width: width, height: height)
        case .stretch, .allDisplays:
            return base
        }
    }

    /// Aspect ratio of the source area after rotation.
    private var rawAspectRatio: Double {
        let profile = self.profile
        var aspect = tabletAspect * (profile.tabletRect.width / max(profile.tabletRect.height, 1e-9))
        if profile.rotation == 90 || profile.rotation == 270 { aspect = 1 / aspect }
        return aspect
    }

    /// Convert one raw tablet coordinate to a global screen point.
    public func map(x: UInt32, y: UInt32) -> CGPoint {
        let profile = self.profile
        let tablet = profile.tabletRect.clamped(minimumSize: 0.0001)
        var nx = Double(x) / Double(maxX)
        var ny = Double(y) / Double(maxY)

        // Restrict to the active tablet area.
        nx = (nx - tablet.x) / tablet.width
        ny = (ny - tablet.y) / tablet.height

        if profile.invertX { nx = 1 - nx }
        if profile.invertY { ny = 1 - ny }

        // Rotate the source before projecting.
        switch profile.rotation {
        case 90: (nx, ny) = (ny, 1 - nx)
        case 180: nx = 1 - nx; ny = 1 - ny
        case 270: (nx, ny) = (1 - ny, nx)
        default: break
        }

        nx = min(max(nx, 0), 1)
        ny = min(max(ny, 0), 1)

        let rect = targetRect
        return CGPoint(x: rect.origin.x + nx * rect.width,
                       y: rect.origin.y + ny * rect.height)
    }
}
