//
//  MenuBarColorSampler.swift
//  Ice
//

import AppKit
import ImageIO
import OSLog
import SwiftUI

// MARK: - MenuBarColorMethod

/// The method that Ice uses to match its menu bar styled views, such as
/// the Ice Bar and the search panel, to the appearance of the menu bar.
enum MenuBarColorMethod: Int, CaseIterable, Identifiable {
    /// Capture the menu bar and wallpaper windows from the screen.
    ///
    /// This method reflects a tinted menu bar, but each capture goes through
    /// the system screen capture service, which can stall.
    case screenCapture = 0

    /// Draw the views with the system's translucent material, and let the
    /// window server blend them with the content behind them.
    case systemMaterial = 1

    /// Sample the desktop wallpaper image file that lies under the menu bar.
    /// This is the default.
    case wallpaperImage = 2

    var id: Int { rawValue }

    /// Localized string key representation.
    var localized: LocalizedStringKey {
        switch self {
        case .screenCapture: "Screen capture"
        case .systemMaterial: "System material"
        case .wallpaperImage: "Wallpaper image"
        }
    }

    /// A Boolean value that indicates whether the method produces an
    /// average color.
    var producesColor: Bool {
        self != .systemMaterial
    }
}

// MARK: - MenuBarColorSampler

/// Produces images of the area under the menu bar, using the configured
/// ``MenuBarColorMethod``.
@MainActor
enum MenuBarColorSampler {
    /// Returns an image, one pixel tall and spanning the width of the screen,
    /// that represents the colors of the menu bar on the given screen.
    ///
    /// Returns `nil` for ``MenuBarColorMethod/systemMaterial``, which does not
    /// compute a color.
    static func menuBarStrip(for screen: NSScreen, method: MenuBarColorMethod) -> CGImage? {
        switch method {
        case .screenCapture:
            capturedMenuBarStrip(for: screen)
        case .systemMaterial:
            nil
        case .wallpaperImage:
            WallpaperImageRenderer.shared.menuBarStrip(for: screen)
        }
    }

    /// Returns the average color of the menu bar on the given screen.
    static func averageColorInfo(for screen: NSScreen, method: MenuBarColorMethod) -> MenuBarAverageColorInfo? {
        guard
            let image = menuBarStrip(for: screen, method: method),
            let color = image.averageColor(option: .ignoreAlpha)
        else {
            return nil
        }
        let source: MenuBarAverageColorInfo.Source = method == .wallpaperImage ? .desktopWallpaper : .menuBarWindow
        return MenuBarAverageColorInfo(color: color, source: source)
    }

    /// Returns an image of the desktop wallpaper under the menu bar of the
    /// given screen, read from the wallpaper file, at the screen's backing
    /// scale.
    static func wallpaperUnderMenuBar(for screen: NSScreen) -> CGImage? {
        WallpaperImageRenderer.shared.wallpaperUnderMenuBar(for: screen)
    }

    /// Captures the menu bar and wallpaper windows from the screen and
    /// returns a strip one pixel tall.
    private static func capturedMenuBarStrip(for screen: NSScreen) -> CGImage? {
        let windows = WindowInfo.createWindows(option: .onScreen)
        let displayID = screen.displayID
        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            return nil
        }
        return ScreenCapture.captureWindows(
            with: [menuBarWindow.windowID, wallpaperWindow.windowID],
            screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
            option: .nominalResolution
        )
    }
}

// MARK: - WallpaperImageRenderer

/// Renders the part of the desktop wallpaper that lies under the menu bar,
/// directly from the wallpaper image file.
///
/// Reading the file avoids the system screen capture service entirely. The
/// rendered images are cached until the wallpaper, its placement options,
/// or the screen geometry change.
///
/// Limitations: only the first image of a dynamic (multi-image) wallpaper is
/// used, and moving (Aerial) wallpapers are represented by their still image.
@MainActor
private final class WallpaperImageRenderer {
    /// The inputs that determine a rendered image.
    private struct RenderKey: Hashable {
        let url: URL
        let modificationDate: Date?
        let placement: Placement
        let fillColor: CGColor?
        let screenFrame: CGRect
        let menuBarHeight: CGFloat
        let scale: CGFloat
    }

    /// How the wallpaper is placed on the screen.
    private enum Placement: Hashable {
        case fill
        case fit
        case stretch
        case center
    }

    /// The rendered images for a single screen.
    private struct RenderedImages {
        let key: RenderKey
        let region: CGImage
        let strip: CGImage
    }

    static let shared = WallpaperImageRenderer()

    /// The maximum pixel dimension used when decoding the wallpaper file.
    private let decodeMaxPixelSize = 4096

