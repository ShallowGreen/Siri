import SwiftUI
import Speech
import AVFoundation
import UIKit

// MARK: - Player Layer Container View
struct PlayerLayerContainerView: UIViewRepresentable {
    let pipManager: PictureInPictureManager
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        
        // 设置播放器层到这个视图中
        DispatchQueue.main.async {
            pipManager.setupPlayerLayer(in: view)
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // 无需更新
    }
}

public struct ContentView: View {
    // MARK: - State Objects
    @StateObject private var speechManager = SpeechRecognitionManager()
    @StateObject private var pipManager = PictureInPictureManager()
    @StateObject private var broadcastManager = ScreenBroadcastManager()
    @StateObject private var realtimeAudioManager = RealtimeAudioStreamManager()
    @StateObject private var inaudibleAudioPlayer = InaudibleAudioPlayer()
    
    // MARK: - State Variables
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var playerLayerContainer: UIView?
    @State private var isPushToTalkActive = false
    
    public init() {}

    public var body: some View {
        TabView {
            // 语音识别 Tab
            speechRecognitionTab
                .tabItem {
                    Image(systemName: "mic")
                    Text("语音识别")
                }
            
            // 屏幕直播 Tab
            ScreenBroadcastView(
                pipManager: pipManager,
                broadcastManager: broadcastManager,
                realtimeAudioManager: realtimeAudioManager,
                inaudibleAudioPlayer: inaudibleAudioPlayer
            )
            .tabItem {
                Image(systemName: "tv")
                Text("屏幕直播")
            }
        }
        .onAppear {
            speechManager.requestAuthorization()
            setupAudioRouteMonitoring()
        }
        .alert("错误", isPresented: $showingAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func setupAudioRouteMonitoring() {
        // 监听音频路由变化，确保始终使用扬声器
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                self.forceAudioToSpeaker()
            }
        }
    }
    
