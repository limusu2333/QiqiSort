import AppKit

extension App {
    func acceptTiming(_ item:PipelineProgress) {
        timingCompleted = item.completed; timingTotal = item.total
        if let remaining = item.remainingSeconds,remaining.isFinite,remaining >= 0 {
            if cancellation.isPauseRequested { pausedRemaining = remaining }
            else { estimatedFinish = Date().addingTimeInterval(remaining) }
        }
        updateClock()
    }
    func updateClock() {
        guard let started = processingStarted else { return }
        let elapsed = "已用 " + Self.duration(Date().timeIntervalSince(started)-cancellation.pausedDuration)
        let estimate:String
        if interactiveEdit?.kind == .editing { estimate = "等待本张纠错，保存后继续" }
        else if interactiveEdit != nil { estimate = "保存进度，准备本张复核" }
        else if cancellation.isCancelled { estimate = busy ? "已停止 · 正在保存" : "已停止" }
        else if !busy { estimate = timingFinishedState }
        else if cancellation.isPauseRequested {
            estimate = cancellation.isPaused ? "已暂停" : "正在暂停"
            if cancellation.isPaused {
                taskBadge.text.stringValue = "已暂停"
                status.stringValue = "已暂停 · 已处理\(originalCount.stringValue)组 · 合影\(groupCount.stringValue)组；点击继续，或结束保存续作记录。"
            }
        } else if timingTotal > 0 && timingCompleted >= timingTotal { estimate = "正在整理与保存结果" }
        else if let finish = estimatedFinish,finish.timeIntervalSinceNow > 0 {
            let format = DateFormatter(); format.dateFormat = "HH:mm"
            estimate = "预计剩余 " + Self.duration(ceil(finish.timeIntervalSinceNow)) + " · 约" + format.string(from:finish) + "完成"
        } else { estimate = estimatedFinish == nil ? "预计完成 正在估算" : "预计完成 正在更新估算" }
        timeStatus.stringValue = elapsed + "  ·  " + estimate
        timeStatus.toolTip = "根据本次已完成照片的耗时动态估算；暂停时间不计入处理耗时。"
    }
}
