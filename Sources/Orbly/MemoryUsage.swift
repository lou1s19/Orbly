import Foundation

/// Reads the memory usage (RSS) of individual processes through /bin/ps.
/// Enough for the dashboard display, without private APIs.
enum MemoryUsage {
    static func residentBytes(pids: [pid_t], completion: @escaping ([pid_t: UInt64]) -> Void) {
        guard !pids.isEmpty else {
            completion([:])
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-o", "pid=,rss=", "-p", pids.map(String.init).joined(separator: ",")]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice

            var result: [pid_t: UInt64] = [:]
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                    if cols.count == 2, let pid = pid_t(cols[0]), let rssKB = UInt64(cols[1]) {
                        result[pid] = rssKB * 1024
                    }
                }
            } catch {
                NSLog("Orbly: ps for the memory display failed: \(error)")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func format(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1024 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }
}
