import Foundation

/// Decodes a manifest value written by a build that may not be this one.
///
/// A manifest is read by whatever version of Dicavo is installed,
/// which is not always the version that wrote it. Removing an enum case used
/// to make every older manifest carrying it undecodable *in its entirety*:
/// the recording could no longer be opened, recovered, reprocessed or
/// reanalysed, although its audio, transcript and analysis were all intact
/// on disk. It happened once already — `SessionAnalysisStatus` carried a
/// `missingAPIKey` case between 2026-07-11 and 2026-08-12.
///
/// A value this build does not know now decodes to `unrecognized`. Every
/// such enum is only ever compared for equality, never switched over
/// exhaustively, so an unknown value reads as "not completed" — the
/// conservative answer, and the one that keeps the rest of the manifest
/// readable.
///
/// The original spelling is not preserved: the next manifest write replaces
/// it with `unrecognized`. That is a deliberate trade. This build cannot act
/// on a state it does not know, and the alternative on offer was losing the
/// whole recording.
extension RawRepresentable where Self: Decodable, RawValue == String {
    static func decodedFromManifest(
        _ decoder: any Decoder,
        fallback: Self
    ) throws -> Self {
        let raw = try decoder.singleValueContainer().decode(String.self)
        return Self(rawValue: raw) ?? fallback
    }
}
