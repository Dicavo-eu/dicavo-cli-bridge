import Foundation

// The licence vocabulary the shared analysis errors speak. The bridge never
// checks a licence: Dicavo decides what it offers before it sends a request,
// and the bridge runs what it is asked to. Only the types an error can carry
// live here.

/// A capability that the free build does not provide and Pro does.
///
/// The set is written into manifests that outlive the build which wrote them,
/// so a feature a build does not know decodes to `unrecognized` rather than
/// failing the whole file.
enum ProFeature: String, Codable, Equatable, Sendable {
    case cloudAnalysis
    case bridgeAnalysis
    case customDictionary
    case outputTemplates
    case calendarAutoStart
    case crossMeetingSearch
    /// Separating the voices of one recording.
    case speakerSeparation
    /// Access for AI agents through `Dicavo --mcp`. 2.1 reads it as
    /// `unrecognized`.
    case agentAccess
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
}

/// Where a Pro entitlement came from.
///
/// Same rule as `ProFeature`: the value is read by builds that may be older
/// than the writer, so an unknown spelling decodes to `unrecognized` instead
/// of invalidating the record.
enum LicenseSource: String, Codable, Equatable, Sendable {
    case purchase
    case grandfathered
    case trial
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
}

/// What the user is currently entitled to.
///
/// A `pro` state carries the source of the entitlement and, when the
/// entitlement is bounded, when it expires. A `free` state carries why the
/// user is not on Pro: either they never were, or an entitlement ran out.
enum LicenseState: Equatable, Sendable {
    case pro(source: LicenseSource, expires: Date?)
    case free(reason: FreeReason)

    enum FreeReason: Equatable, Sendable {
        case never
        case expired(Date)
    }

    var isPro: Bool {
        if case .pro = self { return true }
        return false
    }

    /// The state as it stands at `now`. A state is decided at one moment,
    /// and a menu-bar app stays open for weeks: a Pro whose expiration has
    /// passed is expired Free from then on, whether or not anything has
    /// refreshed it since.
    func effective(at now: Date) -> LicenseState {
        if case let .pro(_, expires?) = self, expires <= now {
            return .free(reason: .expired(expires))
        }
        return self
    }
}
