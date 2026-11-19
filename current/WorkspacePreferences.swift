import Foundation

/// Core Foundation preferences ignore CFFIXED_USER_HOME on some macOS releases.
/// Validation therefore uses an explicit file, never the real user's last task.
enum WorkspacePreferences {
    private static var isolated: URL? {
        ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"].map {
            URL(fileURLWithPath:$0).appendingPathComponent("Library/Application Support/GATHER/workspace-preferences.json")
        }
    }
    static func string(forKey key: String) -> String? {
        if let isolated { return (try? CurationFiles.read([String:String].self, isolated))?[key] }
        return UserDefaults.standard.string(forKey:key)
    }
    static func set(_ value: String, forKey key: String) {
        if let isolated {
            do {
                try FileManager.default.createDirectory(at:isolated.deletingLastPathComponent(),withIntermediateDirectories:true)
                var values = (try? CurationFiles.read([String:String].self,isolated)) ?? [:]
                values[key] = value; try CurationFiles.write(values,isolated)
            } catch { fputs("检查设置保存失败：\(error.localizedDescription)\n",stderr) }
        } else { UserDefaults.standard.set(value,forKey:key) }
    }
}
