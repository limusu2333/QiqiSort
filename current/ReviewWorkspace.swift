import AppKit

final class TopAlignedDocument: NSView {
    override var isFlipped: Bool { true }
}

final class PhotoStage: NSView {
    let viewport = NSScrollView()
    let imageView: NSImageView
    private var viewportSize = NSSize.zero
    init(imageView: NSImageView) {
        self.imageView = imageView; super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor(hex: 0x222222).cgColor
        viewport.drawsBackground = false; viewport.borderType = .noBorder
        viewport.allowsMagnification = true; viewport.minMagnification = 1; viewport.maxMagnification = 4
        viewport.hasHorizontalScroller = true; viewport.hasVerticalScroller = true
        viewport.scrollerStyle = .overlay; viewport.autohidesScrollers = true
        viewport.documentView = imageView; addSubview(viewport); pin(viewport, to: self, inset: 12)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let size = viewport.contentSize
        if size != viewportSize && size.width > 0 && size.height > 0 {
            viewportSize = size; viewport.magnification = 1
            imageView.frame = NSRect(origin: .zero, size: size)
        }
    }
    func resetZoom() { viewport.magnification = 1 }
    @objc func enlarge() { changeZoom(by: 1.4) }
    @objc func reduce() { changeZoom(by: 1 / 1.4) }
    private func changeZoom(by factor: CGFloat) {
        let center = NSPoint(x: viewport.contentView.bounds.midX, y: viewport.contentView.bounds.midY)
        viewport.setMagnification(min(4, max(1, viewport.magnification * factor)), centeredAt: center)
    }
}

final class CandidateButton: NSButton {
    var recordID = ""
    var active = false { didSet { needsDisplay = true } }
    var kept = false
    var loading: PreviewTicket?
    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 3, dy: 3)
        NSColor(hex: 0x222222).setFill(); frame.fill()
        if let image {
            let ratio = min((frame.width - 6) / image.size.width, (frame.height - 6) / image.size.height)
            let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                 width: size.width, height: size.height))
        }
        (active ? Memphis.blue : Memphis.ink.withAlphaComponent(0.3)).setStroke()
        let outline = NSBezierPath(rect: frame); outline.lineWidth = active ? 3 : 1; outline.stroke()
        if kept {
            Memphis.mint.setFill(); NSBezierPath(rect: NSRect(x: frame.maxX - 17, y: frame.maxY - 17, width: 14, height: 14)).fill()
            NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.draw(in: NSRect(x: frame.maxX - 15, y: frame.maxY - 15, width: 10, height: 10))
        }
    }
}

