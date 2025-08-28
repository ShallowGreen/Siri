import Foundation
import ReplayKit
import Combine
import UIKit
import AVFoundation
import os.log

public class ScreenBroadcastManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published public var isRecording: Bool = false
    @Published public var broadcastStatus: String = "未开始"
    @Published public var audioLevel: Double = 0.0
    @Published public var audioFrameCount: Int64 = 0
    @Published public var errorMessage: String? = nil
    @Published public var audioRecordings: [AudioRecording] = []
    @Published public var currentRecordingFileName: String? = nil
    
    // MARK: - Private Properties
    private let appGroupID = "group.dev.tuist.Siri2"
    private let logger = Logger(subsystem: "dev.tuist.Siri", category: "ScreenBroadcast")
    private var statusCheckTimer: Timer?
    private let audioFileManager = AudioFileManager()
    private var audioPlayer: AVAudioPlayer?
    private var darwinNotificationCenter: CFNotificationCenter?
    
    // MARK: - Initialization
    
    public init() {
        logger.info("📱 ScreenBroadcastManager 初始化")
        clearPreviousData()
        loadAudioRecordings()
        setupAudioSession()
        setupDarwinNotifications()
    }
    
    deinit {
        stopStatusMonitoring()
        removeDarwinNotifications()
    }
    
    // MARK: - Public Methods
    
    public func showBroadcastPicker() {
        logger.info("🎛️ 显示系统直播选择器...")
        errorMessage = nil
        
        clearPreviousData()
        
        DispatchQueue.main.async {
            self.showSystemBroadcastPicker()
        }
    }
    
    public func stopBroadcast() {
        guard isRecording else {
            logger.info("⚠️ 当前没有进行直播")
            return
        }
        
        logger.info("⏹️ 用户请求停止屏幕直播")
        
        // 发送停止指令到扩展
        let stopCommand: [String: Any] = [
            "command": "stop",
            "timestamp": Date().timeIntervalSince1970,
            "source": "main_app"
        ]
        
        writeToAppGroup(fileName: "stop_command.json", data: stopCommand)
        logger.info("📤 已发送停止指令到扩展")
    }
    
    // MARK: - System Broadcast Picker
    
    private func showSystemBroadcastPicker() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            logger.error("❌ 无法获取活动窗口")
            errorMessage = "无法启动直播：应用窗口不可用"
            return
        }
        
        logger.info("🎛️ 显示系统直播选择器")
        
        let broadcastPicker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        broadcastPicker.preferredExtension = "dev.tuist.Siri.ScreenBroadcastExtension"
        broadcastPicker.showsMicrophoneButton = false
        
        window.addSubview(broadcastPicker)
        
        // 延迟触发点击
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.triggerBroadcastPicker(broadcastPicker)
            
            // 开始监控扩展状态
            self.startStatusMonitoring()
            
            // 2秒后移除选择器
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                broadcastPicker.removeFromSuperview()
                self.logger.info("🧹 已移除选择器视图")
            }
        }
    }
    
    private func triggerBroadcastPicker(_ picker: RPSystemBroadcastPickerView) {
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                logger.info("🎯 找到选择器按钮，触发点击")
                button.sendActions(for: .touchUpInside)
                return
            }
        }
        
        // 备用触发方法
        picker.isHidden = false
        picker.alpha = 0.01
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for subview in picker.subviews {
                if let button = subview as? UIButton {
                    button.sendActions(for: .touchUpInside)
                    self.logger.info("✅ 延迟触发成功")
                    return
                }
            }
            self.logger.warning("⚠️ 无法找到触发按钮")
        }
    }
    
    // MARK: - Status Monitoring
    
    private func startStatusMonitoring() {
        stopStatusMonitoring()
        
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkBroadcastStatus()
        }
        
        logger.info("👁️ 开始状态监控")
    }
    
    private func stopStatusMonitoring() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = nil
        logger.info("👁️ 停止状态监控")
    }
    
    private func checkBroadcastStatus() {
        // 检查直播状态
        if let statusData = readFromAppGroup(fileName: "broadcast_status.json") {
            processBroadcastStatus(statusData)
        }
        
        // 检查音频通知
        if let notificationData = readFromAppGroup(fileName: "audio_notification.json") {
            processAudioNotification(notificationData)
        }
        
        // 只有在录制状态下才检查音频数据
        if isRecording {
            if let audioData = readFromAppGroup(fileName: "audio_data.json") {
                processAudioData(audioData)
            }
        }
    }
    
    // MARK: - Data Processing
    
    private func processBroadcastStatus(_ data: [String: Any]) {
        guard let status = data["status"] as? String,
              let message = data["message"] as? String else {
            return
        }
        
        logger.info("📊 扩展状态更新: \(status) - \(message)")
        
        DispatchQueue.main.async {
            self.broadcastStatus = message
            
            switch status {
            case "started":
                if !self.isRecording {
                    self.isRecording = true
                    self.logger.info("✅ 系统确认直播已开始，开始监听音频")
                }
            case "finished":
                if self.isRecording {
                    self.isRecording = false
                    self.stopStatusMonitoring()
                    self.logger.info("✅ 系统确认直播已结束，停止监听")
                    self.resetAudioData()
                }
            case "error":
                if self.isRecording {
                    self.isRecording = false
                    self.stopStatusMonitoring()
                    self.errorMessage = message
                    self.logger.error("❌ 直播发生错误: \(message)")
                    self.resetAudioData()
                }
            default:
                break
            }
        }
    }
    
    private func processAudioData(_ data: [String: Any]) {
        guard let audioLevel = data["audioLevel"] as? Double,
              let frameCount = data["frameCount"] as? Int64 else {
            return
        }
        
        DispatchQueue.main.async {
            self.audioLevel = audioLevel
            self.audioFrameCount = frameCount
        }
        
        // 输出音频数据日志
        logger.info("🎵 收到音频数据: 电平=\(String(format: "%.3f", audioLevel)), 帧数=\(frameCount)")
    }
    
    private func resetAudioData() {
        DispatchQueue.main.async {
            self.audioLevel = 0.0
            self.audioFrameCount = 0
        }
    }
    
    // MARK: - App Groups Communication
    
    private func readFromAppGroup(fileName: String) -> [String: Any]? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        
        let fileURL = containerURL.appendingPathComponent(fileName)
        
        do {
            let data = try Data(contentsOf: fileURL)
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            return json as? [String: Any]
        } catch {
            // 静默处理文件不存在的情况
            return nil
        }
    }
    
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
    
    private func clearPreviousData() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let fileNames = ["broadcast_status.json", "audio_data.json", "stop_command.json"]
        
        for fileName in fileNames {
            let fileURL = containerURL.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        logger.info("🧹 已清除之前的数据")
    }
    
    // MARK: - Audio Management
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 确保从扬声器输出，支持与其他音频混合
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // 强制设置音频路由到扬声器
            try audioSession.overrideOutputAudioPort(.speaker)
            try audioSession.setActive(true)
            logger.info("🎵 音频会话设置成功")
        } catch {
            logger.error("❌ 音频会话设置失败: \(error.localizedDescription)")
        }
    }
    
    public func loadAudioRecordings() {
        audioRecordings = audioFileManager.getAllRecordings()
        logger.info("📂 加载了 \(self.audioRecordings.count) 个音频文件")
    }
    
    public func playAudio(at url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            logger.info("▶️ 开始播放音频: \(url.lastPathComponent)")
        } catch {
            logger.error("❌ 播放音频失败: \(error.localizedDescription)")
            errorMessage = "播放失败: \(error.localizedDescription)"
        }
    }
    
    public func stopAudioPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        logger.info("⏹️ 停止音频播放")
    }
    
    public func deleteRecording(_ recording: AudioRecording) {
        if audioFileManager.deleteRecording(at: recording.fileURL) {
            loadAudioRecordings()
        }
    }
    
    public func convertRecordingToWAV(_ recording: AudioRecording) {
        // 只对M4A文件进行转换
        guard recording.fileName.hasSuffix(".m4a") else {
            logger.warning("⚠️ 只能转换M4A文件: \(recording.fileName)")
            return
        }
        
        logger.info("🔄 开始转换录音: \(recording.fileName)")
        
        // 在后台线程执行转换
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let wavURL = self?.audioFileManager.convertM4AToWAV(m4aURL: recording.fileURL) {
                DispatchQueue.main.async {
                    self?.logger.info("✅ 转换完成: \(wavURL.lastPathComponent)")
                    // 重新加载录音列表以显示新的WAV文件
                    self?.loadAudioRecordings()
                }
            } else {
                DispatchQueue.main.async {
                    self?.logger.error("❌ 转换失败: \(recording.fileName)")
                }
            }
        }
    }
    
    public func shareRecording(_ recording: AudioRecording) -> URL {
        return recording.fileURL
    }
    
    private func processAudioNotification(_ data: [String: Any]) {
        guard let event = data["event"] as? String else { return }
        
        switch event {
        case "audio_file_created":
            if let fileName = data["fileName"] as? String {
                DispatchQueue.main.async {
                    self.currentRecordingFileName = fileName
                    self.logger.info("🎙️ 新音频文件创建: \(fileName)")
                }
            }
            
        case "audio_file_completed":
            DispatchQueue.main.async {
                self.currentRecordingFileName = nil
                self.loadAudioRecordings()
                self.logger.info("✅ 音频文件完成")
            }
            
            
        default:
            break
        }
    }
    
    // MARK: - Darwin Notifications
    
    private func setupDarwinNotifications() {
        darwinNotificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        
        // 监听实时音频保存通知
        let notificationName = "dev.tuist.Siri.realtimeAudioSaved" as CFString
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        CFNotificationCenterAddObserver(
            darwinNotificationCenter,
            observer,
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let manager = Unmanaged<ScreenBroadcastManager>.fromOpaque(observer).takeUnretainedValue()
                manager.handleRealtimeAudioSavedNotification()
            },
            notificationName,
            nil,
            .deliverImmediately
        )
        
        logger.info("📡 Darwin通知监听已设置")
    }
    
    private func removeDarwinNotifications() {
        guard let center = darwinNotificationCenter else { return }
        
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName("dev.tuist.Siri.realtimeAudioSaved" as CFString),
            nil
        )
        
        logger.info("📡 Darwin通知监听已移除")
    }
    
    private func handleRealtimeAudioSavedNotification() {
        logger.info("📱 收到实时音频保存通知")
        
        // 读取通知文件获取详细信息
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let notificationURL = containerURL.appendingPathComponent("realtime_audio_notification.json")
        
        if let data = try? Data(contentsOf: notificationURL),
           let notification = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            processAudioNotification(notification)
        }
    }
}
