import AppKit

final class CacheLaunchPanel: NSWindowController {
    let titleLabel = label("正在清理临时缓存",22,.bold)
    let detail = label("原片、任务结果与学习经验会保留",12,.regular,mutedInk)
    let progress = NSProgressIndicator()
    init() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:260),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "七七整理台 · 准备工作台"; window.isReleasedWhenClosed = false
        super.init(window:window)
        let paper = PaperSurface(); paper.accent = Memphis.pink
        window.contentView = paper; window.appearance = NSAppearance(named:.aqua)
        let icon = NSImageView(); icon.image = NSApplication.shared.applicationIconImage; icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant:70).isActive = true; icon.heightAnchor.constraint(equalToConstant:70).isActive = true
        let brand = label("七七整理台",13,.bold)
        let headings = NSStackView(views:[brand,titleLabel]); headings.orientation = .vertical; headings.alignment = .leading; headings.spacing = 8
        let hero = NSStackView(views:[icon,headings]); hero.spacing = 16; hero.alignment = .centerY
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil)
        progress.widthAnchor.constraint(equalToConstant:380).isActive = true
        let body = NSStackView(views:[hero,progress,detail]); body.orientation = .vertical; body.alignment = .centerX; body.spacing = 22
        paper.install(body,padding:32)
        window.setAccessibilityLabel("七七整理台启动准备")
    }
    required init?(coder:NSCoder) { fatalError() }
    func finish(_ report:CacheMaintenance.Report) {
        progress.stopAnimation(nil); progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.doubleValue = 1
        if !report.errors.isEmpty {
            titleLabel.stringValue = "工作台已就绪"
            detail.stringValue = "本次缓存暂未清理，任务与经验已保留"
        } else if report.files > 0 {
            titleLabel.stringValue = "临时缓存已清理"
            detail.stringValue = "清理\(report.files)项 · 回收" + ByteCountFormatter.string(fromByteCount:report.bytes,countStyle:.file)
            if report.deferred > 0 { detail.stringValue += " · 待续作任务已保留" }
        } else {
            titleLabel.stringValue = "准备就绪"
            detail.stringValue = report.deferred > 0 ? "待续作或使用中的任务缓存已保留" : "没有需要清理的临时缓存"
        }
        detail.toolTip = detail.stringValue
    }
}

extension App {
    func prepareLaunch() {
        launchPreparing = true
        let panel = CacheLaunchPanel(); launchPanel = panel
        window.beginSheet(panel.window!)
        CacheMaintenance.onLaunch(recent:recentTaskRoot) { [weak self,weak panel] report in
            guard let self,let panel else { return }
            self.cacheCleanupReport = report; panel.finish(report)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.55) { [weak self,weak panel] in
                guard let self,let panel else { return }
                if let sheet = panel.window { self.window.endSheet(sheet); sheet.orderOut(nil) }
                self.launchPanel = nil; self.launchPreparing = false
            }
        }
    }
}
