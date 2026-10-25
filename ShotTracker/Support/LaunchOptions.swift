import Foundation

/// Launch arguments for UI tests and demo runs. Debug builds only — a Release build
/// ignores every one of them.
///
/// - `-uiTesting`: a fresh in-memory store and a throwaway preferences suite, and no
///   notification-permission prompt (a system alert would block the test).
/// - `-uiTestStubNetwork`: RxTerms and openFDA answer from canned fixtures
///   (`StubURLProtocol`), so lookup tests are deterministic and never hit the network.
/// - `-seedDemoData`: fill an empty store with `DemoData` (every regimen kind, doses in
///   every Today bucket, a week of history). Works with or without `-uiTesting`.
/// - `-runBackgroundRefresh`: run the `BGAppRefreshTask` handler once after launch (the
///   simulator won't schedule one).
/// - `-deviceTimeZone <identifier>`: run as if the device were in that zone
///   (`NSTimeZone.default`), e.g. `Europe/Paris` — for the "home · here" display.
/// - `-demoTrip` (with the two above): the demo's doses are planned on their home clocks,
///   as if the phone had just landed, and two medications with non-default travel options
///   are added ("Malarone": keep 20 hours, a dose held back; "Doxycycline": move an open
///   dose to the new clock now).
/// - `-demoHomeTimeZone <identifier>`: the zone `DemoData`'s schedules are written in
///   (default: the device's), e.g. `America/New_York` with `-deviceTimeZone Europe/Paris`
///   for a two-zone Today.
/// - `-atelierTheme <id>`: start on that Atelier theme, never stored (`shottracker`, `system`, `warm`, `studio`,
///   `contrast`, or `canary`, which paints everything the theme reaches in loud colours).
/// - `-atelierMotion system|reduced|off`: transient motion preference for UI checks.
/// - `-atelierAppearance system|light|dark`: transient color scheme for captures.
/// - `-toastPlacement top`: toasts at the top (Atelier's iPhone default) instead of above the tab bar.
nonisolated enum LaunchOptions {
    #if DEBUG
    private static let arguments = ProcessInfo.processInfo.arguments
    static let isUITesting = arguments.contains("-uiTesting")
    /// Visual-only captures can outlast the normal six-second Undo toast; behavior tests never set this.
    static let holdsToastForCapture = isUITesting && arguments.contains("-uiTestHoldToast")
    static let stubsNetwork = arguments.contains("-uiTestStubNetwork")
    static let seedsDemoData = arguments.contains("-seedDemoData")
    static let runsBackgroundRefresh = arguments.contains("-runBackgroundRefresh")
    static let demoTrip = arguments.contains("-demoTrip")
    static let deviceTimeZone = value(after: "-deviceTimeZone").flatMap(TimeZone.init(identifier:))
    static let demoHomeTimeZone = value(after: "-demoHomeTimeZone").flatMap(TimeZone.init(identifier:))
    static let atelierThemeID = value(after: "-atelierTheme")
    static let atelierMotion = value(after: "-atelierMotion")
    static let atelierAppearance = value(after: "-atelierAppearance")
    static let toastPlacementTop = value(after: "-toastPlacement") == "top"

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    #else
    static let isUITesting = false
    static let stubsNetwork = false
    static let seedsDemoData = false
    static let runsBackgroundRefresh = false
    static let demoTrip = false
    static let deviceTimeZone: TimeZone? = nil
    static let demoHomeTimeZone: TimeZone? = nil
    #endif

    /// Makes `-deviceTimeZone` the process's zone. Call first thing at launch.
    static func applyDeviceTimeZoneOverride() {
        guard let deviceTimeZone else { return }
        // `NSTimeZone.default` alone moves `Calendar.current` but not `TimeZone.current`
        // or `.autoupdatingCurrent` (what formatters use) on iOS 27, so make it the
        // process's *system* zone too: Foundation reads `TZ` first.
        setenv("TZ", deviceTimeZone.identifier, 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        NSTimeZone.default = deviceTimeZone
    }

    /// After `NSSystemTimeZoneDidChange`: drop the cached system zone so `TimeZone.current`
    /// reads the new one (a `-deviceTimeZone` override stays in place).
    static func resetSystemTimeZoneUnlessOverridden() {
        guard deviceTimeZone == nil else { return }
        NSTimeZone.resetSystemTimeZone()
    }

    /// The defaults the app's own preferences live in. UI tests get a suite that's
    /// wiped at launch, so one test's settings never leak into the next.
    static let defaults: UserDefaults = {
        guard isUITesting, let suite = UserDefaults(suiteName: "ShotTracker.UITests") else { return .standard }
        suite.removePersistentDomain(forName: "ShotTracker.UITests")
        return suite
    }()

    /// The session for lookup and drug-info requests.
    static let urlSession: URLSession = {
        #if DEBUG
        if stubsNetwork {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        #endif
        return .shared
    }()
}
