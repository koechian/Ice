//
//  MenuBarSearchModel.swift
//  Ice
//

import Cocoa
import Combine
import Ifrit

@MainActor
final class MenuBarSearchModel: ObservableObject {
    enum ItemID: Hashable {
        case header(MenuBarSection.Name)
        case item(MenuBarItemTag)
    }

    @Published var searchText = ""
    @Published var displayedItems = [SectionedListItem<ItemID>]()
    @Published var selection: ItemID?
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    private var cancellables = Set<AnyCancellable>()

    private weak var appState: AppState?

    let fuse = Fuse(threshold: 0.5)

    func performSetup(with panel: MenuBarSearchPanel, appState: AppState) {
        self.appState = appState
        configureCancellables(with: panel)
    }

    private func configureCancellables(with panel: MenuBarSearchPanel) {
        var c = Set<AnyCancellable>()

        Publishers.CombineLatest(
            panel.publisher(for: \.screen),
            panel.publisher(for: \.isVisible)
        )
        .compactMap { screen, isVisible in
            isVisible ? screen : nil
        }
        .sink { [weak self] screen in
            self?.updateAverageColorInfo(for: screen)
        }
        .store(in: &c)

        cancellables = c
    }

    private func updateAverageColorInfo(for screen: NSScreen) {
        guard let appState else {
            return
        }

        let method = appState.settings.advanced.menuBarColorMethod
        let info = MenuBarColorSampler.averageColorInfo(for: screen, method: method)

        // Keep the previous color if sampling fails.
        guard info != nil || !method.producesColor else {
            return
        }

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }
}
