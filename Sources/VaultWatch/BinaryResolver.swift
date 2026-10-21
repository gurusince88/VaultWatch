import Foundation

/// GUI apps do not inherit the shell PATH, so `ob` (a Node script with an
/// `#!/usr/bin/env node` shebang) fails silently unless we resolve both binaries
/// and hand the child an explicit PATH.
struct ResolvedBinaries {
    let ob: String
    let node: String?

    /// PATH for child processes: dirs of ob and node first, then common locations.
    var childPath: String {
        var dirs: [String] = []
        func add(_ p: String?) {
            guard let p = p, !p.isEmpty, !dirs.contains(p) else { return }
            dirs.append(p)
        }
        add((ob as NSString).deletingLastPathComponent)
        if let node = node { add((node as NSString).deletingLastPathComponent) }
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].forEach { add($0) }
        return dirs.joined(separator: ":")
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = childPath
        env["HOME"] = NSHomeDirectory()
        return env
    }
}

enum BinaryResolver {
    static func resolve() -> ResolvedBinaries? {
        guard let ob = find("ob") else { return nil }
        return ResolvedBinaries(ob: ob, node: find("node"))
    }

    static func find(_ name: String) -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
        ]
        // nvm: newest installed version first
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted().reversed() {
                candidates.append("\(nvmDir)/\(v)/bin/\(name)")
            }
        }
        // fnm
        let fnmDir = "\(home)/Library/Application Support/fnm/node-versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: fnmDir) {
            for v in versions.sorted().reversed() {
                candidates.append("\(fnmDir)/\(v)/installation/bin/\(name)")
            }
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return loginShellLookup(name)
    }

    /// Last resort: ask a login shell, which loads the user's real PATH.
    private static func loginShellLookup(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
