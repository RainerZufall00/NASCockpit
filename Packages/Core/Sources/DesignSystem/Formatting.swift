import Foundation

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    /// RAM is binary: 8 GiB shows as "8 GB".
    public static func memory(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .memory))
    }

    public static func throughput(_ bytesPerSecond: Double) -> String {
        let bytes = Int64(max(0, bytesPerSecond))
        // ByteCountFormatStyle spells 0 as "Zero kB".
        let value = bytes == 0 ? "0 B" : bytes.formatted(.byteCount(style: .decimal))
        return "\(value)/s"
    }

    public static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    public static func temperature(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? ""
    }
}
