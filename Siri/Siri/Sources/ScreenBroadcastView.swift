import SwiftUI

public struct ScreenBroadcastView: View {
    @StateObject private var broadcastManager = ScreenBroadcastManager()
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    public init() {}
    
    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 标题
                headerSection
                
                // 状态信息
                statusSection
                
                // 控制按钮
                controlButtonSection
                
                // 音频数据展示
                if broadcastManager.isRecording {
                    audioDataSection
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
        .alert("提示", isPresented: $showingAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
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
            
            // 说明文字
            Text(broadcastManager.isRecording ? 
                 "点击停止按钮将结束屏幕直播" : 
                 "点击显示直播选择器，然后在系统弹窗中选择开始")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
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
        }
    }
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

#Preview {
    ScreenBroadcastView()
}
