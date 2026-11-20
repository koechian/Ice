//
//  IceBarColorManager.swift
//  Ice
//

import Combine
import SwiftUI

@MainActor
final class IceBarColorManager: ObservableObject {
    @Published private(set) var colorInfo: MenuBarAverageColorInfo?

    private weak var iceBarPanel: IceBarPanel?

    private weak var appState: AppState?

    private var windowImage: CGImage?

    private var cancellables = Set<AnyCancellable>()

    func performSetup(with iceBarPanel: IceBarPanel, appState: AppState) {
        self.iceBarPanel = iceBarPanel
        self.appState = appState
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let iceBarPanel {
            iceBarPanel.publisher(for: \.screen)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak iceBarPanel] screen in
                    guard
                        let self,
                        let iceBarPanel,
                        let screen,
                        iceBarPanel.isVisible,
                        screen == .main
                    else {
                        return
                    }
                    updateWindowImage(for: screen)
                }
                .store(in: &c)

            iceBarPanel.publisher(for: \.isVisible)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak iceBarPanel] isVisible in
                    guard
                        let self,
                        let iceBarPanel,
                        let screen = iceBarPanel.screen,
                        isVisible,
                        screen == .main
                    else {
                        return
                    }
                    updateColorInfo(with: iceBarPanel.frame, screen: screen)
                }
                .store(in: &c)

            iceBarPanel.publisher(for: \.frame)
                .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self, weak iceBarPanel] frame in
                    guard
                        let self,
                        let iceBarPanel,
                        let screen = iceBarPanel.screen,
                        iceBarPanel.isVisible,
                        screen == .main
                    else {
                        return
                    }
                    withAnimation(.interactiveSpring) {
                        self.updateColorInfo(with: frame, screen: screen)
                    }
                }
                .store(in: &c)

            Publishers.Merge4(
                NSWorkspace.shared.notificationCenter
                    .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                    .replace(with: ()),
                NotificationCenter.default
                    .publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .replace(with: ()),
                DistributedNotificationCenter.default()
                    .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
                    .replace(with: ()),
                Timer.publish(every: 5, on: .main, in: .default)
                    .autoconnect()
                    .replace(with: ())
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak iceBarPanel] in
                // Capturing the menu bar is costly, and can stall on macOS 15
                // and later, so only refresh while the Ice Bar is displayed.
                guard
                    let self,
                    let iceBarPanel,
                    let screen = iceBarPanel.screen,
                    iceBarPanel.isVisible,
                    screen == .main
                else {
                    return
                }
                updateWindowImage(for: screen)
                withAnimation {
                    self.updateColorInfo(with: iceBarPanel.frame, screen: screen)
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    private func updateWindowImage(for screen: NSScreen) {
        guard let appState else {
            return
        }
        let method = appState.settings.advanced.menuBarColorMethod
        guard method.producesColor else {
            windowImage = nil
            return
        }
        guard let image = MenuBarColorSampler.menuBarStrip(for: screen, method: method) else {
            return
        }
        windowImage = image
    }

    private func updateColorInfo(with frame: CGRect, screen: NSScreen) {
        guard let image = windowImage else {
            colorInfo = nil
            return
        }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        let insetScreenFrame = screen.frame.insetBy(dx: frame.width / 2, dy: 0)
        let percentage = ((frame.midX - insetScreenFrame.minX) / insetScreenFrame.width).clamped(to: 0...1)

        let cropRect = CGRect(x: imageBounds.width * percentage, y: 0, width: 0, height: 1)
            .insetBy(dx: -150, dy: 0)
            .intersection(imageBounds)

        guard
            let croppedImage = image.cropping(to: cropRect),
            let averageColor = croppedImage.averageColor()
        else {
            return
        }

        // Just use `menuBarWindow` as the source for now, regardless
        // of whether its image contributed to the average.
        colorInfo = MenuBarAverageColorInfo(color: averageColor, source: .menuBarWindow)
    }

    func updateAllProperties(with frame: CGRect, screen: NSScreen) {
        updateWindowImage(for: screen)
        updateColorInfo(with: frame, screen: screen)
    }
}
