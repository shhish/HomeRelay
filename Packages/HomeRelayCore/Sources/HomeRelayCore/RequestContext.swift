import Foundation

/// Who is behind the current request, so the backend can label the events a
/// write or scene run causes. Set by `APIRouter` for the duration of a request.
public enum RequestContext {
    /// Token name.
    @TaskLocal public static var caller: String?
    /// The `X-HomeRelay-Cause` header: an opaque id a client (a routine engine,
    /// say) uses to recognise events its own actions caused.
    @TaskLocal public static var cause: String?

    /// Accepts short printable ids only; anything else is ignored.
    static func validCause(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.count <= 128,
              raw.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7F }) else { return nil }
        return raw
    }
}
