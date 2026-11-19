import AppKit
import CryptoKit
import Darwin

struct ReleaseManifest: Codable {
    struct Part: Codable { let name: String; let size: Int64; let sha256: String }
    let version: Int
    let tag, repository, rootFolder, executable, executableSHA256: String
    let archiveSize, unpackedSize: Int64
    let archiveSHA256: String
    let parts: [Part]
    func validate() throws {
        guard version == 1, !parts.isEmpty, archiveSize > 0, unpackedSize > 0,
              repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              tag.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              rootFolder == "七七理片研究版", executable == "原项目/runtime/七七整理台",
              parts.reduce(Int64(0), { $0 + $1.size }) == archiveSize,
              Set(parts.map(\.name)).count == parts.count,
              [archiveSHA256, executableSHA256].allSatisfy({ $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }),
              parts.allSatisfy({ $0.size > 0 && $0.name.range(of: #"^QiqiSort-Research-data\.zip\.[0-9]{3}$"#, options: .regularExpression) != nil && $0.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }) else {
            throw InstallError.message("研究版资源清单无效，请重新下载官方启动器。")
        }
    }
}
enum InstallError: Error, LocalizedError {
    case message(String), cancelled
    var errorDescription: String? {
        switch self { case .message(let text): return text; case .cancelled: return "已暂停安装，下载进度已保留。" }
    }
}
final class ResearchInstaller {
    let manifest: ReleaseManifest
    let destination, cache: URL
    var localAssets: URL?
    var progress: ((String, String, Double) -> Void)?
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private let fm = FileManager.default
    init(manifest: ReleaseManifest, destination: URL, cache: URL, localAssets: URL?) throws {
        try manifest.validate(); self.manifest = manifest; self.destination = destination; self.cache = cache; self.localAssets = localAssets
    }
    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }
    func checkCancellation() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw InstallError.cancelled } }
    func report(_ title: String, _ detail: String, _ fraction: Double) { progress?(title, detail, min(1, max(0, fraction))) }
    func digest(_ url: URL, update: ((Int64) -> Void)? = nil) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(), count: Int64 = 0
        while let data = try file.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try checkCancellation(); hash.update(data: data); count += Int64(data.count); update?(count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func size(_ url: URL) -> Int64 { (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }
    func installed() -> Bool {
        guard let data = try? Data(contentsOf: destination.appendingPathComponent(".qiqisort-install.json")),
              let marker = try? JSONDecoder().decode([String: String].self, from: data), marker["archiveSHA256"] == manifest.archiveSHA256 else { return false }
        return (try? digest(destination.appendingPathComponent(manifest.executable))) == manifest.executableSHA256
    }
    private func run(_ executable: String, _ arguments: [String], log: URL) throws {
        try checkCancellation()
        fm.createFile(atPath: log.path, contents: nil)
        let errorFile = try FileHandle(forWritingTo: log); defer { try? errorFile.close() }
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.standardOutput = FileHandle.nullDevice; child.standardError = errorFile
        lock.lock()
        if cancelled { lock.unlock(); throw InstallError.cancelled }
        process = child
        do { try child.run(); lock.unlock() } catch { process = nil; lock.unlock(); throw error }
        child.waitUntilExit()
        lock.lock(); process = nil; lock.unlock()
        try checkCancellation()
        guard child.terminationStatus == 0 else {
            let data = (try? Data(contentsOf: log)) ?? Data()
            let message = String(decoding: data.suffix(1800), as: UTF8.self)
            throw InstallError.message("资源准备未完成，可再次点击继续。\n" + message)
        }
    }
    func install() throws -> URL {
        if installed() { return destination }
        guard !fm.fileExists(atPath: destination.path) else {
            throw InstallError.message("安装位置已有一个未通过本版校验的文件夹：\n\(destination.path)\n请保留其中的资料，先将该文件夹改名，再重新安装。")
        }
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let lockURL = cache.appendingPathComponent("install.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw InstallError.message("无法创建安装锁，请检查缓存目录权限。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw InstallError.message("另一个窗口正在准备同一研究版，请先回到那个窗口。") }
        defer { flock(descriptor, LOCK_UN) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let free = (try fm.attributesOfFileSystem(forPath: cache.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let cachedBytes = manifest.parts.reduce(Int64(0)) { $0 + min($1.size, size(cache.appendingPathComponent($1.name))) }
        let localComplete = localAssets.map { dir in manifest.parts.allSatisfy { size(dir.appendingPathComponent($0.name)) == $0.size } } ?? false
        let needed = manifest.unpackedSize + manifest.archiveSize + (localComplete ? 0 : max(0, manifest.archiveSize - cachedBytes)) + 512_000_000
        guard free >= needed else { throw InstallError.message("磁盘可用空间不足。此次准备还需约 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))；请腾出空间后继续，已下载部分会保留。") }
        var files = [URL](), completed: Int64 = 0
        for part in manifest.parts {
            try checkCancellation()
            let cached = cache.appendingPathComponent(part.name)
            let local = localAssets?.appendingPathComponent(part.name)
            let source: URL
            if let local, fm.fileExists(atPath: local.path) { source = local }
            else {
                source = cached
                if size(cached) != part.size {
                    if size(cached) > part.size { try fm.removeItem(at: cached) }
                    report("正在下载完整研究版", "支持断点续传，暂停后再次打开可继续。", Double(completed) / Double(manifest.archiveSize) * 0.6)
                    let before = completed
                    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    timer.schedule(deadline: .now(), repeating: .milliseconds(300))
                    timer.setEventHandler { [weak self] in
                        guard let self else { return }
                        let now = before + min(self.size(cached), part.size)
                        self.report("正在下载完整研究版", "\(ByteCountFormatter.string(fromByteCount: now, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: self.manifest.archiveSize, countStyle: .file)) · 可暂停续传", Double(now) / Double(self.manifest.archiveSize) * 0.6)
                    }
                    timer.resume()
                    do {
                        defer { timer.cancel() }
                        let url = "https://github.com/\(manifest.repository)/releases/download/\(manifest.tag)/\(part.name)"
                        try run("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--retry-delay", "2", "--connect-timeout", "20", "--continue-at", "-", "--output", cached.path, url], log: cache.appendingPathComponent("download.log"))
                    }
                }
            }
            report("正在校验下载资源", "核对分包 \(files.count + 1)/\(manifest.parts.count)，确保文件完整。", 0.6)
            guard size(source) == part.size, try digest(source) == part.sha256 else {
                if source == cached { try? fm.removeItem(at: cached) }
                throw InstallError.message("分包校验不通过：\(part.name)。请重新下载；其他已校验分包会保留。")
            }
            files.append(source); completed += part.size
        }
        let archive = cache.appendingPathComponent("complete.zip")
        report("正在合并与核对资源", "程序自动完成，不需要手动操作。", 0.65)
        fm.createFile(atPath: archive.path, contents: nil)
        let output = try FileHandle(forWritingTo: archive)
        do {
            try output.truncate(atOffset: 0)
            var hash = SHA256(), count: Int64 = 0
            for file in files {
                let input = try FileHandle(forReadingFrom: file)
                do {
                    defer { try? input.close() }
                    while let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                        try checkCancellation(); try output.write(contentsOf: data); hash.update(data: data); count += Int64(data.count)
                        report("正在合并与核对资源", "已核对 \(ByteCountFormatter.string(fromByteCount: count, countStyle: .file))", 0.65 + Double(count) / Double(manifest.archiveSize) * 0.15)
                    }
                }
            }
            try output.close()
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard count == manifest.archiveSize, actual == manifest.archiveSHA256 else { throw InstallError.message("完整资源校验不通过，请重新取得本版全部分包。") }
        } catch { try? output.close(); throw error }
        let expanded = cache.appendingPathComponent("expanded", isDirectory: true)
        if fm.fileExists(atPath: expanded.path) { try fm.removeItem(at: expanded) }
        try fm.createDirectory(at: expanded, withIntermediateDirectories: true)
        report("正在安装本地程序与模型", "安装完成后可离线运行。", 0.82)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path], log: cache.appendingPathComponent("extract.log"))
        try checkCancellation()
        let payload = expanded.appendingPathComponent(manifest.rootFolder)
        let program = payload.appendingPathComponent(manifest.executable)
        guard fm.isExecutableFile(atPath: program.path), try digest(program) == manifest.executableSHA256,
              program.resolvingSymlinksInPath().path.hasPrefix(payload.path + "/") else {
            throw InstallError.message("解压后的程序未通过校验，请重新安装。")
        }
        let marker = try JSONEncoder().encode(["archiveSHA256": manifest.archiveSHA256, "tag": manifest.tag])
        try marker.write(to: payload.appendingPathComponent(".qiqisort-install.json"), options: .atomic)
        try fm.moveItem(at: payload, to: destination)
        for file in [archive, expanded, cache.appendingPathComponent("download.log"), cache.appendingPathComponent("extract.log")] + manifest.parts.map({ cache.appendingPathComponent($0.name) }) {
            try? fm.removeItem(at: file)
        }
        report("研究版已准备好", "完整程序与本地模型已安装，正在打开工作台。", 1)
        return destination
    }
    func launch() throws {
        let child = Process(); child.executableURL = destination.appendingPathComponent(manifest.executable)
        child.currentDirectoryURL = destination.appendingPathComponent("原项目")
        var environment = ProcessInfo.processInfo.environment
        for key in ["DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_INSERT_LIBRARIES"] { environment.removeValue(forKey: key) }
        child.environment = environment; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
    }
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}
func loadManifest() throws -> ReleaseManifest {
    let url = argument("--manifest").map { URL(fileURLWithPath: $0) } ?? Bundle.main.url(forResource: "release-manifest", withExtension: "json")
    guard let url else { throw InstallError.message("启动器缺少资源清单，请重新解压研究版启动器。") }
    return try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: url))
}
func makeInstaller() throws -> ResearchInstaller {
    let manifest = try loadManifest()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let destination = argument("--destination").map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Applications").appendingPathComponent(manifest.rootFolder)
    let cache = argument("--cache").map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Library/Caches/QiqiSortResearchInstaller").appendingPathComponent(manifest.tag)
    let local = argument("--assets-dir").map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL.deletingLastPathComponent()
    return try ResearchInstaller(manifest: manifest, destination: destination, cache: cache, localAssets: local)
}
if CommandLine.arguments.contains("--install-only") {
    do { let installer = try makeInstaller(); let path = try installer.install(); print("安装与资源校验通过：\(path.path)"); exit(0) }
    catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
}

