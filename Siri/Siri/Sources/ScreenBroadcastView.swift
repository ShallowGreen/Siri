import SwiftUI
import AVFoundation
import MediaPlayer

public struct ScreenBroadcastView: View {
    @ObservedObject var broadcastManager: ScreenBroadcastManager
    @ObservedObject var realtimeAudioManager: RealtimeAudioStreamManager
    @ObservedObject var inaudibleAudioPlayer: InaudibleAudioPlayer
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var selectedRecording: AudioRecording?
    @State private var showingPlayer = false
    @State private var showingShareSheet = false
    @State private var recordingToShare: AudioRecording?
    @State private var showingClearAllAlert = false
    
    let pipManager: PictureInPictureManager?
    
    init(
        pipManager: PictureInPictureManager? = nil,
        broadcastManager: ScreenBroadcastManager,
        realtimeAudioManager: RealtimeAudioStreamManager,
        inaudibleAudioPlayer: InaudibleAudioPlayer
    ) {
        self.pipManager = pipManager
        self.broadcastManager = broadcastManager
        self.realtimeAudioManager = realtimeAudioManager
        self.inaudibleAudioPlayer = inaudibleAudioPlayer
    }
    
    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 标题
                headerSection
                
                // 状态信息
                statusSection
                
                // 控制按钮
                controlButtonSection
                
                // 实时音频识别显示区域（常显）
                realtimeRecognitionSection
                
                // 音频数据展示
                if broadcastManager.isRecording {
                    audioDataSection
                }
                
                // 录音列表
                if !broadcastManager.audioRecordings.isEmpty {
                    recordingsListSection
                }
                
