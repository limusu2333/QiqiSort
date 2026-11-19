import AppKit

enum Branding {
    static let name = "七七整理台"
    static func configureProcess() { ProcessInfo.processInfo.processName = name }
    static func icon() -> NSImage? {
        guard let root = try? ProjectResources().root else { return nil }
        return NSImage(contentsOf:root.appendingPathComponent("branding/qiqi-icon.png"))
    }
    static func apply(to app:NSApplication) {
        if let icon = icon() { app.applicationIconImage = icon; app.dockTile.display() }
    }
    static func mark(size:CGFloat)->NSImageView {
        let view = NSImageView(); view.image = icon(); view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant:size),view.heightAnchor.constraint(equalToConstant:size)])
        view.setAccessibilityLabel("七七整理台，小猫照片整理员")
        return view
    }
}
enum BrandingValidation {
    static func run(output:URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"),"品牌检查需要独立用户目录")
        let fm = FileManager.default; try fm.createDirectory(at:output,withIntermediateDirectories:true)
        let app = NSApplication.shared, owner = App(); app.delegate = owner; app.setActivationPolicy(.regular)
        owner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
        RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        let info = Bundle.main.infoDictionary ?? [:]
        let runningName = NSRunningApplication.current.localizedName ?? ""
        try FrontendValidation.require(info["CFBundleDisplayName"] as? String == Branding.name && info["CFBundleIdentifier"] as? String == "GroupPicker", "显示名或原有设置标识错误")
        try FrontendValidation.require(ProcessInfo.processInfo.processName == Branding.name && runningName == Branding.name,"系统仍显示旧启动名称："+runningName)
        try FrontendValidation.require((app.applicationIconImage?.size.width ?? 0) >= 512 && owner.window.title.hasPrefix(Branding.name),"Dock图标或窗口品牌未接入")
        guard let icon = Branding.icon(),let actualIcon = app.applicationIconImage,
              let expected = normalized(icon),let actual = normalized(actualIcon),
              let expectedPixels = expected.bitmapData,let actualPixels = actual.bitmapData else { throw GatherError.message("图标像素无法验证") }
        let count = expected.bytesPerRow * expected.pixelsHigh
        let difference = (0..<count).reduce(0.0) { $0 + abs(Double(expectedPixels[$1])-Double(actualPixels[$1])) } / Double(count)
        try FrontendValidation.require(difference < 8,"系统图标像素与新素材不符：\(difference)")
        if let data = actual.representation(using:.png,properties:[:]) { try data.write(to:output.appendingPathComponent("actual-icon.png")) }
        try FrontendValidation.capture(owner.window,at:output.appendingPathComponent("main.png"),controls:[owner.importSurface,owner.metricCards[0]])
        let recordRoot = output.appendingPathComponent("ui-fixture")
        let source = URL(fileURLWithPath:".build/live-wedding-smoke-vU2nCw/organize").standardizedFileURL
        try fm.createDirectory(at:recordRoot,withIntermediateDirectories:true)
        try fm.copyItem(at:CurationFiles.directory(source),to:CurationFiles.directory(recordRoot))
        let review = try ReviewWindow(root:recordRoot)
        try FrontendValidation.require(review.window?.title.hasPrefix(Branding.name) == true,"选片工作台未改名")
        try FrontendValidation.capture(review.window!,at:output.appendingPathComponent("review.png"),controls:[review.browser.gridScroll,review.export])
        try CurationFiles.write(["status":"passed","processName":ProcessInfo.processInfo.processName,"systemLocalizedName":runningName,"settingsIdentity":Bundle.main.bundleIdentifier ?? "","iconMeanPixelDifference":String(difference),"checks":"嵌入显示名称、原设置标识保留、系统实际应用名称、运行时图标、主界面与选片界面品牌、原生窗口边界"],output.appendingPathComponent("receipt.json"))
        review.close(); owner.window.orderOut(nil)
    }
    static func normalized(_ image:NSImage)->NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:128,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context = NSGraphicsContext(bitmapImageRep:bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x:0,y:0,width:128,height:128))
        image.draw(in:NSRect(x:0,y:0,width:128,height:128),from:.zero,operation:.sourceOver,fraction:1)
        NSGraphicsContext.restoreGraphicsState(); return bitmap
    }

}
