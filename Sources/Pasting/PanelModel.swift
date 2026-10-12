import Foundation
import Combine

enum PanelTab: Equatable {
    case history
    case favorites
    case images          // kind == .image
    case pinboard(UUID)
    case app(String)   // bundle id, or "unknown"
}

struct AppStat: Identifiable, Equatable {
    let key: String
    let name: String
    let count: Int
    let latest: Date
    var id: String { key }
}

extension ClipItem {
    var appKey: String { sourceAppBundleID ?? "unknown" }
}

/// UI state shared between the AppKit controller and SwiftUI views.
/// (No @State/@FocusState: this toolchain lacks SwiftUI macro plugins.)
final class PanelModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var pinboards: [Pinboard] = []
    @Published var appStats: [AppStat] = []
    @Published var selectedIndex: Int = 0
    @Published var selectedTab: PanelTab = .history
    @Published var appeared: Bool = false
    @Published var hoveredID: UUID?
    /// Cards animating out (clear) or waiting to animate in (undo).
    @Published var hiddenIDs: Set<UUID> = []
    var staggerReverse = false
    /// Non-nil while the 5 s undo toast is visible (number of cleared items).
    @Published var clearedCount: Int?
    @Published var cardSize: CGFloat = 120

    var selectedItem: ClipItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }
}