                Spacer(minLength: 50)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
        .onReceive(broadcastManager.$errorMessage) { error in
            if let error = error, !error.isEmpty {
                alertMessage = error
                showingAlert = true
            }
        }
        .onReceive(realtimeAudioManager.$errorMessage) { error in
            if !error.isEmpty {
                alertMessage = error
                showingAlert = true
            }
        }
        .onReceive(broadcastManager.$isRecording) { isRecording in
            if isRecording {
                realtimeAudioManager.startMonitoring()
            } else {
                realtimeAudioManager.stopMonitoring()
            }
        }
        .onReceive(realtimeAudioManager.$recognizedText) { text in
            // Update PiP with media audio recognized text
            pipManager?.updateMediaText(text)
        }
        .alert("提示", isPresented: $showingAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
        }
        .alert("清空所有录音", isPresented: $showingClearAllAlert) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) {
                clearAllRecordings()
            }
        } message: {
            Text("确定要删除所有录音文件吗？此操作不可撤销。")
        }
        .sheet(isPresented: $showingPlayer) {
            if let recording = selectedRecording {
                AudioPlayerView(recording: recording)
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let recording = recordingToShare {
                ShareSheet(items: [recording.fileURL])
            }
        }
        .onAppear {
            broadcastManager.loadAudioRecordings()
        }
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "tv")
                .font(.system(size: 50))
                .foregroundColor(.blue)
            
            Text("屏幕直播")
                .font(.title)
                .fontWeight(.bold)
            
            Text("实时获取系统音频数据")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Status Section
    private var statusSection: some View {
        VStack(spacing: 15) {
            // 录制状态
            HStack {
                Circle()
                    .fill(broadcastManager.isRecording ? Color.red : Color.gray)
                    .frame(width: 12, height: 12)
                
                Text(broadcastManager.isRecording ? "正在直播" : "未开始")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            
            // 直播状态信息
            InfoCard(title: "📡 直播状态", content: broadcastManager.broadcastStatus)
        }
    }
    
    // MARK: - Control Button Section
    private var controlButtonSection: some View {
        VStack(spacing: 16) {
            // 主控制按钮
            Button(action: {
                if broadcastManager.isRecording {
                    broadcastManager.stopBroadcast()
                } else {
                    broadcastManager.showBroadcastPicker()
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: broadcastManager.isRecording ? "stop.fill" : "play.fill")
                        .font(.title2)
                    
                    Text(broadcastManager.isRecording ? "停止屏幕直播" : "显示直播选择器")
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(broadcastManager.isRecording ? Color.red : Color.blue)
                )
            }
            .disabled(false)
            
            // 音频控制按钮区域
            VStack(spacing: 12) {
                // 中断音乐按钮
                Button(action: {
                    inaudibleAudioPlayer.playInaudibleSound()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.title2)
                        
                        Text("中断后台音乐")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange)
                    )
                }
                
                // 恢复音乐按钮
                Button(action: {
                    inaudibleAudioPlayer.resumeBackgroundMusicComprehensive()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                        
                        Text("恢复后台音乐")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.green)
                    )
                }
                .opacity(inaudibleAudioPlayer.lastInterruptionTime != nil ? 1.0 : 0.6)
                .disabled(inaudibleAudioPlayer.lastInterruptionTime == nil)
                
                // 音频控制方法选择器
                HStack(spacing: 8) {
                    Button("会话重置") {
                        inaudibleAudioPlayer.resumeBackgroundMusicViaSessionReset()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button("远程命令") {
                        inaudibleAudioPlayer.resumeBackgroundMusicViaRemoteCommand()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button("通知恢复") {
                        inaudibleAudioPlayer.resumeBackgroundMusicViaNotification()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .opacity(inaudibleAudioPlayer.lastInterruptionTime != nil ? 1.0 : 0.4)
                .disabled(inaudibleAudioPlayer.lastInterruptionTime == nil)
            }
            
            // 说明文字
            VStack(spacing: 8) {
                Text(broadcastManager.isRecording ? 
                     "点击停止按钮将结束屏幕直播" : 
                     "点击显示直播选择器，然后在系统弹窗中选择开始")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Text("🔴 中断按钮: 播放高频不可听声音暂停后台音乐")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Text("🟢 恢复按钮: 使用多种方法尝试恢复后台音乐播放")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                if let lastTime = inaudibleAudioPlayer.lastInterruptionTime {
                    Text("最近中断时间: \(lastTime.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
    }
    
    // MARK: - Audio Data Section
    private var audioDataSection: some View {
        VStack(spacing: 15) {
            // 音频电平指示器
            VStack(alignment: .leading, spacing: 8) {
                Text("🎵 音频电平")
                    .font(.headline)
                
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // 背景
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 20)
                        
                        // 音频电平条
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(
                                gradient: Gradient(colors: [.green, .yellow, .red]),
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: geometry.size.width * broadcastManager.audioLevel, height: 20)
                    }
                }
                .frame(height: 20)
                
                Text(String(format: "电平: %.3f", broadcastManager.audioLevel))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // 音频帧计数
            InfoCard(title: "📊 音频数据", content: "已处理帧数: \(broadcastManager.audioFrameCount)")
            
            // 当前录制文件
            if let fileName = broadcastManager.currentRecordingFileName {
                InfoCard(title: "🎙️ 正在录制", content: fileName)
            }
        }
    }
    
    // MARK: - Realtime Recognition Section
    private var realtimeRecognitionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("📻 实时语音识别")
                    .font(.headline)
                
                Spacer()
                
                HStack(spacing: 8) {
                    Circle()
                        .fill(realtimeAudioManager.isProcessing ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    
                    Text(realtimeAudioManager.isProcessing ? "识别中" : "未启动")
                        .font(.caption)
                        .foregroundColor(realtimeAudioManager.isProcessing ? .green : .gray)
                }
            }
            
            ScrollView {
                Text(realtimeAudioManager.recognizedText.isEmpty ? 
                     "开始直播后，系统音频将自动识别为文字显示在这里..." : 
                     realtimeAudioManager.recognizedText)
                    .font(.body)
                    .foregroundColor(realtimeAudioManager.recognizedText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    .padding(12)
                    .background(Color(.systemBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
            }
            .frame(maxHeight: 150)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
        )
    }
    
    // MARK: - Recordings List Section
    private var recordingsListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("📼 录音列表")
                    .font(.headline)
                
                Spacer()
                
                // 清空所有录音按钮
                Button(action: {
                    showingClearAllAlert = true
                }) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                }
                .disabled(broadcastManager.audioRecordings.isEmpty)
                
                // 刷新按钮
                Button(action: {
                    broadcastManager.loadAudioRecordings()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.blue)
                }
            }
            
            ForEach(broadcastManager.audioRecordings) { recording in
                RecordingRow(
                    recording: recording,
                    onPlay: {
                        selectedRecording = recording
                        showingPlayer = true
                    },
                    onShare: {
                        recordingToShare = recording
                        showingShareSheet = true
                    },
                    onDelete: {
                        broadcastManager.deleteRecording(recording)
                    },
                    onConvert: {
                        broadcastManager.convertRecordingToWAV(recording)
                    }
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
        )
    }
    
    // MARK: - Clear All Recordings
    private func clearAllRecordings() {
        // 删除所有录音文件
        broadcastManager.clearAllRecordings()
        
        // 重新加载录音列表
        broadcastManager.loadAudioRecordings()
        
        // 显示成功提示
        alertMessage = "已清空所有录音文件"
        showingAlert = true
    }
}

// MARK: - Recording Row Component
struct RecordingRow: View {
    let recording: AudioRecording
    let onPlay: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void
    let onConvert: () -> Void
    
    @State private var showingDeleteAlert = false
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                // 文件信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.fileName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    
                    HStack(spacing: 12) {
                        Label(recording.formattedDuration, systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Label(recording.formattedFileSize, systemImage: "doc")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // 操作按钮
                HStack(spacing: 8) {
                    // 播放按钮
                    Button(action: onPlay) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                    
                    // 分享按钮
                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                    
                    // 转换按钮 - 只对M4A文件显示
                    if recording.fileName.hasSuffix(".m4a") {
                        Button(action: onConvert) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.title3)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    // 删除按钮
                    Button(action: {
                        showingDeleteAlert = true
                    }) {
                        Image(systemName: "trash")
                            .font(.title3)
                            .foregroundColor(.red)
                    }
                }
            }
            
            Divider()
        }
        .alert("删除录音", isPresented: $showingDeleteAlert) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("确定要删除这个录音文件吗？")
        }
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Info Card Component
struct InfoCard: View {
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(content)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
        )
    }
}

