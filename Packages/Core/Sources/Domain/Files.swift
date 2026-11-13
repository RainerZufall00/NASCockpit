import Foundation

/// An entry in File Station. Paths start with the shared folder, e.g. `/photo/2024`.
public struct FileItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?

    public init(path: String, name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    /// Folder that contains this item ("/" for a shared folder).
    public var parentPath: String { FileItem.parent(of: path) }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    public static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/\(name)" : "\(folder)/\(name)"
    }

    /// Folders first, then by name like Finder.
    public static func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

public enum TransferMode: String, Sendable, Hashable {
    case copy, move
}

public enum FileValidation {
    /// A folder cannot be copied or moved into itself or one of its subfolders, or onto its own parent (move).
    public static func canTransfer(_ item: FileItem, to destination: String, mode: TransferMode) -> Bool {
        if destination == item.path || destination.hasPrefix(item.path + "/") { return false }
        if destination == "/" { return false }
        if mode == .move, destination == item.parentPath { return false }
        return true
    }

    /// DSM rejects these characters in file names.
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }
}
