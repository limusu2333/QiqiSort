import AppKit
import QuartzCore

extension App {
    func buildWorkspace() {
        NSApp.appearance = NSAppearance(named: .aqua)
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出七七整理台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 850),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "七七整理台 · 婚礼底片整理"
        window.titlebarAppearsTransparent = true; window.backgroundColor = Memphis.paper
        window.minSize = NSSize(width: 1000, height: 820)
        let root = DropView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]; window.contentView = root
        root.received = { [weak self] in self?.addInputs($0) }
        root.canReceive = { [weak self] in self?.busy == false }
        root.highlight = { [weak self] in self?.importSurface.highlighted = $0 }
        let background = WorkspaceBackground(); root.addSubview(background); pin(background, to: root)

        configureImportControls()
        choose.target = self; choose.action = #selector(selectInputs)
        clearInput.target = self; clearInput.action = #selector(clearInputs); clearInput.isHidden = true
        openExisting.target = self; openExisting.action = #selector(openExistingResult)
        styleButton(clearInput, symbol: "xmark", compact: true)
        styleButton(openExisting, symbol: "folder.badge.magnifyingglass")
        startGroups.target = self; startGroups.action = #selector(runGroups)
        startOrganize.target = self; startOrganize.action = #selector(runOrganize)
        cancel.target = self; cancel.action = #selector(stop); cancel.isEnabled = false
        pause.target = self; pause.action = #selector(togglePause); pause.isEnabled = false
        reveal.target = self; reveal.action = #selector(openOutput); reveal.isEnabled = false
        resume.target = self; resume.action = #selector(resumeTask)
        review.target = self; review.action = #selector(openReview)
        styleButton(choose, symbol: "folder.badge.plus"); choose.fill = Memphis.pink
        styleButton(startGroups, primary: true, symbol: "person.3.fill")
        styleButton(startOrganize, symbol: "square.grid.2x2.fill"); startOrganize.fill = Memphis.mint
        styleButton(cancel, symbol: "stop.fill", compact: true)
        cancel.toolTip = "结束本次处理，只保存续作记录，不导出照片"
        styleButton(pause, symbol: "pause.fill")
        pause.toolTip = "完成当前照片后暂停，点击继续可接着处理"
        styleButton(resume, symbol: "arrow.clockwise")
        styleButton(reveal, symbol: "folder", compact: true)
        styleButton(review, symbol: "rectangle.on.rectangle")
        for button in [choose, startGroups, startOrganize, pause, review] {
            button.widthAnchor.constraint(equalToConstant: button.intrinsicContentSize.width).isActive = true
        }
        choose.keyEquivalent = "o"; choose.keyEquivalentModifierMask = .command

        let brand = row([Branding.mark(size:30),label(Branding.name,21,.black,.white)],spacing:9)
        let brandPlate = PaperSurface(); brandPlate.fill = ink; brandPlate.accent = Memphis.pink
        brandPlate.install(brand, padding: 9)
        brandPlate.widthAnchor.constraint(equalToConstant: 200).isActive = true
        brandPlate.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let header = row([brandPlate, label("婚礼底片工作台", 14, .semibold), spacer(),
                          StatusBadge("本地处理", color: Memphis.mint), taskBadge], spacing: 16)
        let title = row([label("这一次，好好归档。", 28, .bold), spacer()], spacing: 24)

        let artwork = importPreview
        artwork.heightAnchor.constraint(equalToConstant: 104).isActive = true
        importTitle.alignment = .center; importTitle.maximumNumberOfLines = 2
        importDetail.alignment = .center; importDetail.maximumNumberOfLines = 2
        importDetail.stringValue = "尚未选择底片"
        let importHeading = row([label("01", 12, .bold, Memphis.blue), label("导入底片", 12, .semibold), importPath, showImportPaths, expandImport], spacing: 8)
        let center = column([spacer(), artwork, importTitle, importDetail, row([choose, clearInput], spacing: 10), spacer()], spacing: 13)
        center.alignment = .centerX
        fullWidth([artwork, importTitle, importDetail], in: center)
        let importBody = column([importHeading, center], spacing: 16)
        fullWidth([importHeading, center], in: importBody)
        center.setContentHuggingPriority(.init(1), for: .vertical)
        importSurface.accent = Memphis.yellow; importSurface.install(importBody, padding: 26)
        let meters = [metric("已处理", number: originalCount, symbol: "photo.stack", color: Memphis.yellow),
                      metric("合影入选", number: groupCount, symbol: "person.3.fill", color: Memphis.pink),
                      metric("待决定", number: exceptionCount, symbol: "hand.raised", color: Memphis.mint),
                      metric("处理失败", number: pendingCount, symbol: "exclamationmark", color: Memphis.lavender)]
        metricCards = meters.enumerated().map { index, surface in
            let card = MetricCard(surface: surface, title: MetricFilter(rawValue: index)!.title)
            card.tag = index; card.target = self; card.action = #selector(openMetric(_:)); return card
        }
        let right = column([row([label("02", 12, .bold, Memphis.blue), label("分类进度", 12, .semibold), spacer()])] + metricCards, spacing: 10)
        fullWidth(right.arrangedSubviews, in: right)
        right.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let workspace = row([importSurface, right], spacing: 24); workspace.alignment = .top
        importSurface.heightAnchor.constraint(equalTo: right.heightAnchor).isActive = true
        importSurface.widthAnchor.constraint(equalTo: workspace.widthAnchor, constant: -304).isActive = true

        burstControl.font = .systemFont(ofSize: 12)
        timeStatus.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium)
        timeStatus.maximumNumberOfLines = 1; timeStatus.setContentCompressionResistancePriority(.required,for:.horizontal)
        let options = row([burstControl, spacer(), timeStatus, openExisting, resume], spacing: 16)
        let runBand = NSView(); runBand.wantsLayer = true; runBand.layer?.backgroundColor = ink.cgColor
        status.font = .systemFont(ofSize: 12, weight: .medium); status.textColor = .white
        status.maximumNumberOfLines = 2; status.stringValue = "等待底片"
        percentage.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        percentage.widthAnchor.constraint(equalToConstant: 50).isActive = true
        percentage.alignment = .right
        let progressRow = row([progressPrint, percentage], spacing: 14)
        progressPrint.heightAnchor.constraint(equalToConstant: 16).isActive = true
        progressPrint.setContentHuggingPriority(.init(1), for: .horizontal)
        let progressArea = column([status, progressRow], spacing: 9)
        fullWidth([status, progressRow], in: progressArea)
        progressArea.setContentHuggingPriority(.init(1), for: .horizontal)
        progressRow.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = row([startGroups, startOrganize, pause, cancel, progressArea, reveal, review], spacing: 10)
        runBand.addSubview(actions); pin(actions, to: runBand, inset: 18)
        runBand.heightAnchor.constraint(equalToConstant: 82).isActive = true
        progressArea.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1

        correctionNotice.maximumNumberOfLines = 1; correctionNotice.lineBreakMode = .byTruncatingMiddle
        correctionNotice.setContentCompressionResistancePriority(.init(200),for:.horizontal)
        let activityHeading = row([label("处理记录",12,.bold), correctionNotice, spacer(),label("点选照片记录查看判断",10,.medium,mutedInk)],spacing:10)
        log.string = "尚无处理记录。"; log.autoresizingMask = [.width]
        let scroll = NSScrollView(); scroll.documentView = log; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.scrollerStyle = .overlay
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:40).isActive = true
        scroll.setContentHuggingPriority(.init(1),for:.vertical)
        let fileHeading = label("照片",10,.semibold,mutedInk); fileHeading.widthAnchor.constraint(equalToConstant:180).isActive = true
        let resultHeading = label("结果",10,.semibold,mutedInk); resultHeading.widthAnchor.constraint(equalToConstant:88).isActive = true; resultHeading.alignment = .center
        let columnHeading = row([fileHeading,resultHeading,label("简要说明",10,.semibold,mutedInk),spacer()],spacing:8)
        let activityBody = column([activityHeading,columnHeading,scroll],spacing:6); fullWidth(activityBody.arrangedSubviews,in:activityBody)
        let activityPanel = PaperSurface(); activityPanel.accent = Memphis.mint; activityPanel.install(activityBody,padding:12)
        activityPanel.setContentHuggingPriority(.init(1),for:.vertical)
        let foot = row([label(Branding.name, 10, .bold, mutedInk), spacer(), label("底片整理 / 合影筛选", 10, .medium, mutedInk)])
        let stack = column([header, title, workspace, options, runBand, activityPanel, foot], spacing: 10)
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        fullWidth(stack.arrangedSubviews, in: stack)
    }
    func animateImport() {
        guard !Memphis.reduceMotion else { return }
        importSurface.wantsLayer = true
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.55; animation.toValue = 1; animation.duration = 0.22
        importSurface.layer?.add(animation, forKey: "import-feedback")
    }
}
