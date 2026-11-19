//
//  ScreenCapture.swift
//  Ice
//

import CoreGraphics
import OSLog
import ScreenCaptureKit

/// A namespace for screen capture operations.
enum ScreenCapture {

    // MARK: Permissions

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    static func checkPermissions() -> Bool {
        for windowID in Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace]) {
            guard
                let window = WindowInfo(windowID: windowID),
                window.owningApplication != .current // Skip windows we own.
            else {
                continue
            }
            return window.title != nil
        }
        // CGPreflightScreenCaptureAccess() only returns an initial value,
        // but we can use it as a fallback.
        return CGPreflightScreenCaptureAccess()
    }

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    ///
    /// This function caches its initial result and returns it on subsequent
    /// calls. Pass `true` to the `reset` parameter to replace the cached
    /// result with a newly computed value.
    static func cachedCheckPermissions(reset: Bool = false) -> Bool {
        enum Context {
            static var cachedResult: Bool?
        }
        if !reset, let result = Context.cachedResult {
            return result
        }
        let result = checkPermissions()
        Context.cachedResult = result
        return result
    }

    /// Requests screen capture permissions.
    static func requestPermissions() {
        if #available(macOS 15.0, *) {
            // CGRequestScreenCaptureAccess() is broken on macOS 15. We can
            // try accessing SCShareableContent to trigger a request if the
            // user doesn't have permissions.
            // TODO: Find out if we still need this as of macOS 26.
            SCShareableContent.getWithCompletionHandler { _, _ in }
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Capture Window(s)

    /// Captures a composite image of an array of windows.
    ///
    /// The windows are composited from front to back, according to the order
    /// of the `windowIDs` parameter.
    ///
    /// - Parameters:
    ///   - windowIDs: The identifiers of the windows to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the windows.
    ///   - option: Options that specify which parts of the windows are captured.
    static func captureWindows(with windowIDs: [CGWindowID], screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        guard let array = Bridging.createCGWindowArray(with: windowIDs) else {
            return nil
        }
        let bounds = screenBounds ?? .null
        // ScreenCaptureKit doesn't support capturing images of offscreen menu bar
        // items, so we unfortunately have to use the deprecated CGWindowList API.
        return CaptureExecutor.shared.perform(timeout: CaptureExecutor.defaultTimeout) {
            CGImage(windowListFromArrayScreenBounds: bounds, windowArray: array, imageOption: option)
        }
    }

    /// Captures an image of a window.
    ///
    /// - Parameters:
    ///   - windowID: The identifier of the window to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the window.
    ///   - option: Options that specify which parts of the window are captured.
    static func captureWindow(with windowID: CGWindowID, screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        captureWindows(with: [windowID], screenBounds: screenBounds, option: option)
    }
}

// MARK: - CaptureExecutor

/// Runs window capture requests on a dedicated serial queue and bounds the
/// time that a caller waits for each result.
///
/// On macOS 15 and later, the CGWindowList capture functions are proxied
/// through the `replayd` system daemon. The daemon occasionally leaves a
/// request unanswered, and the call then blocks its thread for 30 seconds
/// before it fails. Waiting for such a request on the main thread freezes
/// the app, and queueing further requests behind it extends the freeze
/// indefinitely. This executor therefore abandons a request once its
/// timeout elapses, and rejects new requests until the stalled one returns.
private final class CaptureExecutor: @unchecked Sendable {
    /// The lifecycle of a single capture request.
    private enum Phase {
        case pending
        case running
        case completed
        case abandoned
    }

    /// The mutable state of a capture request.
    private struct RequestState {
        var phase = Phase.pending
        var image: CGImage?
    }

    /// A single capture request, shared between the caller and the queue.
    private final class Request: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(uncheckedState: RequestState())
    }

    /// The shared executor.
    static let shared = CaptureExecutor()

    /// The maximum time to wait for a capture on the main thread, where any
    /// wait delays user interaction.
    static let mainThreadTimeout: DispatchTimeInterval = .milliseconds(250)

    /// The maximum time to wait for a capture on any other thread.
    static let backgroundTimeout: DispatchTimeInterval = .milliseconds(1500)

    /// The timeout appropriate for the calling thread.
    static var defaultTimeout: DispatchTimeInterval {
        Thread.isMainThread ? mainThreadTimeout : backgroundTimeout
    }

    private let queue = DispatchQueue(label: "ScreenCapture.CaptureExecutor", qos: .userInitiated)

    /// The number of abandoned requests that are still executing.
    private let stalledRequestCount = OSAllocatedUnfairLock(initialState: 0)

    private let logger = Logger(category: "ScreenCapture")

    /// Performs the given capture and returns its result, or returns `nil`
    /// if the capture does not finish within `timeout`, or if an earlier
    /// capture is still stalled.
    func perform(timeout: DispatchTimeInterval, capture: @escaping () -> CGImage?) -> CGImage? {
        guard stalledRequestCount.withLock({ $0 }) == 0 else {
            return nil
        }
        let request = Request()
        queue.async { [self] in
            execute(request, capture: capture)
        }
        if request.semaphore.wait(timeout: .now() + timeout) == .success {
            return request.state.withLockUnchecked { $0.image }
        }
        return abandon(request)
    }

    /// Runs a request on the queue, unless its caller has already abandoned it.
    private func execute(_ request: Request, capture: () -> CGImage?) {
        let shouldRun = request.state.withLock { state in
            guard state.phase == .pending else {
                return false
            }
            state.phase = .running
            return true
        }
        guard shouldRun else {
            return
        }
        let image = capture()
        let wasAbandoned = request.state.withLockUnchecked { state in
            guard state.phase == .running else {
                return true
            }
            state.phase = .completed
            state.image = image
            return false
        }
        if wasAbandoned {
            stalledRequestCount.withLock { $0 -= 1 }
            logger.notice("Stalled screen capture request finished; resuming captures")
        } else {
            request.semaphore.signal()
        }
    }

    /// Marks a timed-out request as abandoned. Returns the request's image if
    /// it completed between the timeout and this call.
    ///
    /// A request that is still running is counted as stalled while its lock
    /// is held, so the queue cannot record its completion before the count
    /// is incremented.
    private func abandon(_ request: Request) -> CGImage? {
        let (previousPhase, image) = request.state.withLockUnchecked { state in
            let previous = (state.phase, state.image)
            if state.phase == .running {
                stalledRequestCount.withLock { $0 += 1 }
            }
            if state.phase != .completed {
                state.phase = .abandoned
            }
            return previous
        }
        if previousPhase == .running {
            logger.error("Screen capture request timed out; suspending captures until it returns")
        }
        return image
    }
}
