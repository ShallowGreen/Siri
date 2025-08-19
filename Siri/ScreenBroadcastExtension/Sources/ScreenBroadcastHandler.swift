import ReplayKit
import Foundation
import CoreMedia
import os.log

@objc(ScreenBroadcastHandler)
public class ScreenBroadcastHandler: RPBroadcastSampleHandler {
    
    private let logger = Logger(subsystem: "dev.tuist.Siri.ScreenBroadcastExtension", category: "Broadcast")
    private let appGroupID = "group.dev.tuist.Siri"
    
    // 状态管理
    private var isRecording = false
    private var audioFrameCount: Int64 = 0
    
    // MARK: - Broadcast Lifecycle
    
    public override init() {
        super.init()
        logger.info("🎬 ScreenBroadcastHandler 初始化")
    }
    
    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        logger.info("🚀 屏幕直播开始")
        logger.info("📋 启动参数: \(setupInfo ?? [:])")
        
        // 设置录制状态
        isRecording = true
        audioFrameCount = 0
        
        // 通知主程序直播已开始
        updateStatus(status: "started", message: "屏幕直播已开始")
        
        logger.info("✅ 屏幕直播启动完成")
    }
    
    public override func broadcastFinished() {
        logger.info("🛑 屏幕直播结束")
        
        isRecording = false
        
        // 通知主程序直播已结束
        updateStatus(status: "finished", message: "屏幕直播已结束")
        
        logger.info("✅ 屏幕直播结束完成")
    }
    
    public override func finishBroadcastWithError(_ error: Error) {
        logger.error("❌ 屏幕直播发生错误: \(error.localizedDescription)")
        
        isRecording = false
        
        // 通知主程序直播发生错误
        updateStatus(status: "error", message: "直播错误: \(error.localizedDescription)")
        
        logger.error("❌ 屏幕直播错误处理完成")
        super.finishBroadcastWithError(error)
    }
    
    // MARK: - Sample Buffer Processing
    
    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isRecording else {
            return
        }
        
        // 检查是否收到停止指令
        checkForStopCommand()
        
        switch sampleBufferType {
        case .audioApp:
            processAppAudio(sampleBuffer)
        case .audioMic:
            processMicAudio(sampleBuffer)
        case .video:
            processVideo(sampleBuffer)
        @unknown default:
            logger.error("❌ 未知的样本缓冲区类型")
        }
    }
    
    // MARK: - Audio Processing
    
    private func processAppAudio(_ sampleBuffer: CMSampleBuffer) {
        audioFrameCount += 1
        
        // 计算音频电平
        let audioLevel = calculateAudioLevel(sampleBuffer: sampleBuffer)
        
        // 每 30 帧发送一次音频数据到主程序
        if audioFrameCount % 30 == 0 {
            sendAudioDataToMainApp(audioLevel: audioLevel, frameCount: audioFrameCount)
        }
    }
    
    private func processMicAudio(_ sampleBuffer: CMSampleBuffer) {
        // 处理麦克风音频（如果需要）
        logger.debug("🎤 收到麦克风音频数据")
    }
    
    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        // 处理视频数据（如果需要）
        logger.debug("📹 收到视频数据")
    }
    
    // MARK: - Audio Level Calculation
    
    private func calculateAudioLevel(sampleBuffer: CMSampleBuffer) -> Double {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0.0
        }
        
        var dataPointer: UnsafeMutablePointer<Int8>?
        var dataLength: Int = 0
        
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        
        guard status == noErr, let pointer = dataPointer, dataLength > 0 else {
            return 0.0
        }
        
        // 将数据转换为 Float 并计算 RMS
        let samples = pointer.withMemoryRebound(to: Float.self, capacity: dataLength / MemoryLayout<Float>.size) { floatPointer in
            Array(UnsafeBufferPointer(start: floatPointer, count: dataLength / MemoryLayout<Float>.size))
        }
        
        if samples.isEmpty {
            return 0.0
        }
        
        // 计算 RMS (Root Mean Square)
        let sum = samples.reduce(0.0) { $0 + ($1 * $1) }
        let rms = sqrt(Double(sum) / Double(samples.count))
        
        // 转换为分贝并规范化到 0-1 范围
        let decibels = 20 * log10(max(rms, 1e-7))
        let normalizedLevel = max(0.0, min(1.0, (decibels + 60) / 60))
        
        return normalizedLevel
    }
    
    // MARK: - Communication with Main App
    
    private func sendAudioDataToMainApp(audioLevel: Double, frameCount: Int64) {
        let audioData: [String: Any] = [
            "audioLevel": audioLevel,
            "frameCount": frameCount,
            "timestamp": Date().timeIntervalSince1970,
            "isRecording": isRecording
        ]
        
        writeToAppGroup(fileName: "audio_data.json", data: audioData)
        
        logger.info("🎵 发送音频数据: 电平=\(String(format: "%.3f", audioLevel)), 帧数=\(frameCount)")
    }
    
    private func updateStatus(status: String, message: String) {
        let statusData: [String: Any] = [
            "status": status,
            "message": message,
            "timestamp": Date().timeIntervalSince1970,
            "isRecording": isRecording
        ]
        
        writeToAppGroup(fileName: "broadcast_status.json", data: statusData)
        logger.info("📡 状态更新: \(status) - \(message)")
    }
    
    // MARK: - File System Communication
    
    private func writeToAppGroup(fileName: String, data: [String: Any]) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("❌ 无法获取App Group容器路径")
            return
        }
        
        let fileURL = containerURL.appendingPathComponent(fileName)
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
            try jsonData.write(to: fileURL)
        } catch {
            logger.error("❌ 写入App Group文件失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Stop Command Processing
    
    private func checkForStopCommand() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let stopCommandURL = containerURL.appendingPathComponent("stop_command.json")
        
        if FileManager.default.fileExists(atPath: stopCommandURL.path) {
            logger.info("📥 收到主程序停止指令")
            
            // 删除指令文件
            try? FileManager.default.removeItem(at: stopCommandURL)
            
            // 停止直播
            finishBroadcastWithError(NSError(domain: "UserRequested", code: 0, userInfo: [NSLocalizedDescriptionKey: "用户通过主程序停止直播"]))
        }
    }
}
