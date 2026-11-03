import Foundation

/// Cursor's usage for the current billing cycle, from
/// `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`.
struct CursorUsage: Equatable {
    var premiumPercent: Double       // planUsage.apiPercentUsed: named/premium models
    var cursorModelsPercent: Double  // planUsage.autoPercentUsed: Auto, Composer, Grok
    var totalPercent: Double         // planUsage.totalPercentUsed
    var cycleEnd: Date               // billingCycleEnd: when both pools reset
    var plan: String?
    var fetchedAt: Date
}

enum CursorDecodeError: Error {
    case badShape
}

extension CursorUsage {
    static func decode(_ data: Data, fetchedAt: Date) throws -> CursorUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = json["planUsage"] as? [String: Any],
              let api = number(plan["apiPercentUsed"]),
              let auto = number(plan["autoPercentUsed"]),
              let total = number(plan["totalPercentUsed"]),
              let endMillis = number(json["billingCycleEnd"])
        else { throw CursorDecodeError.badShape }
        return CursorUsage(premiumPercent: api, cursorModelsPercent: auto, totalPercent: total,
                           cycleEnd: Date(timeIntervalSince1970: endMillis / 1000), plan: nil, fetchedAt: fetchedAt)
    }

    /// "pro_student" → "Pro Student"
    static func planDisplayName(_ raw: String) -> String {
        raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Cursor sends some numbers as JSON strings (e.g. epoch milliseconds).
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

enum JWT {
    /// The `exp` claim of a JWT, or nil if the token isn't a JWT or has no expiry.
    static func expiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? NSNumber
        else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }
}

/// What the menu bar shows for Cursor: Premium models until they run out,
/// then Cursor's own models, then nothing left.
enum CursorBadge: Equatable {
    case premium(Double)
    case cursorModels(Double)
    case exhausted

    /// Nil when there's no data or it belongs to a billing cycle that has ended.
    static func from(_ usage: CursorUsage?, now: Date) -> CursorBadge? {
        guard let usage, now < usage.cycleEnd else { return nil }
        if usage.premiumPercent < 100 { return .premium(usage.premiumPercent) }
        if usage.cursorModelsPercent < 100 { return .cursorModels(usage.cursorModelsPercent) }
        return .exhausted
    }

    var displayPercent: Int {
        switch self {
        case .premium(let p), .cursorModels(let p): return min(100, max(0, Int(p.rounded())))
        case .exhausted: return 100
        }
    }
}
