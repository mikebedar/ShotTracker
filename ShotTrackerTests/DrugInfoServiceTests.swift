import Foundation
import Testing
@testable import ShotTracker

/// Intercepts requests and returns a canned response — no live network in tests.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// Serialized: every test mutates the shared StubURLProtocol static state before its
// network call resolves, so concurrent execution races on which fixture a given
// request actually sees.
@Suite(.serialized)
@MainActor
struct DrugInfoServiceTests {
    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let fullLabelJSON = """
    {
      "results": [
        {
          "description": ["DESCRIPTION Metformin is an oral antihyperglycemic drug."],
          "warnings": ["WARNINGS Lactic acidosis has been reported."],
          "indications_and_usage": ["Indicated to improve glycemic control."],
          "adverse_reactions": ["Diarrhea, nausea."],
          "openfda": {
            "brand_name": ["Glucophage"],
            "generic_name": ["Metformin Hydrochloride"],
            "manufacturer_name": ["Example Pharma"],
            "route": ["ORAL"],
            "rxcui": ["860975"]
          }
        }
      ]
    }
    """

    private static let boxedWarningJSON = """
    {
      "results": [
        {
          "boxed_warning": ["WARNING: SERIOUS RISK"],
          "openfda": { "rxcui": ["111"] }
        }
      ]
    }
    """

    private static let noResultsJSON = """
    { "results": [] }
    """

    @Test func decodesFullLabelWithOpenFDAFields() async {
        StubURLProtocol.responseData = Data(Self.fullLabelJSON.utf8)
        let info = await DrugInfoService.fetchLabel(rxcui: "860975", genericName: "metformin", urlSession: Self.stubbedSession())

        #expect(info != nil)
        #expect(info?.rxcui == "860975")
        #expect(info?.brandName == "Glucophage")
        #expect(info?.manufacturerName == "Example Pharma")
        #expect(info?.route == "ORAL")
        #expect(info?.drugDescription?.first?.contains("antihyperglycemic") == true)
        #expect(info?.warnings?.first?.contains("Lactic acidosis") == true)
        #expect(info?.indicationsAndUsage?.first?.contains("glycemic") == true)
        #expect(info?.adverseReactions?.first == "Diarrhea, nausea.")
        #expect(info?.boxedWarning == nil)
        #expect(info?.fetchedAt != nil)
    }

    @Test func missingBoxedWarningStaysNilNotCrash() async {
        // Most drugs have no boxed warning at all — openFDA simply omits the field.
        StubURLProtocol.responseData = Data(Self.fullLabelJSON.utf8)
        let info = await DrugInfoService.fetchLabel(rxcui: "860975", genericName: "metformin", urlSession: Self.stubbedSession())
        #expect(info?.boxedWarning == nil)
    }

    @Test func decodesBoxedWarningWhenPresent() async {
        StubURLProtocol.responseData = Data(Self.boxedWarningJSON.utf8)
        let info = await DrugInfoService.fetchLabel(rxcui: "111", genericName: "example", urlSession: Self.stubbedSession())
        #expect(info?.boxedWarning?.first?.contains("SERIOUS RISK") == true)
    }

    @Test func noMatchReturnsNilRatherThanThrowing() async {
        StubURLProtocol.responseData = Data(Self.noResultsJSON.utf8)
        let info = await DrugInfoService.fetchLabel(rxcui: "nonexistent", genericName: "totally made up drug", urlSession: Self.stubbedSession())
        #expect(info == nil)
    }

    @Test func malformedJSONReturnsNilRatherThanCrashing() async {
        StubURLProtocol.responseData = Data("not json at all".utf8)
        let info = await DrugInfoService.fetchLabel(rxcui: "860975", genericName: "metformin", urlSession: Self.stubbedSession())
        #expect(info == nil)
    }
}
