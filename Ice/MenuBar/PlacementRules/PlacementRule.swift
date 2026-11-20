//
//  PlacementRule.swift
//  Ice
//

import AppKit
import SwiftUI

// MARK: - PlacementRule

/// A rule that places a menu bar item in one section while a condition is
/// satisfied, and in another section while it is not.
struct PlacementRule: Codable, Hashable, Identifiable {
    /// A menu bar section that a rule can place an item in.
    enum Section: String, Codable, CaseIterable, Identifiable {
        case visible
        case hidden
        case alwaysHidden

        var id: String { rawValue }

        /// The corresponding menu bar section name.
        var sectionName: MenuBarSection.Name {
            switch self {
            case .visible: .visible
            case .hidden: .hidden
            case .alwaysHidden: .alwaysHidden
            }
        }

        /// Localized string key representation.
        var localized: LocalizedStringKey {
            sectionName.localized
        }
    }

    /// The identifier of the rule.
    var id = UUID()

    /// A Boolean value that indicates whether the rule is applied.
    var isEnabled = true

    /// The namespace of the item's tag; normally the owning app's bundle
    /// identifier.
    var itemNamespace: String

    /// The title of the item's tag.
    var itemTitle: String

    /// The item's display name when the rule was created, shown while the
    /// item is not in the menu bar.
    var itemDisplayName: String

    /// The condition that selects between the two sections.
    var condition: PlacementCondition

    /// The section for the item while the condition is satisfied.
    var sectionWhenSatisfied: Section

    /// The section for the item while the condition is not satisfied.
    var sectionOtherwise: Section

    /// Creates a rule for the given menu bar item.
    init(
        item: MenuBarItem,
        condition: PlacementCondition = .externalDisplayConnected,
        sectionWhenSatisfied: Section = .visible,
        sectionOtherwise: Section = .hidden
    ) {
        self.itemNamespace = item.tag.namespace.description
        self.itemTitle = item.tag.title
        self.itemDisplayName = item.displayName
        self.condition = condition
        self.sectionWhenSatisfied = sectionWhenSatisfied
        self.sectionOtherwise = sectionOtherwise
    }

    /// Returns a Boolean value that indicates whether the rule applies to
    /// the given menu bar item.
    func matches(_ item: MenuBarItem) -> Bool {
        item.tag.namespace.description == itemNamespace && item.tag.title == itemTitle
    }

    /// Returns the section that the item belongs in under the current
    /// conditions.
    @MainActor
    func targetSection() -> Section {
        condition.isSatisfied() ? sectionWhenSatisfied : sectionOtherwise
    }

    /// Returns a Boolean value that indicates whether rules can identify
    /// the given menu bar item across launches.
    ///
    /// Items whose tag namespace is a UUID or missing get a new identity
    /// when their app relaunches, so a saved rule would stop matching them.
    static func canTarget(_ item: MenuBarItem) -> Bool {
        item.isMovable &&
        item.canBeHidden &&
        !item.tag.isControlItem &&
        item.tag.namespace.isString
    }
}

// MARK: - PlacementCondition

/// A condition that a ``PlacementRule`` evaluates.
enum PlacementCondition: String, Codable, CaseIterable, Identifiable {
    /// At least one display other than the built-in display is connected.
    case externalDisplayConnected

    var id: String { rawValue }

    /// Localized string key representation.
    var localized: LocalizedStringKey {
        switch self {
        case .externalDisplayConnected: "An external display is connected"
        }
    }

    /// Returns a Boolean value that indicates whether the condition is
    /// currently satisfied.
    @MainActor
    func isSatisfied() -> Bool {
        switch self {
        case .externalDisplayConnected:
            NSScreen.screens.contains { CGDisplayIsBuiltin($0.displayID) == 0 }
        }
    }
}
