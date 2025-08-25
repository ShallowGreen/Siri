import SwiftUI
import AVFoundation

@main
struct SiriApp: App {
    
    init() {
        // 在应用启动时设置全局音频会话，确保媒体音频从扬声器输出
        setupGlobalAudioSession()
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
}
