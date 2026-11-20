//
//  PlacementRulesSettingsPane.swift
//  Ice
//

import SwiftUI

struct PlacementRulesSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var manager: PlacementRuleManager
    @ObservedObject var itemManager: MenuBarItemManager

    var body: some View {
        IceForm {
            IceSection {
                introduction
            }
            if manager.rules.isEmpty {
                IceSection {
                    Text("No rules yet. Add one for a menu bar item below.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach($manager.rules) { $rule in
                ruleSection(for: $rule)
            }
            IceSection {
                addRuleMenu
            }
        }
    }

    @ViewBuilder
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Move menu bar items between sections automatically.")
                .font(.headline)
            Text(
                """
                Each rule places an item in one section while its condition is met, \
                and in another section while it is not. Rules are applied when the \
                condition changes and when the item's app launches. Items you move \
                by hand stay where you put them until the condition next changes.
                """
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func ruleSection(for rule: Binding<PlacementRule>) -> some View {
        IceSection {
            ruleHeader(for: rule)
        } content: {
            IcePicker("When", selection: rule.condition) {
                ForEach(PlacementCondition.allCases) { condition in
                    Text(condition.localized).tag(condition)
                }
            }
            sectionPicker("Place in", selection: rule.sectionWhenSatisfied)
            sectionPicker("Otherwise place in", selection: rule.sectionOtherwise)
            ruleStatus(for: rule.wrappedValue)
        }
    }

    @ViewBuilder
    private func ruleHeader(for rule: Binding<PlacementRule>) -> some View {
        HStack {
            Toggle(isOn: rule.isEnabled) {
                Text(verbatim: rule.wrappedValue.itemDisplayName)
                    .font(.headline)
            }
            Spacer()
            Button(role: .destructive) {
                manager.removeRule(withID: rule.wrappedValue.id)
            } label: {
                Text("Remove")
            }
        }
    }

    @ViewBuilder
    private func sectionPicker(_ titleKey: LocalizedStringKey, selection: Binding<PlacementRule.Section>) -> some View {
        IcePicker(titleKey, selection: selection) {
            ForEach(availableSections(including: selection.wrappedValue)) { section in
                Text(section.localized).tag(section)
            }
        }
    }

    @ViewBuilder
    private func ruleStatus(for rule: PlacementRule) -> some View {
        let isPresent = itemManager.itemCache.managedItems.contains(where: rule.matches)
        let conditionText = rule.condition.isSatisfied() ? "met" : "not met"
        let target = rule.targetSection().sectionName.displayString.lowercased()
        Group {
            if !rule.isEnabled {
                Text("Disabled.")
            } else if isPresent {
                Text(verbatim: "Condition \(conditionText): the item belongs in the \(target) section.")
            } else {
                Text(verbatim: "Condition \(conditionText). The item isn't in the menu bar; the rule applies when it appears.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var addRuleMenu: some View {
        let items = manager.availableItems()
        Menu {
            ForEach(items, id: \.tag) { item in
                Button {
                    manager.addRule(for: item)
                } label: {
                    Text(verbatim: item.displayName)
                }
            }
        } label: {
            Text("Add Rule for Item")
        }
        .disabled(items.isEmpty)
        .fixedSize()
    }

    /// Returns the sections a picker offers: the enabled sections, plus the
    /// current selection so that a saved choice stays visible.
    private func availableSections(including selection: PlacementRule.Section) -> [PlacementRule.Section] {
        PlacementRule.Section.allCases.filter { section in
            section == selection || appState.menuBarManager.section(withName: section.sectionName)?.isEnabled == true
        }
    }
}
