//
//  PlacementRuleManager.swift
//  Ice
//

import AppKit
import Combine
import OSLog

/// Stores the user's placement rules and moves menu bar items between
/// sections when the rules' conditions change.
///
/// Rules are applied:
/// - shortly after launch,
/// - after the display configuration changes and settles,
/// - when the set of menu bar items changes, for example when an app
///   with a rule launches,
/// - when the rules are edited.
///
/// Applying rules is idempotent: an item already in its target section
/// is left where it is, so the moves this manager makes do not trigger
/// further moves.
@MainActor
final class PlacementRuleManager: ObservableObject {
    /// The user's placement rules.
    @Published var rules = [PlacementRule]()

    /// Delay after launch before rules are first applied.
    private let launchDelay: Duration = .seconds(2)

    /// Delay after a display change, which lets the menu bar settle.
    private let displayChangeDelay: Duration = .seconds(2)

    /// Delay after the menu bar items or the rules change.
    private let itemChangeDelay: Duration = .seconds(1)

    /// The pending or running application of the rules.
    private var applyTask: Task<Void, Never>?

    private weak var appState: AppState?

    private var cancellables = Set<AnyCancellable>()

    private let logger = Logger(category: "PlacementRuleManager")

    /// Sets up the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        loadRules()
        configureCancellables(with: appState)
        scheduleApplication(after: launchDelay)
    }

    private func configureCancellables(with appState: AppState) {
        var c = Set<AnyCancellable>()

        $rules
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] rules in
                guard let self else {
                    return
                }
                saveRules(rules)
                scheduleApplication(after: itemChangeDelay)
            }
            .store(in: &c)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                scheduleApplication(after: displayChangeDelay)
            }
            .store(in: &c)

        appState.itemManager.$itemCache
            .map { Set($0.managedItems.map(\.tag)) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                scheduleApplication(after: itemChangeDelay)
            }
            .store(in: &c)

        cancellables = c
    }

    // MARK: Persistence

    private func loadRules() {
        guard let data = Defaults.data(forKey: .placementRules) else {
            return
        }
        do {
            rules = try JSONDecoder().decode([PlacementRule].self, from: data)
        } catch {
            logger.error("Failed to decode placement rules: \(error, privacy: .public)")
        }
    }

    private func saveRules(_ rules: [PlacementRule]) {
        do {
            let data = try JSONEncoder().encode(rules)
            Defaults.set(data, forKey: .placementRules)
        } catch {
            logger.error("Failed to encode placement rules: \(error, privacy: .public)")
        }
    }

    // MARK: Editing

    /// Adds a rule for the given menu bar item.
    func addRule(for item: MenuBarItem) {
        rules.append(PlacementRule(item: item))
    }

    /// Removes the rule with the given identifier.
    func removeRule(withID id: PlacementRule.ID) {
        rules.removeAll { $0.id == id }
    }

    /// Returns the menu bar items that a new rule can target: movable,
    /// hideable items with a stable identity that no rule targets yet.
    func availableItems() -> [MenuBarItem] {
        guard let appState else {
            return []
        }
        return appState.itemManager.itemCache.managedItems.filter { item in
            PlacementRule.canTarget(item) && !rules.contains { $0.matches(item) }
        }
    }

    // MARK: Applying Rules

    /// Applies the rules after the given delay, replacing any pending
    /// application.
    private func scheduleApplication(after delay: Duration) {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            await self?.applyRules()
        }
    }

    /// Moves each item that is governed by an enabled rule into the
    /// rule's target section.
    private func applyRules() async {
        guard
            let appState,
            rules.contains(where: \.isEnabled)
        else {
            return
        }

        let itemManager = appState.itemManager
        await itemManager.cacheItemsIfNeeded()

        let pendingMoves = rules.compactMap { pendingMove(for: $0, in: itemManager.itemCache) }
        guard !pendingMoves.isEmpty else {
            return
        }

        let currentItems = await MenuBarItem.getMenuBarItems(option: .activeSpace)
        var movedAny = false

        for (item, section) in pendingMoves {
            guard !Task.isCancelled else {
                break
            }
            guard let destination = destination(for: section, in: currentItems, appState: appState) else {
                logger.notice("Cannot place \(item.logString, privacy: .public) in \(section.sectionName.logString, privacy: .public); the section is disabled")
                continue
            }
            do {
                logger.debug("Placing \(item.logString, privacy: .public) in \(section.sectionName.logString, privacy: .public)")
                try await itemManager.move(item: item, to: destination)
                itemManager.removeTemporarilyShownItemFromCache(with: item.tag)
                movedAny = true
            } catch {
                logger.error("Failed to place \(item.logString, privacy: .public): \(error, privacy: .public)")
            }
        }

        if movedAny {
            await itemManager.cacheItemsRegardless()
        }
    }

    /// Returns the item governed by the given rule and the section it
    /// should move to, or `nil` if the item is absent or already placed.
    private func pendingMove(
        for rule: PlacementRule,
        in cache: MenuBarItemManager.ItemCache
    ) -> (MenuBarItem, PlacementRule.Section)? {
        guard
            rule.isEnabled,
            let item = cache.managedItems.first(where: rule.matches),
            let currentSection = cache.address(for: item.tag)?.section
        else {
            return nil
        }
        let target = rule.targetSection()
        return currentSection == target.sectionName ? nil : (item, target)
    }

    /// Returns the move destination that places an item at the edge of the
    /// given section nearest to the section's divider.
    private func destination(
        for section: PlacementRule.Section,
        in items: [MenuBarItem],
        appState: AppState
    ) -> MenuBarItemManager.MoveDestination? {
        switch section {
        case .visible:
            return items.first(matching: .hiddenControlItem).map { .rightOfItem($0) }
        case .hidden:
            return items.first(matching: .hiddenControlItem).map { .leftOfItem($0) }
        case .alwaysHidden:
            guard appState.menuBarManager.section(withName: .alwaysHidden)?.isEnabled == true else {
                return nil
            }
            return items.first(matching: .alwaysHiddenControlItem).map { .leftOfItem($0) }
        }
    }
}
