import Foundation

/// Fetches structured drug-label sections from the openFDA Drug Label API
/// (api.fda.gov/drug/label.json — free, no auth required at this app's volume) for a
/// medication chosen via Lookup. Stateless, matching `DoseForecastService`'s pattern —
/// no DI wiring needed. Never throws to the caller: a missing/unmatched label is a
/// normal outcome (openFDA coverage varies per drug), not an error to surface, so
/// picking a medication is never blocked waiting on this.
enum DrugInfoService {
    private static let baseURL = "https://api.fda.gov/drug/label.json"

    static func fetchLabel(
        rxcui: String?,
        genericName: String,
        urlSession: URLSession = .shared
    ) async -> DrugLabelInfo? {
        if let rxcui, let byRxcui = await fetch(search: "openfda.rxcui:\"\(rxcui)\"", urlSession: urlSession) {
            return byRxcui
        }

        let trimmedName = genericName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        return await fetch(search: "openfda.generic_name:\"\(trimmedName)\"", urlSession: urlSession)
    }

    private static func fetch(search: String, urlSession: URLSession) async -> DrugLabelInfo? {
        var components = URLComponents(string: baseURL)
        components?.queryItems = [
            URLQueryItem(name: "search", value: search),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else { return nil }

        guard
            let (data, _) = try? await urlSession.data(from: url),
            let decoded = try? JSONDecoder().decode(OpenFDALabelResponse.self, from: data),
            let result = decoded.results?.first
        else {
            return nil
        }

        return DrugLabelInfo(
            rxcui: result.openfda?.rxcui?.first,
            brandName: result.openfda?.brandName?.first,
            manufacturerName: result.openfda?.manufacturerName?.first,
            route: result.openfda?.route?.first,
            drugDescription: result.description,
            indicationsAndUsage: result.indicationsAndUsage,
            warnings: result.warnings,
            boxedWarning: result.boxedWarning,
            adverseReactions: result.adverseReactions,
            fetchedAt: .now
        )
    }
}

/// openFDA's drug-label response shape. Every field optional and defensively decoded —
/// label sections vary widely per drug, and a missing/renamed field must never crash.
private struct OpenFDALabelResponse: Decodable {
    let results: [Result]?

    struct Result: Decodable {
        let description: [String]?
        let warnings: [String]?
        let boxedWarning: [String]?
        let indicationsAndUsage: [String]?
        let adverseReactions: [String]?
        let openfda: OpenFDAFields?

        enum CodingKeys: String, CodingKey {
            case description
            case warnings
            case boxedWarning = "boxed_warning"
            case indicationsAndUsage = "indications_and_usage"
            case adverseReactions = "adverse_reactions"
            case openfda
        }
    }

    struct OpenFDAFields: Decodable {
        let brandName: [String]?
        let genericName: [String]?
        let manufacturerName: [String]?
        let route: [String]?
        let rxcui: [String]?

        enum CodingKeys: String, CodingKey {
            case brandName = "brand_name"
            case genericName = "generic_name"
            case manufacturerName = "manufacturer_name"
            case route
            case rxcui
        }
    }
}
