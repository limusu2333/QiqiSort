import AppKit

extension ReviewWindow {
    var currentDraftChoice: PhotoChoice? {
        guard let current, let exception = currentException else { return nil }
        return drafts[exception.id]?.first { $0.recordID == current.id }
    }
    func refreshDecisionFeedback() {
        let choice = currentDraftChoice, editing = choice != nil
        let rejecting = choice?.selected == false
        reject.title = rejecting ? "改为保留" : "不选此张"
        reject.symbolName = rejecting ? "checkmark" : "xmark"
        reject.fill = rejecting ? Memphis.mint : Memphis.pink
        reject.invalidateIntrinsicContentSize()
        reject.toolTip = rejecting ? "撤回这次不选，改为保留；保存后生效" : "将当前照片设为不选，保留原类别；保存后生效"
        reject.setAccessibilityLabel(reject.title)
        rejectionReason.isHidden = !rejecting
        rejectionReason.isEnabled = rejecting && !exporting
        if savingDecision {
            editNotice.stringValue = "正在保存决定，请稍候…"; editNotice.textColor = Memphis.blue
        } else if editing {
            editNotice.stringValue = rejecting ? "已设为不选 · 尚未保存。点击下方保存按钮生效。" : "调整中 · 尚未保存。可改为不选，或取消调整。"
            editNotice.textColor = rejecting ? .systemRed : Memphis.blue
        } else {
            editNotice.stringValue = lastDecisionMessage; editNotice.textColor = NSColor(hex: 0x187A63)
        }
        if editing && afterInteractiveEdit != nil { editNotice.stringValue += " 所有调整保存或取消后继续本场任务。" }
        editNotice.isHidden = editNotice.stringValue.isEmpty
        let grouped = (currentException?.recordIDs.count ?? 1) > 1
        submit.title = rejecting && !grouped ? "保存不选决定" : "保存\(grouped ? "本组" : "本张")决定"
        role.isEnabled = editing && !rejecting && !exporting
        submit.invalidateIntrinsicContentSize()
    }
    @objc func toggleRejection() {
        guard !exporting, let current, plan.photos.contains(where: { $0.recordID == current.id }) else { return }
        stashReason()
        let wasEditing = currentDraftChoice != nil, undoRejection = currentDraftChoice?.selected == false
        if !wasEditing { beginAdjustment() }
        guard currentDraftChoice != nil else { return }
        keep.state = wasEditing && undoRejection ? .on : .off
        changeChoice(); display()
        if keep.state == .off { reason.scrollToVisible(reason.bounds) }
    }
    @objc func chooseRejectionReason() {
        guard currentDraftChoice?.selected == false, rejectionReason.indexOfSelectedItem > 0,
              let selected = rejectionReason.titleOfSelectedItem else { return }
        stashReason()
        if selected != "其他原因（手动填写）" {
            let preset = selected
            if !reason.stringValue.contains(preset) {
                let existing = reason.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                reason.stringValue = existing.isEmpty ? preset : existing + "\n" + preset
            }
            stashReason()
        }
        rejectionReason.selectItem(at: 0)
        reason.scrollToVisible(reason.bounds); window?.makeFirstResponder(reason)
        refreshDecisionFeedback()
    }
}
