import Foundation

/// One specific strength/form of a drug+route search result (e.g. "500 mg Tab"),
/// with the exact RxCUI for that variant when RxTerms provides one — this is what
/// lets a user pick the precise medication they're taking, not just the drug family.
struct MedicationVariant: Identifiable, Hashable {
    let id = UUID()
    let strengthAndForm: String
    let rxcui: String?
}

struct MedicationLookupResult: Identifiable, Hashable {
    let id = UUID()
    let displayName: String
    let canonicalName: String
    let routeSummary: String?
    let rxNormCode: String?
    let variants: [MedicationVariant]
}

struct MedicationLookupResponse: Decodable {
    let totalCount: Int
    let codes: [String]
    let extras: Extras?
    let displayRows: [[String]]

    struct Extras: Decodable {
        let strengthsAndForms: [[String]]?
        let rxcuis: [[String]]?
        let sxdgRxCui: [String]?

        enum CodingKeys: String, CodingKey {
            case strengthsAndForms = "STRENGTHS_AND_FORMS"
            case rxcuis = "RXCUIS"
            case sxdgRxCui = "SXDG_RXCUI"
        }
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        totalCount = try container.decode(Int.self)
        codes = try container.decode([String].self)
        // A failed `try?` decode doesn't advance an unkeyed container, so a `null` here
        // used to make the next field (the display rows) fail and the whole search throw.
        if try container.decodeNil() {
            extras = nil
        } else {
            extras = try? container.decode(Extras.self)
        }
        displayRows = try container.decode([[String]].self)
    }
}

final class MedicationLookupService {
    private let urlSession: URLSession

    init(urlSession: URLSession = LaunchOptions.urlSession) {
        self.urlSession = urlSession
    }

    func search(query: String) async throws -> [MedicationLookupResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://clinicaltables.nlm.nih.gov/api/rxterms/v3/search")
        components?.queryItems = [
            URLQueryItem(name: "terms", value: trimmed),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "ef", value: "STRENGTHS_AND_FORMS,RXCUIS,SXDG_RXCUI"),
        ]

        guard let url = components?.url else { return [] }

        let (data, _) = try await urlSession.data(from: url)
        let decoded = try JSONDecoder().decode(MedicationLookupResponse.self, from: data)

        return zip(decoded.codes.indices, decoded.codes).map { index, code in
            let displayValue = decoded.displayRows[safe: index]?.first ?? code
            let routeSummary = routeText(from: displayValue)
            let canonicalName = displayValue.replacingOccurrences(of: routeSummary.map { " (\($0))" } ?? "", with: "")
            let variants = Self.parseVariants(
                strengthsAndForms: decoded.extras?.strengthsAndForms?[safe: index] ?? [],
                rxcuis: decoded.extras?.rxcuis?[safe: index] ?? []
            )

            return MedicationLookupResult(
                displayName: canonicalName,
                canonicalName: canonicalName,
                routeSummary: routeSummary,
                rxNormCode: decoded.extras?.sxdgRxCui?[safe: index],
                variants: variants
            )
        }
    }

    /// Zips a result row's `STRENGTHS_AND_FORMS` with its parallel `RXCUIS` array into
    /// variants, tolerating a shorter/missing RXCUIS array (older RxTerms rows, or the
    /// `ef` field simply not resolving for that row) by leaving `rxcui` nil rather than
    /// dropping the strength entirely — a variant without an RxCUI still displays fine,
    /// it just can't drive an openFDA lookup later.
    static func parseVariants(strengthsAndForms: [String], rxcuis: [String]) -> [MedicationVariant] {
        strengthsAndForms.enumerated().map { index, strengthAndForm in
            MedicationVariant(
                strengthAndForm: strengthAndForm.trimmingCharacters(in: .whitespaces),
                rxcui: rxcuis[safe: index]
            )
        }
    }

    private func routeText(from displayName: String) -> String? {
        guard
            let open = displayName.lastIndex(of: "("),
            let close = displayName.lastIndex(of: ")"),
            open < close
        else {
            return nil
        }

        return String(displayName[displayName.index(after: open)..<close])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
