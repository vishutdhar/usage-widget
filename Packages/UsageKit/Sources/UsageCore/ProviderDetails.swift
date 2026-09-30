import Foundation

/// What a provider's `extras` add to the widget: a plan name beside the
/// account label and a footnote under its rows. Both the widget and the
/// reload fingerprint read them here, so a change the widget would show is
/// a change the scheduler sees.
///
/// Values are checked on the way out: an unrecognised plan or an
/// implausible count shows nothing rather than something wrong.
public enum ProviderDetails {
    public static let planKey = "planType"
    public static let resetCreditsKey = "resetCreditsAvailable"
    /// Larger counts are not plausible and are not shown.
    public static let maxResetCredits = 999

    /// The plan as a person would name it, from the Codex protocol's plan
    /// values; nil for "unknown" and anything not in the list.
    public static func planName(_ raw: String) -> String? {
        switch raw {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business", "self_serve_business_prolite", "self_serve_business_usage_based": return "Business"
        case "enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based": return "Enterprise"
        case "edu": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        default: return nil
        }
    }

    public static func plan(in extras: [String: JSONValue]) -> String? {
        guard case .string(let raw)? = extras[planKey] else { return nil }
        return planName(raw)
    }

    /// The banked reset count, when it is a whole number in range.
    public static func resetCredits(in extras: [String: JSONValue]) -> Int? {
        guard case .number(let value)? = extras[resetCreditsKey], value.isFinite, value >= 0,
              value <= Double(maxResetCredits), value.rounded() == value else { return nil }
        return Int(value)
    }

    public static func resetsText(_ count: Int) -> String {
        switch count {
        case 0: return "No resets available"
        case 1: return "1 reset available"
        default: return "\(count) resets available"
        }
    }

    public static func footnote(in extras: [String: JSONValue]) -> String? {
        resetCredits(in: extras).map(resetsText)
    }
}
