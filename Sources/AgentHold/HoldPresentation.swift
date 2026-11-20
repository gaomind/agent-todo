import Foundation

extension HoldItem {
    var actionTitle: String {
        let label = /^(?i:恢复条件|等待事项|阻塞原因|Waiting for|Blocked on)\s*[:：]\s*/
        let request = /^(?:麻烦(?:你|您)?|请(?:你|您)?|我(?:还|仍)?需要(?:你|您))\s*(?=(?:先)?(?:确认|提供|授权|决定|选择|回复|核对|上传|批准|合并|同步|手动|等待|不要|勿))/
        let completedLead = /^(?:部署|发布)已发起[，,]\s*(?=(?:等|待).+后)/
        let genericContinuation = /[，,]\s*(?:然后|之后)我再继续(?:处理|操作|验收)?[。.!！…]*$/
        let oneLine = condition.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var title = oneLine
        if let prefix = title.prefixMatch(of: label) { title.removeSubrange(prefix.range) }
        if let prefix = title.prefixMatch(of: request) {
            title.removeSubrange(prefix.range)
            if let suffix = title.firstMatch(of: genericContinuation) { title.removeSubrange(suffix.range) }
        }
        if let prefix = title.prefixMatch(of: completedLead) { title.removeSubrange(prefix.range) }
        return title.isEmpty ? oneLine : title
    }

    func copyText(sourceContext: (text: String, isTruncated: Bool)?) -> String {
        var metadata = ["状态：\(status.label)"]
        if let cwd, !cwd.isEmpty {
            if !project.isEmpty { metadata.append("项目：\(project)") }
            metadata.append("项目目录：\(cwd)")
        }
        metadata.append("\(provider.name) 会话：\(sessionID.uuidString.lowercased())")
        if let turnID, !turnID.isEmpty { metadata.append("轮次：\(turnID)") }
        metadata.append("记录时间：\(detectedAt.ISO8601Format())")

        var sections = [clipboardHeading, "当前恢复条件\n\(condition)", metadata.joined(separator: "\n")]
        if let sourceContext {
            let heading = sourceContext.isTruncated ? "原始 \(provider.name) 回复（已截断）" : "原始 \(provider.name) 回复"
            sections.append("\(heading)\n\(sourceContext.text)")
        } else if !evidence.isEmpty {
            sections.append("原始 \(provider.name) 回复（已保存摘录）\n\(evidence)")
        }
        return sections.joined(separator: "\n\n")
    }
}
