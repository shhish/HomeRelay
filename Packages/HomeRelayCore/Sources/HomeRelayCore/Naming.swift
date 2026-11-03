import Foundation

public enum Naming {
    /// "Current Temperature" -> "currentTemperature", "PM2.5 Density" -> "pm25Density".
    /// Used for characteristic and service types the app has no explicit name for.
    public static func camelCase(_ label: String) -> String {
        let words = label
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return "unknown" }
        let head = first.prefix(1).lowercased() + first.dropFirst().lowercased()
        let tail = words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return ([head] + tail).joined()
    }
}