final class LauncherUI: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 510), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let title = NSTextField(labelWithString: "让七七先准备好，再开始研究。")
    let detail = NSTextField(wrappingLabelWithString: "首次打开会自动下载完整程序与本地模型。\n以后可以离线运行，无需安装开发工具或配置密钥。")
    let bar = NSProgressIndicator()
    let primary = NSButton(title: "下载并安装研究版", target: nil, action: nil)
    let offline = NSButton(title: "选择离线分包文件夹…", target: nil, action: nil)
    var installer: ResearchInstaller?
    var selectedAssets: URL?
    var busy = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window.title = "七七理片 · 学习研究版"
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        let content = window.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 1).cgColor
        if let image = NSImage(named: NSImage.applicationIconName) {
            let icon = NSImageView(frame: NSRect(x: 38, y: 337, width: 106, height: 106)); icon.image = image; content.addSubview(icon)
        }
        let brand = NSTextField(labelWithString: "七七理片 · QiqiSort"); brand.font = .boldSystemFont(ofSize: 29); brand.frame = NSRect(x: 167, y: 389, width: 580, height: 44); content.addSubview(brand)
        let byline = NSTextField(labelWithString: "摄影师七七 × 李A 联合构建"); byline.font = .systemFont(ofSize: 15); byline.textColor = .secondaryLabelColor; byline.frame = NSRect(x: 169, y: 359, width: 540, height: 26); content.addSubview(byline)
        title.font = .boldSystemFont(ofSize: 24); title.frame = NSRect(x: 44, y: 292, width: 720, height: 36); content.addSubview(title)
        detail.font = .systemFont(ofSize: 16); detail.frame = NSRect(x: 44, y: 216, width: 710, height: 62); content.addSubview(detail)
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1; bar.frame = NSRect(x: 44, y: 179, width: 710, height: 18); content.addSubview(bar)
        let notice = NSTextField(wrappingLabelWithString: "仅供学习研究与技术讨论，禁止商业软件开发及商业产品／服务使用。\nMobileCLIP2 官方许可排除商业经营、产品开发和商业产品／服务使用。"); notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabelColor; notice.frame = NSRect(x: 44, y: 112, width: 710, height: 48); content.addSubview(notice)
        primary.bezelStyle = .rounded; primary.bezelColor = NSColor(calibratedRed: 0.5, green: 0.84, blue: 0.74, alpha: 1); primary.font = .boldSystemFont(ofSize: 16); primary.frame = NSRect(x: 482, y: 43, width: 274, height: 46); primary.target = self; primary.action = #selector(begin); content.addSubview(primary)
        offline.bezelStyle = .rounded; offline.frame = NSRect(x: 38, y: 45, width: 250, height: 40); offline.target = self; offline.action = #selector(chooseOffline); content.addSubview(offline)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        do {
            let current = try makeInstaller()
            if current.installed() { installer = current; try current.launch(); NSApp.terminate(nil) }
        } catch { show(error) }
        if let path = argument("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.snapshot(path); exit(0) }
        }
    }
    @objc func chooseOffline() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "选择本版全部数据分包所在的文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { selectedAssets = panel.url; detail.stringValue = "已选择本地分包。点击安装后会先校验完整性，无需手动合并。" }
    }
    @objc func begin() {
        if busy { installer?.cancel(); primary.isEnabled = false; title.stringValue = "正在暂停，进度会保留…"; return }
        do {
            let current = try makeInstaller(); if let selectedAssets { current.localAssets = selectedAssets }; installer = current
            current.progress = { [weak self] title, detail, fraction in DispatchQueue.main.async { self?.title.stringValue = title; self?.detail.stringValue = detail; self?.bar.doubleValue = fraction } }
            busy = true; primary.title = "暂停安装"; offline.isEnabled = false
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try current.install()
                    DispatchQueue.main.async {
                        self.busy = false
                        do { try current.launch(); NSApp.terminate(nil) } catch { self.show(error); self.reset() }
                    }
                } catch { DispatchQueue.main.async { self.busy = false; self.reset(); self.title.stringValue = "资源准备尚未完成"; self.detail.stringValue = error.localizedDescription; if !(error is InstallError && error.localizedDescription == InstallError.cancelled.localizedDescription) { self.show(error) } } }
            }
        } catch { show(error) }
    }
    func reset() { primary.title = "继续安装研究版"; primary.isEnabled = true; offline.isEnabled = true }
    func show(_ error: Error) { let alert = NSAlert(); alert.messageText = "七七理片研究版"; alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "知道了"); alert.runModal() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { installer?.cancel(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func snapshot(_ path: String) {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}
let app = NSApplication.shared
let delegate = LauncherUI()
app.delegate = delegate
app.run()
