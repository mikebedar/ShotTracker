#if DEBUG
import Foundation

/// Canned RxTerms and openFDA answers for `-uiTestStubNetwork` runs. Any search term
/// returns two results built from the term (an oral pill with two strengths and an
/// injectable with one); the term "zzz" returns no matches and "offline" fails like a
/// dropped connection. openFDA always returns one label.
nonisolated final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "clinicaltables.nlm.nih.gov" || host == "api.fda.gov"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        if url.host == "clinicaltables.nlm.nih.gov" {
            let term = items.first { $0.name == "terms" }?.value ?? ""
            if term.lowercased() == "offline" {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            respond(Self.rxTerms(for: term), url: url)
        } else {
            respond(Self.openFDALabel, url: url)
        }
    }

    override func stopLoading() {}

    private func respond(_ body: String, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func rxTerms(for term: String) -> String {
        let name = term.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // `[0,[],{},[]]` is what RxTerms really sends for no hits.
        guard name.lowercased() != "zzz", !name.isEmpty else { return #"[0,[],{},[]]"# }
        return """
        [2,["\(name) (Oral Pill)","\(name) (Injectable)"],\
        {"STRENGTHS_AND_FORMS":[[" 20 mg Tab"," 40 mg Tab"],[" 10 mg/ml Sol"]],\
        "RXCUIS":[["310429","313988"],["727573"]],"SXDG_RXCUI":["1000001","1000002"]},\
        [["\(name) (Oral Pill)"],["\(name) (Injectable)"]]]
        """
    }

    static let openFDALabel = """
    {"results":[{"description":["Stub label description."],\
    "indications_and_usage":["Stub indications."],"warnings":["Stub warnings."],\
    "boxed_warning":["Stub boxed warning."],"adverse_reactions":["Stub adverse reactions."],\
    "openfda":{"brand_name":["Stubix"],"manufacturer_name":["Stub Labs"],"route":["ORAL"],"rxcui":["310429"]}}]}
    """
}
#endif
