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
    
    // MARK: - State Variables
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var playerLayerContainer: UIView?
    
    public init() {}

    public var body: some View {
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
        .onAppear {
            speechManager.requestAuthorization()
        }
        .onReceive(speechManager.$recognizedText) { text in
            // Update PiP with recognized text
            pipManager.updateText(text)
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
        .onReceive(speechManager.$recognizedText) { newText in
            // Update PiP text whenever speech recognition text changes
            pipManager.updateText(newText)
        }
        .alert("错误", isPresented: $showingAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