    private var cache = [CGDirectDisplayID: RenderedImages]()

    private let logger = Logger(category: "WallpaperImageRenderer")

    func menuBarStrip(for screen: NSScreen) -> CGImage? {
        renderedImages(for: screen)?.strip
    }

    func wallpaperUnderMenuBar(for screen: NSScreen) -> CGImage? {
        renderedImages(for: screen)?.region
    }

    private func renderedImages(for screen: NSScreen) -> RenderedImages? {
        guard let key = renderKey(for: screen) else {
            return nil
        }
        if let cached = cache[screen.displayID], cached.key == key {
            return cached
        }
        guard let rendered = render(key) else {
            logger.error("Failed to render wallpaper image from \(key.url.lastPathComponent, privacy: .public)")
            return nil
        }
        cache[screen.displayID] = rendered
        return rendered
    }

    private func renderKey(for screen: NSScreen) -> RenderKey? {
        let workspace = NSWorkspace.shared
        guard let url = workspace.desktopImageURL(for: screen) else {
            return nil
        }
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fillColor = (options[.fillColor] as? NSColor)?.cgColor
        let menuBarHeight = screen.getMenuBarHeight() ?? NSStatusBar.system.thickness
        return RenderKey(
            url: url,
            modificationDate: attributes?[.modificationDate] as? Date,
            placement: Self.placement(from: options),
            fillColor: fillColor,
            screenFrame: screen.frame,
            menuBarHeight: menuBarHeight,
            scale: screen.backingScaleFactor
        )
    }

    private static func placement(from options: [NSWorkspace.DesktopImageOptionKey: Any]) -> Placement {
        let rawScaling = (options[.imageScaling] as? NSNumber)?.uintValue
        let scaling = rawScaling.flatMap(NSImageScaling.init(rawValue:)) ?? .scaleProportionallyUpOrDown
        let allowsClipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        switch scaling {
        case .scaleProportionallyUpOrDown, .scaleProportionallyDown:
            return allowsClipping ? .fill : .fit
        case .scaleAxesIndependently:
            return .stretch
        case .scaleNone:
            return .center
        @unknown default:
            return .fill
        }
    }

    private func render(_ key: RenderKey) -> RenderedImages? {
        guard
            let wallpaper = decodeWallpaper(at: key.url),
            let region = renderRegion(of: wallpaper, for: key),
            let strip = Self.downsampleToSingleRow(region)
        else {
            return nil
        }
        return RenderedImages(key: key, region: region, strip: strip)
    }

    /// Decodes the first image in the wallpaper file, applying its EXIF
    /// orientation and limiting its size.
    private func decodeWallpaper(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeMaxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Draws the wallpaper as the system places it on the screen, and returns
    /// the band that lies under the menu bar.
    private func renderRegion(of wallpaper: CGImage, for key: RenderKey) -> CGImage? {
        let width = Int((key.screenFrame.width * key.scale).rounded())
        let height = Int((key.menuBarHeight * key.scale).rounded())
        guard
            width > 0,
            height > 0,
            let context = Self.makeContext(width: width, height: height)
        else {
            return nil
        }
        context.interpolationQuality = .high
        if let fillColor = key.fillColor {
            context.setFillColor(fillColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // `placedRect` uses a top-left origin in screen pixels. The context
        // uses a bottom-left origin and covers only the top `height` pixels
        // of the screen, so flip the rectangle into the context's space.
        let placedRect = Self.placedRect(
            imageSize: CGSize(width: wallpaper.width, height: wallpaper.height),
            screenSize: CGSize(width: width, height: Int((key.screenFrame.height * key.scale).rounded())),
            placement: key.placement
        )
        let drawRect = CGRect(
            x: placedRect.minX,
            y: CGFloat(height) - placedRect.minY - placedRect.height,
            width: placedRect.width,
            height: placedRect.height
        )
        context.draw(wallpaper, in: drawRect)
        return context.makeImage()
    }

    /// Returns the rectangle, in screen pixels with a top-left origin, that
    /// the wallpaper occupies for the given placement.
    private static func placedRect(imageSize: CGSize, screenSize: CGSize, placement: Placement) -> CGRect {
        let size: CGSize
        switch placement {
        case .fill:
            let factor = max(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
            size = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        case .fit:
            let factor = min(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
            size = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        case .stretch:
            size = screenSize
        case .center:
            size = imageSize
        }
        return CGRect(
            x: (screenSize.width - size.width) / 2,
            y: (screenSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Averages each column of the image into a single row.
    private static func downsampleToSingleRow(_ image: CGImage) -> CGImage? {
        guard let context = makeContext(width: image.width, height: 1) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: 1))
        return context.makeImage()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
