import SwiftUI
import AVFoundation

@main
struct SiriApp: App {
    
    init() {
        // 在应用启动时设置全局音频会话，确保媒体音频从扬声器输出
        setupGlobalAudioSession()
        
        // 生成高频不可听音频文件
        generateInaudibleAudioFile()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
    private func setupGlobalAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 使用 playAndRecord 模式支持同时播放和录音，确保从扬声器输出
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true)
            // 强制设置音频路由到扬声器
            try audioSession.overrideOutputAudioPort(.speaker)
            print("🎵 全局音频会话设置成功 - 强制扬声器输出")
        } catch {
            print("❌ 全局音频会话设置失败: \(error.localizedDescription)")
        }
    }
    
    private func generateInaudibleAudioFile() {
        // 在后台异步生成音频文件，避免阻塞应用启动
        DispatchQueue.global(qos: .background).async {
            let audioFileManager = AudioFileManager()
            if let fileURL = audioFileManager.generateInaudibleAudioFile() {
                print("🔊 高频不可听音频文件已准备: \(fileURL.lastPathComponent)")
            } else {
                print("❌ 生成高频音频文件失败")
            }
        }
    }
}