extension ReviewWindow {
    func buildReviewWorkspace() {
        guard let window, let root = window.contentView else { return }
        browser = ReviewBrowser(owner: self)
        window.delegate = self; window.titlebarAppearsTransparent = true; window.backgroundColor = Memphis.paper
        let background = WorkspaceBackground(); root.addSubview(background); pin(background, to: root)
        styleButton(back, symbol: "chevron.left", compact: true)
        styleButton(next, symbol: "chevron.right", compact: true)
        styleButton(photoNote,symbol:"note.text")
        styleButton(adjust, symbol: "slider.horizontal.3")
        styleButton(reject, symbol: "xmark"); reject.fill = Memphis.pink
        styleButton(submit, primary: true, symbol: "checkmark")
        styleButton(discard, symbol: "arrow.uturn.backward", compact: true)
        styleButton(forget, symbol: "brain", compact: true)
        styleButton(export, symbol: "square.and.arrow.up"); export.fill = Memphis.mint
        styleButton(memories, symbol: "brain")
        styleButton(applyTaskMemory, symbol: "arrow.triangle.2.circlepath")
        applyTaskMemory.widthAnchor.constraint(equalToConstant: 150).isActive = true
        styleButton(clearMarks, symbol: "mappin.slash", compact: true)
        filter.controlSize = .large; filter.font = .systemFont(ofSize: 12, weight: .semibold)
        categoryFilter.widthAnchor.constraint(equalToConstant: 230).isActive = true
        categoryFilter.font = .systemFont(ofSize: 12)
        let title = row([row([Branding.mark(size:32),label(Branding.name,21,.black)],spacing:8), label(plan.mode == .groups ? "只挑合影" : "选片工作台", 14, .semibold), spacer(), applyTaskMemory, memories, reviewBadge], spacing: 16)
        let navigation = row([filter, spacer(), position, back, next], spacing: 12)

        caption.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        caption.textColor = mutedInk; caption.maximumNumberOfLines = 1; caption.lineBreakMode = .byTruncatingMiddle
        photo.noteMenuContext = { [weak self] in
            guard let self,let current = self.current,let note = self.onPhotoNote else { return nil }
            return PhotoNoteMenuContext(files:current.sources.map { URL(fileURLWithPath:$0) },note: { note(current) })
        }
        photoStage = PhotoStage(imageView: photo)
        styleButton(zoomOut, symbol: "minus.magnifyingglass", compact: true)
        styleButton(zoomIn, symbol: "plus.magnifyingglass", compact: true)
        zoomOut.target = photoStage; zoomOut.action = #selector(PhotoStage.reduce)
        zoomIn.target = photoStage; zoomIn.action = #selector(PhotoStage.enlarge)
        let photoHeading = row([caption, spacer(), photoNote, zoomOut, zoomIn], spacing: 8)
        photoStage.addSubview(emptyPhoto); emptyPhoto.alignment = .center
        emptyPhoto.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyPhoto.centerXAnchor.constraint(equalTo: photoStage.centerXAnchor),
            emptyPhoto.centerYAnchor.constraint(equalTo: photoStage.centerYAnchor),
            emptyPhoto.widthAnchor.constraint(lessThanOrEqualTo: photoStage.widthAnchor, constant: -40),
            photoStage.heightAnchor.constraint(equalToConstant: 180)
        ])
        photoStage.setContentHuggingPriority(.init(1), for: .vertical)
        candidateScroll.documentView = candidateStrip; candidateScroll.hasHorizontalScroller = true
        candidateScroll.hasVerticalScroller = false; candidateScroll.drawsBackground = false
        candidateStrip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            candidateStrip.leadingAnchor.constraint(equalTo: candidateScroll.contentView.leadingAnchor),
            candidateStrip.topAnchor.constraint(equalTo: candidateScroll.contentView.topAnchor),
            candidateStrip.heightAnchor.constraint(equalToConstant: 88),
            candidateScroll.heightAnchor.constraint(equalToConstant: 102)
        ])
        let gallery = column([browser.search, row([browser.sort, spacer(), browser.size], spacing: 8), browser.gridScroll], spacing: 10)
        fullWidth(gallery.arrangedSubviews, in: gallery)
        browser.gridScroll.setContentHuggingPriority(.init(1), for: .vertical)
        browser.categoriesScroll.widthAnchor.constraint(equalToConstant: 184).isActive = true

        info.font = .systemFont(ofSize: 12); info.textColor = mutedInk; info.maximumNumberOfLines = 4
        destination.font = .systemFont(ofSize: 14, weight: .bold); destination.maximumNumberOfLines = 2
        category.font = .systemFont(ofSize: 12); role.font = .systemFont(ofSize: 12)
        category.heightAnchor.constraint(equalToConstant: 30).isActive = true
        role.heightAnchor.constraint(equalToConstant: 30).isActive = true
        keep.font = .systemFont(ofSize: 13, weight: .semibold)
        rejectionReason.font = .systemFont(ofSize: 12); rejectionReason.isHidden = true
        editNotice.font = .systemFont(ofSize: 12, weight: .medium); editNotice.maximumNumberOfLines = 3; editNotice.isHidden = true
        choiceNotice.font = .systemFont(ofSize: 12)
        choiceNotice.textColor = .systemRed
        choiceNotice.isHidden = true
        remember.font = .systemFont(ofSize: 12)
        memoryScope.addItems(withTitles: ["用于今后的同类照片", "仅用于这张照片", "仅用于本次任务"])
        memoryScope.font = .systemFont(ofSize: 12)
        memoryScope.toolTip = "本次决定的长期经验适用范围"
        reason.font = .systemFont(ofSize: 12); reason.placeholderString = "可补充原因，帮助今后分类更准"
        reason.cell?.wraps = true; reason.cell?.isScrollable = false; reason.maximumNumberOfLines = 4
        reason.heightAnchor.constraint(equalToConstant: 70).isActive = true
        let sidebarContent = column([
            photoHeading, photoStage, row([mark, spacer(), clearMarks], spacing: 8),
            row([label("当前归档", 12, .semibold), spacer(), forget]), destination, rule(),
            row([adjust, spacer(), reject], spacing: 8), editNotice, keep,
            label("照片分类", 11, .semibold, mutedInk), category, choiceNotice,
            label("补充原因（可选）", 12, .semibold), rejectionReason, reason, remember, memoryScope, rule(),
            label("保留用途", 11, .semibold, mutedInk), role,
            label("识别与异常", 12, .semibold), info, candidateTitle, candidateScroll
        ], spacing: 8)
        fullWidth(sidebarContent.arrangedSubviews, in: sidebarContent)
        let sidebarScroll = NSScrollView(); sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        let sidebarDocument = TopAlignedDocument(); sidebarScroll.documentView = sidebarDocument
        sidebarDocument.addSubview(sidebarContent)
        sidebarDocument.translatesAutoresizingMaskIntoConstraints = false
        sidebarContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarDocument.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
            sidebarContent.leadingAnchor.constraint(equalTo: sidebarDocument.leadingAnchor),
            sidebarContent.trailingAnchor.constraint(equalTo: sidebarDocument.trailingAnchor, constant: -12),
            sidebarContent.topAnchor.constraint(equalTo: sidebarDocument.topAnchor),
            sidebarContent.bottomAnchor.constraint(equalTo: sidebarDocument.bottomAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 340)
        ])
        let separator = NSView(); separator.wantsLayer = true; separator.layer?.backgroundColor = ink.withAlphaComponent(0.16).cgColor
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let body = row([browser.categoriesScroll, gallery, separator, sidebarScroll], spacing: 16); body.alignment = .top
        NSLayoutConstraint.activate([
            gallery.heightAnchor.constraint(equalTo: body.heightAnchor),
            sidebarScroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            separator.heightAnchor.constraint(equalTo: body.heightAnchor),
            browser.categoriesScroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            gallery.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -573)
        ])
        body.setContentHuggingPriority(.init(1), for: .vertical)
        let bottom = row([label(plan.mode == .groups ? "只导出入选合影 · 原片保留不动" : "原片保留不动", 11, .medium, mutedInk), spacer(), discard, submit, export], spacing: 12)
        let divider = rule()
        let stack = column([title, navigation, body, divider, bottom], spacing: 16)
        root.addSubview(stack); pin(stack, to: root, inset: 24); fullWidth(stack.arrangedSubviews, in: stack)
    }

    func refreshBadge(editing: Bool) {
        if applyingLearning { reviewBadge.text.stringValue = "正在应用经验"; reviewBadge.color = Memphis.yellow }
        else if exporting { reviewBadge.text.stringValue = "正在导出"; reviewBadge.color = Memphis.yellow }
        else if editing { reviewBadge.text.stringValue = "决定未保存"; reviewBadge.color = Memphis.yellow }
        else { reviewBadge.text.stringValue = "待决定 \(plan.pendingCount) 组"; reviewBadge.color = plan.pendingCount > 0 ? Memphis.pink : Memphis.mint }
    }

    func refreshCandidates() {
        for view in candidateStrip.arrangedSubviews { (view as? CandidateButton)?.loading?.cancel(); candidateStrip.removeArrangedSubview(view); view.removeFromSuperview() }
        guard let current else { candidateTitle.stringValue = "没有候选照片"; return }
        let candidates: [ResultRecord]
        if let exception = currentException {
            candidates = exception.recordIDs.compactMap { id in records.first { $0.id == id } }
            candidateTitle.stringValue = "同组候选 · \(candidates.count) 张"
        } else {
            let location = visible.firstIndex { $0.id == current.id } ?? 0
            candidates = Array(visible[max(0, location - 2)..<min(visible.count, location + 4)])
            candidateTitle.stringValue = "附近照片"
        }
        for record in candidates {
            let button = CandidateButton(); button.isBordered = false; button.title = ""
            button.recordID = record.id
            button.loading = previewLoader.request(record, pixels: 400) { [weak button] image in
                guard button?.recordID == record.id else { return }; button?.image = image
            }
            button.active = current.id == record.id; button.target = self; button.action = #selector(selectCandidate(_:))
            let choice = currentException.flatMap { drafts[$0.id]?.first { $0.recordID == record.id } }
                ?? plan.photos.first { $0.recordID == record.id }?.choice
            button.kept = choice?.selected == true; button.isEnabled = !exporting
            button.toolTip = URL(fileURLWithPath: record.preview).lastPathComponent
            button.setAccessibilityLabel(button.toolTip)
            candidateStrip.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 112).isActive = true
            button.heightAnchor.constraint(equalToConstant: 84).isActive = true
        }
    }

    @objc func selectCandidate(_ sender: CandidateButton) {
        stashReason()
        if let target = visible.firstIndex(where: { $0.id == sender.recordID }) { index = target; display() }
        else {
            filter.selectedSegment = 0; categoryFilter.selectItem(at: 0); rebuild()
            if let target = visible.firstIndex(where: { $0.id == sender.recordID }) { index = target; display() }
        }
    }
}