    private func forceAudioToSpeaker() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.overrideOutputAudioPort(.speaker)
            print("🔊 强制音频路由到扬声器")
        } catch {
            print("❌ 设置扬声器输出失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Speech Recognition Tab
    private var speechRecognitionTab: some View {
        VStack(spacing: 30) {
            // Title
            Text("Siri")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 50)
            
            // Hidden Player Layer Container (required for PiP)
            PlayerLayerContainerView(pipManager: pipManager)
                .frame(width: 100, height: 25) // 小尺寸容器，几乎不可见
                .opacity(0.01) // 几乎透明
            
            // Status Display
            VStack(spacing: 16) {
                // Recording Status
                HStack {
                    Image(systemName: speechManager.isRecording ? "mic.fill" : "mic.slash.fill")
                        .foregroundColor(speechManager.isRecording ? .red : .gray)
                        .font(.title2)
                    
                    Text(speechManager.isRecording ? "正在录音..." : "未录音")
                        .font(.headline)
                        .foregroundColor(speechManager.isRecording ? .red : .secondary)
                }
                
                // PiP Status
                HStack {
                    Image(systemName: pipManager.isPipActive ? "pip.fill" : "pip")
                        .foregroundColor(pipManager.isPipActive ? .blue : .gray)
                        .font(.title2)
                    
                    Text(pipManager.isPipActive ? "画中画已激活" : "画中画未激活")
                        .font(.headline)
                        .foregroundColor(pipManager.isPipActive ? .blue : .secondary)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
            // Recognized Text Display
            ScrollView {
                Text(speechManager.recognizedText.isEmpty ? "识别的文字将在这里显示..." : speechManager.recognizedText)
                    .font(.body)
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
            }
            .frame(maxHeight: 200)
            
            Spacer()
            
            // Control Buttons
            VStack(spacing: 16) {
                // Start/Stop Recording Button
                Button(action: {
                    if speechManager.isRecording {
                        speechManager.stopRecording()
                    } else {
                        if speechManager.isAuthorized {
                            speechManager.startRecording()
                            // Auto-start PiP when recording starts
                            if pipManager.canStartPip && !pipManager.isPipActive {
                                pipManager.startPictureInPicture()
                            }
                        } else {
                            speechManager.requestAuthorization()
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: speechManager.isRecording ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                        Text(speechManager.isRecording ? "停止" : "开始")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 15)
                    .background(speechManager.isRecording ? Color.red : Color.blue)
                    .cornerRadius(25)
                }
                .disabled(!speechManager.isAuthorized && !speechManager.isRecording)
                
                // Push-to-Talk Button
                Button(action: {}) {
                    HStack {
                        Image(systemName: isPushToTalkActive ? "mic.fill" : "hand.point.up.left.fill")
                            .font(.title2)
                        Text(isPushToTalkActive ? "按住说话中..." : "按住说话")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 15)
                    .background(isPushToTalkActive ? Color.red : Color.purple)
                    .cornerRadius(25)
                    .scaleEffect(isPushToTalkActive ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.1), value: isPushToTalkActive)
                }
                .disabled(!speechManager.isAuthorized)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPushToTalkActive {
                                handlePushToTalkPress()
                            }
                        }
                        .onEnded { _ in
                            if isPushToTalkActive {
                                handlePushToTalkRelease()
                            }
                        }
                )
                
                // Picture in Picture Toggle Button
                Button(action: {
                    print("🔘 [UI] 画中画按钮被点击")
                    print("🔘 [UI] 当前状态 - isPipActive: \(pipManager.isPipActive), canStartPip: \(pipManager.canStartPip)")
                    
                    if pipManager.isPipActive {
                        print("🔘 [UI] 停止画中画")
                        pipManager.stopPictureInPicture()
                    } else {
                        print("🔘 [UI] 启动画中画")
                        pipManager.startPictureInPicture()
                    }
                }) {
                    HStack {
                        Image(systemName: pipManager.isPipActive ? "pip.remove" : "pip.enter")
                            .font(.title2)
                        Text(pipManager.isPipActive ? "关闭画中画" : "开启画中画")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(pipManager.isPipActive ? Color.orange : Color.green)
                    .cornerRadius(20)
                }
                .disabled(!pipManager.canStartPip && !pipManager.isPipActive)
            }
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .background(Color(.systemGroupedBackground))
        .onReceive(speechManager.$recognizedText) { text in
            // Update PiP with microphone recognized text
            pipManager.updateMicrophoneText(text)
        }
        .onReceive(speechManager.$errorMessage) { error in
            if !error.isEmpty {
                alertMessage = error
                showingAlert = true
            }
        }
        .onReceive(pipManager.$errorMessage) { error in
            if !error.isEmpty {
                alertMessage = error
                showingAlert = true
            }
        }
        .onReceive(realtimeAudioManager.$recognizedText) { text in
            // Update PiP with media audio recognized text (only when not in push-to-talk mode)
            if !isPushToTalkActive {
                pipManager.updateMediaText(text)
            }
        }
    }
    
    // MARK: - Push-to-Talk Handlers
    private func handlePushToTalkPress() {
        guard speechManager.isAuthorized else { return }
        
        print("🎤 [PTT] 按下按住说话按钮")
        isPushToTalkActive = true
        
        // 1. 中断后台音乐
        // print("🎵 [PTT] 中断后台音乐")
        // inaudibleAudioPlayer.playInaudibleSound()
        
        // 2. 检查是否在屏幕直播
        let isBroadcasting = broadcastManager.isRecording
        print("📡 [PTT] 屏幕直播状态: \(isBroadcasting)")
        
        // 3. 如果没有在屏幕直播，先连接socket再启动语音识别
        if !isBroadcasting {
            print("🔌 [PTT] 没有屏幕直播，启动socket连接和语音识别")
            realtimeAudioManager.startMonitoring()
        } else {
            // 如果在屏幕直播，暂停媒体声音识别
            print("⏸️ [PTT] 暂停媒体声音识别前，启用文字保留模式")
            realtimeAudioManager.setTextPreservationMode(true)
            realtimeAudioManager.stopMonitoring()
        }
        
        // 4. 启用麦克风收集和语音识别
        print("🎤 [PTT] 启动麦克风语音识别")
        speechManager.startRecording(clearPreviousText: false)
        
        // Auto-start PiP when recording starts
        if pipManager.canStartPip && !pipManager.isPipActive {
            pipManager.startPictureInPicture()
        }
    }
    
    private func handlePushToTalkRelease() {
        guard isPushToTalkActive else { return }
        
        print("🎤 [PTT] 松开按住说话按钮")
        isPushToTalkActive = false
        
        // 1. 停止麦克风收集和识别
        print("🛑 [PTT] 停止麦克风语音识别")
        speechManager.stopRecording()
        
        // 2. 检查是否在屏幕直播
        let isBroadcasting = broadcastManager.isRecording
        print("📡 [PTT] 屏幕直播状态: \(isBroadcasting)")
        
        // 3. 根据直播状态决定是否断开socket
        if isBroadcasting {
            // 如果在屏幕直播，恢复媒体声音识别
            print("▶️ [PTT] 恢复媒体声音识别，保留之前的文字")
            realtimeAudioManager.startMonitoring()
        } else {
            // 如果没有屏幕直播，断开socket连接
            print("🔌 [PTT] 没有屏幕直播，断开socket连接")
            realtimeAudioManager.stopMonitoring()
        }
        
        // 4. 如果在屏幕直播，使用远程命令恢复后台音乐
        // if isBroadcasting {
        //     print("🎵 [PTT] 使用远程命令恢复后台音乐")
        //     inaudibleAudioPlayer.resumeBackgroundMusicViaRemoteCommand()
        // }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
