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
nonisolated enum LaunchOptions {
    #if DEBUG
    private static let arguments = ProcessInfo.processInfo.arguments
    static let isUITesting = arguments.contains("-uiTesting")
    static let stubsNetwork = arguments.contains("-uiTestStubNetwork")
    static let seedsDemoData = arguments.contains("-seedDemoData")
    #else
    static let isUITesting = false
    static let stubsNetwork = false
    static let seedsDemoData = false
    #endif

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
