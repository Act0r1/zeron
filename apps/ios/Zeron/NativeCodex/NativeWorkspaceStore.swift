import Foundation
import Darwin

/// Sole owner of persistent project files. The JS worker only holds a path index.
/// Actor isolation serializes mutations without blocking shell bridge callbacks.
actor NativeWorkspaceStore {
    let directory: URL
    private let legacyCheckpoint: URL
    private var prepared = false
    private var changes = Set<String>()
    private var commandID: String?
    private let fm = FileManager.default

    init(checkpointURL: URL) {
        legacyCheckpoint = checkpointURL
        directory = checkpointURL.deletingPathExtension().appendingPathExtension("files")
    }

    private func failure(_ text: String) -> NSError { NativeWorkspaceFiles.failure(text) }

    private func prepare() throws {
        guard !prepared else { return }
        if !fm.fileExists(atPath: directory.path) {
            if fm.fileExists(atPath: legacyCheckpoint.path) {
                let entries = try JSONDecoder().decode([NativeWorkspaceEntry].self, from: Data(contentsOf: legacyCheckpoint))
                let stage = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                defer { try? fm.removeItem(at: stage) }
                try NativeWorkspaceFiles.export(entries, to: stage)
                try fm.moveItem(at: stage, to: directory)
                // Keep the legacy checkpoint as a migration backup. Native files now win.
            } else { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        }
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw failure("Invalid workspace directory") }
        prepared = true
    }

    /// Only canonical mount-relative paths enter the store. No symlink traversal.
    private func url(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw failure("Invalid workspace path") }
        if path == "/" { return directory }
        let pieces = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw failure("Invalid workspace path") }
        var result = directory
        for piece in pieces {
            result.appendPathComponent(String(piece))
            if let attrs = try? fm.attributesOfItem(atPath: result.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw failure("Symbolic links are not supported")
            }
        }
        return result
    }

    private func inventory() throws -> [String] {
        var result = ["/"]
        var scanError: Error?
        // iOS app-container paths may use /var while enumeration returns /private/var.
        // Enumerate a canonical root and compare components, never slice by the
        // caller's path length (that can manufacture nonexistent child paths).
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = root.pathComponents
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { _, error in scanError = error; return false }) else { throw failure("Could not read workspace") }
        while let child = enumerator.nextObject() as? URL {
            guard try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw failure("Symbolic links are not supported") }
            let components = child.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else { throw failure("Invalid workspace entry path") }
            result.append("/" + components.dropFirst(rootComponents.count).joined(separator: "/"))
        }
        if let scanError { throw scanError }
        return result.sorted()
    }

    private func metadata(_ target: URL) throws -> [String: Any] {
        let attrs = try fm.attributesOfItem(atPath: target.path)
        let type = attrs[.type] as? FileAttributeType
        guard type == .typeDirectory || type == .typeRegular else { throw failure("Unsupported workspace entry") }
        return ["isFile": type == .typeRegular, "isDirectory": type == .typeDirectory, "isSymbolicLink": false,
                "mode": (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 420,
                "size": (attrs[.size] as? NSNumber)?.intValue ?? 0,
                "mtime": (attrs[.modificationDate] as? Date ?? .distantPast).timeIntervalSince1970 * 1000]
    }

    private func checkCapacity(replacing target: URL? = nil, bytes: Int = 0, extraEntries: Int = 0) throws {
        let paths = try inventory()
        var total = bytes
        for path in paths {
            let file = try url(path)
            if file == target { continue }
            let info = try metadata(file)
            if info["isFile"] as? Bool == true { total += info["size"] as? Int ?? 0 }
        }
        guard total <= NativeWorkspaceFiles.maxBytes else { throw failure("Workspace exceeds the 8 MB limit") }
        guard paths.count - 1 + extraEntries <= NativeWorkspaceFiles.maxEntries else { throw failure("Workspace exceeds the 2,000-entry limit") }
    }

    func beginCommand(_ id: String) throws { try prepare(); commandID = id; changes.removeAll() }
    func endCommand(_ id: String) { if commandID == id { commandID = nil } }
    func changedPaths() -> [String] { changes.sorted() }

    func snapshot() throws -> [NativeWorkspaceEntry] {
        try prepare()
        return try inventory().filter { $0 != "/" }.map { path in
            let target = try url(path), info = try metadata(target)
            let isFile = info["isFile"] as? Bool == true
            return NativeWorkspaceEntry(path: "/workspace" + path, type: isFile ? "file" : "directory", mode: info["mode"] as? Int ?? 420, content: isFile ? try Data(contentsOf: target).base64EncodedString() : nil)
        }
    }

    func importEntries(_ entries: [NativeWorkspaceEntry]) throws {
        try prepare()
        let merged = try NativeWorkspaceFiles.merge(existing: snapshot(), incoming: entries)
        let stage = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try NativeWorkspaceFiles.export(merged, to: stage)
        // Both directories are on the same app volume; swapping is atomic, including on crash.
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, directory.path, UInt32(RENAME_SWAP)) == 0 else {
            throw failure("Could not commit imported workspace (\(errno))")
        }
        entries.forEach { changes.insert($0.path) }
    }

    func readFile(_ path: String) throws -> String {
        try prepare()
        let relative = "/" + (try NativeWorkspaceFiles.relativePath(path))
        guard let text = String(data: try Data(contentsOf: url(relative)), encoding: .utf8) else { throw failure("File is not UTF-8 text") }
        return text
    }

    func writeFile(_ path: String, content: String) throws {
        let relative = "/" + (try NativeWorkspaceFiles.relativePath(path))
        _ = try handle(["method": "writeFile", "path": relative, "content": Data(content.utf8).base64EncodedString()])
    }

    func saveArtifact(_ path: String, data: Data, commandID: String? = nil) throws {
        let relative = "/" + (try NativeWorkspaceFiles.relativePath(path))
        let parent = (relative as NSString).deletingLastPathComponent
        if parent != "/" { _ = try handle(["method": "mkdir", "path": parent, "recursive": true], commandID: commandID) }
        _ = try handle(["method": "writeFile", "path": relative, "content": data.base64EncodedString()], commandID: commandID)
    }

    /// The bridge accepts only filesystem operations, never device paths or code.
    func handle(_ request: [String: Any], commandID expected: String? = nil) throws -> [String: Any] {
        if let expected, expected != commandID { throw failure("Shell command was cancelled") }
        try prepare()
        guard let method = request["method"] as? String else { throw failure("Missing filesystem operation") }
        let path = request["path"] as? String ?? "/"
        let target = try url(path)
        var value: Any = NSNull()
        var mutated = false
        switch method {
        case "index": value = try inventory()
        case "readFile":
            guard try metadata(target)["isFile"] as? Bool == true else { throw failure("EISDIR: \(path)") }
            value = try Data(contentsOf: target).base64EncodedString()
        case "stat": value = try metadata(target)
        case "exists": value = fm.fileExists(atPath: target.path)
        case "readdir": value = try fm.contentsOfDirectory(atPath: target.path).sorted()
        case "writeFile", "appendFile":
            guard path != "/", let encoded = request["content"] as? String, let bytes = Data(base64Encoded: encoded) else { throw failure("Invalid file contents") }
            let exists = fm.fileExists(atPath: target.path)
            if exists, try metadata(target)["isFile"] as? Bool != true { throw failure("EISDIR: \(path)") }
            var data = method == "appendFile" && exists ? try Data(contentsOf: target) : Data()
            data.append(bytes)
            try checkCapacity(replacing: target, bytes: data.count, extraEntries: exists ? 0 : 1)
            try data.write(to: target, options: .atomic)
            mutated = true
        case "mkdir":
            let recursive = request["recursive"] as? Bool == true
            if fm.fileExists(atPath: target.path) {
                guard recursive, try metadata(target)["isDirectory"] as? Bool == true else { throw failure("EEXIST: \(path)") }
            } else {
                var missing = 1, parent = target.deletingLastPathComponent()
                while parent.path != directory.path && !fm.fileExists(atPath: parent.path) { missing += 1; parent.deleteLastPathComponent() }
                try checkCapacity(extraEntries: missing)
                try fm.createDirectory(at: target, withIntermediateDirectories: recursive)
                mutated = true
            }
        case "rm":
            guard path != "/" else { throw failure("Cannot remove the workspace mount") }
            if fm.fileExists(atPath: target.path) {
                if try metadata(target)["isDirectory"] as? Bool == true, request["recursive"] as? Bool != true,
                   !(try fm.contentsOfDirectory(atPath: target.path)).isEmpty { throw failure("ENOTEMPTY: \(path)") }
                let removed = try inventory().filter { $0 == path || $0.hasPrefix(path + "/") }
                try fm.removeItem(at: target)
                removed.forEach { changes.insert("/workspace" + $0) }
                mutated = true
            } else if request["force"] as? Bool != true { throw failure("ENOENT: \(path)") }
        case "mv":
            guard path != "/", let destination = request["destination"] as? String, destination != "/" else { throw failure("Invalid move") }
            let dest = try url(destination)
            guard !destination.hasPrefix(path + "/") else { throw failure("Cannot move a folder into itself") }
            let moved = try inventory().filter { $0 == path || $0.hasPrefix(path + "/") }
            guard rename(target.path, dest.path) == 0 else { throw failure("Could not move \(path) (\(errno))") }
            for old in moved { changes.insert("/workspace" + old); changes.insert("/workspace" + destination + old.dropFirst(path.count)) }
            mutated = true
        case "chmod":
            guard let mode = request["mode"] as? Int else { throw failure("Missing mode") }
            try fm.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: target.path); mutated = true
        case "utimes":
            guard let mtime = request["mtime"] as? Double else { throw failure("Missing modification time") }
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime / 1000)], ofItemAtPath: target.path); mutated = true
        default: throw failure("Unsupported filesystem operation: \(method)")
        }
        var response: [String: Any] = ["value": value]
        if mutated { changes.insert(path == "/" ? "/workspace" : "/workspace" + path); response["paths"] = try inventory() }
        return response
    }
}
