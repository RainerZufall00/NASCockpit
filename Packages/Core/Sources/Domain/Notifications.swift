import Foundation

/// One entry of the NAS's own notification list (DSM: the bell in the web UI).
public struct NASNotification: Identifiable, Sendable, Hashable {
    public struct Detail: Identifiable, Sendable, Hashable {
        public var label: String
        public var value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var id: String
    public var date: Date
    public var level: LogLevel
    public var title: String
    /// One line: what it is about (task, container, log text). May be empty.
    public var message: String
    /// Everything else the NAS sent along, for the detail view.
    public var details: [Detail]

    public init(id: String, date: Date, level: LogLevel, title: String, message: String, details: [Detail] = []) {
        self.id = id
        self.date = date
        self.level = level
        self.title = title
        self.message = message
        self.details = details
    }
}