// MARK: - Inaudible Audio Player
class InaudibleAudioPlayer: ObservableObject {
    private var audioPlayer: AVAudioPlayer?
    private var inaudibleAudioURL: URL?
    @Published var lastInterruptionTime: Date?
    
    init() {
        setupInaudibleAudio()
    }
    
    private func setupInaudibleAudio() {
        // 获取预生成的高频音频文件
        let appGroupID = "group.dev.tuist.Siri"
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            print("❌ 无法获取App Group容器路径")
            return
        }
        
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        let fileName = "InaudibleAudio.wav"
        let fileURL = audioDirectory.appendingPathComponent(fileName)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            inaudibleAudioURL = fileURL
            print("✅ 找到高频音频文件: \(fileName)")
        } else {
            print("❌ 高频音频文件不存在: \(fileName)")
        }
    }
    
    func playInaudibleSound() {
        guard let audioURL = inaudibleAudioURL else {
            print("❌ 高频音频文件未准备好")
            return
        }
        
        do {
            // 配置音频会话，确保能够中断其他音频
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // 创建音频播放器
            audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            audioPlayer?.prepareToPlay()
            
            // 播放高频音频
            if audioPlayer?.play() == true {
                print("🔊 播放高频不可听音频，尝试中断后台音乐")
                lastInterruptionTime = Date()
                
                // 播放完成后恢复音频会话设置
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    do {
                        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
                        try audioSession.overrideOutputAudioPort(.speaker)
                        print("✅ 音频会话已恢复到正常设置")
                    } catch {
                        print("❌ 恢复音频会话失败: \(error.localizedDescription)")
                    }
                }
            } else {
                print("❌ 播放高频音频失败")
            }
        } catch {
            print("❌ 播放高频音频错误: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Resume Background Music Methods
    
    /// 方法1: 通过重置音频会话来恢复后台音乐
    func resumeBackgroundMusicViaSessionReset() {
        print("🎵 尝试通过音频会话重置恢复后台音乐")
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // 首先完全停用音频会话
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            
            // 短暂延迟后重新激活，允许其他应用重新获得音频焦点
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                do {
                    // 设置为ambient类别，不会中断其他音频
                    try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                    try audioSession.setActive(true)
                    
                    print("✅ 音频会话已重置，后台音乐应该可以恢复")
                    
                    // 再次延迟后恢复到正常设置
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        do {
                            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
                            try audioSession.overrideOutputAudioPort(.speaker)
                            print("✅ 音频会话已恢复到应用正常设置")
                        } catch {
                            print("❌ 恢复应用音频设置失败: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    print("❌ 重新激活音频会话失败: \(error.localizedDescription)")
                }
            }
        } catch {
            print("❌ 停用音频会话失败: \(error.localizedDescription)")
        }
    }
    
    /// 方法2: 使用MPRemoteCommandCenter发送播放命令
    func resumeBackgroundMusicViaRemoteCommand() {
        print("🎵 尝试通过远程命令恢复后台音乐")
        
        // 这个方法在实际设备中可能不会工作，因为应用无法直接控制其他应用的媒体播放
        // 但可以尝试配置远程控制事件
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 先激活会话以获得远程控制权限
            try audioSession.setActive(true)
            
            // 短暂延迟后释放控制权，让系统恢复之前的音频应用
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                do {
                    try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                    print("✅ 已释放音频会话控制权")
                } catch {
                    print("❌ 释放音频会话失败: \(error.localizedDescription)")
                }
            }
        } catch {
            print("❌ 激活音频会话失败: \(error.localizedDescription)")
        }
    }
    
    /// 方法3: 通过通知中心尝试恢复
    func resumeBackgroundMusicViaNotification() {
        print("🎵 尝试通过通知恢复后台音乐")
        
        // 发送音频中断结束通知
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        
        print("📢 已发送音频中断结束通知")
    }
    
    /// 方法4: 综合恢复方法（推荐使用）
    func resumeBackgroundMusicComprehensive() {
        print("🎵 使用综合方法恢复后台音乐")
        
        // 先尝试音频会话重置
        resumeBackgroundMusicViaSessionReset()
        
        // 延迟后尝试远程命令
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.resumeBackgroundMusicViaRemoteCommand()
        }
        
        // 最后发送通知
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.resumeBackgroundMusicViaNotification()
        }
    }
}

#Preview {
    ScreenBroadcastView(
        broadcastManager: ScreenBroadcastManager(),
        realtimeAudioManager: RealtimeAudioStreamManager(),
        inaudibleAudioPlayer: InaudibleAudioPlayer()
    )
}
