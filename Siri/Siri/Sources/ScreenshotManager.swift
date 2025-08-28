import Foundation
import SwiftUI
import os.log

public struct Screenshot: Identifiable, Equatable {
    public let id = UUID()
    public let image: UIImage
    public let fileName: String
    public let timestamp: Date
    public let associatedText: String
    public var isNew: Bool
    
    public static func == (lhs: Screenshot, rhs: Screenshot) -> Bool {
        return lhs.id == rhs.id
    }
}

public class ScreenshotManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published public var screenshots: [Screenshot] = []
    @Published public var latestScreenshot: UIImage? // 保留用于向后兼容
    @Published public var screenshotFileName: String = "" // 保留用于向后兼容
    @Published public var hasNewScreenshot: Bool = false
    
    // MARK: - Private Properties
    private let logger = Logger(subsystem: "dev.tuist.Siri", category: "ScreenshotManager")
    private let appGroupID = "group.dev.tuist.Siri2"
    private var fileMonitorTimer: Timer?
    
    // MARK: - Public Methods
    
    public init() {
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    public func startMonitoring() {
        // 每0.5秒检查一次新截图
        fileMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForNewScreenshots()
        }
        
        logger.info("📸 截图监控已启动")
    }
    
    public func stopMonitoring() {
        fileMonitorTimer?.invalidate()
        fileMonitorTimer = nil
        logger.info("📸 截图监控已停止")
    }
    
    public func triggerScreenshot(with recognizedText: String) {
        // 发送截图触发指令到ScreenBroadcastHandler
        let triggerData: [String: Any] = [
            "recognizedText": recognizedText,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("❌ 无法获取App Group容器路径")
            return
        }
        
        let triggerURL = containerURL.appendingPathComponent("screenshot_trigger.json")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: triggerData, options: [])
            try jsonData.write(to: triggerURL)
            logger.info("📸 截图触发指令已发送: \(recognizedText)")
        } catch {
            logger.error("❌ 发送截图触发指令失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    
    private func checkForNewScreenshots() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let notificationURL = containerURL.appendingPathComponent("screenshot_notification.json")
        
        guard FileManager.default.fileExists(atPath: notificationURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: notificationURL)
            if let notification = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let event = notification["event"] as? String,
               event == "screenshot_captured",
               let fileName = notification["fileName"] as? String,
               let filePath = notification["filePath"] as? String {
                
                // 加载新截图
                loadScreenshot(from: filePath, fileName: fileName)
                
                // 删除通知文件
                try? FileManager.default.removeItem(at: notificationURL)
            }
        } catch {
            logger.error("❌ 检查截图通知失败: \(error.localizedDescription)")
        }
    }
    
    private func loadScreenshot(from filePath: String, fileName: String) {
        let fileURL = URL(fileURLWithPath: filePath)
        
        guard FileManager.default.fileExists(atPath: filePath) else {
            logger.error("❌ 截图文件不存在: \(filePath)")
            return
        }
        
        guard let imageData = try? Data(contentsOf: fileURL),
              let image = UIImage(data: imageData) else {
            logger.error("❌ 无法加载截图: \(fileName)")
            return
        }
        
        // 从文件名提取时间信息
        let timestamp = Date()
        
        // 创建新的截图对象
        let screenshot = Screenshot(
            image: image,
            fileName: fileName,
            timestamp: timestamp,
            associatedText: "", // 稍后会通过其他方式关联文字
            isNew: true
        )
        
        DispatchQueue.main.async { [weak self] in
            // 添加到截图数组
            self?.screenshots.append(screenshot)
            
            // 保持向后兼容
            self?.latestScreenshot = image
            self?.screenshotFileName = fileName
            self?.hasNewScreenshot = true
            
            self?.logger.info("✅ 新截图已加载: \(fileName), 总数: \(self?.screenshots.count ?? 0)")
        }
    }
    
    public func markScreenshotAsViewed() {
        hasNewScreenshot = false
    }
    
    public func markScreenshotAsViewed(id: UUID) {
        if let index = screenshots.firstIndex(where: { $0.id == id }) {
            screenshots[index].isNew = false
        }
        
        // 检查是否还有新截图
        hasNewScreenshot = screenshots.contains { $0.isNew }
    }
    
    public func markAllScreenshotsAsViewed() {
        for index in screenshots.indices {
            screenshots[index].isNew = false
        }
        hasNewScreenshot = false
    }
    
    public func clearAllScreenshots() {
        screenshots.removeAll()
        latestScreenshot = nil
        screenshotFileName = ""
        hasNewScreenshot = false
        logger.info("🗑️ 已清空所有截图")
    }
    
    public func getNewScreenshotsCount() -> Int {
        return screenshots.filter { $0.isNew }.count
    }
}