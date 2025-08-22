import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    let recording: AudioRecording
    @StateObject private var playerManager = AudioPlayerManager()
    @State private var showShareSheet = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            // 标题
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
                
                Text(recording.fileName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                
                HStack(spacing: 20) {
                    Label(recording.formattedDuration, systemImage: "clock")
                    Label(recording.formattedFileSize, systemImage: "doc")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.top, 20)
            
            // 播放进度
            VStack(spacing: 12) {
                // 进度条
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // 背景轨道
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 6)
                        
                        // 进度
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * playerManager.progress, height: 6)
                    }
                }
                .frame(height: 6)
                
                // 时间标签
                HStack {
                    Text(playerManager.currentTimeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(playerManager.durationString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 30)
            
            // 播放控制
            HStack(spacing: 40) {
                // 后退10秒
                Button(action: {
                    playerManager.skip(seconds: -10)
                }) {
                    Image(systemName: "gobackward.10")
                        .font(.title)
                        .foregroundColor(.primary)
                }
                
                // 播放/暂停按钮
                Button(action: {
                    if playerManager.isPlaying {
                        playerManager.pause()
                    } else {
                        playerManager.play(url: recording.fileURL)
                    }
                }) {
                    Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                }
                
                // 前进10秒
                Button(action: {
                    playerManager.skip(seconds: 10)
                }) {
                    Image(systemName: "goforward.10")
                        .font(.title)
                        .foregroundColor(.primary)
                }
            }
            .padding(.vertical, 20)
            
            // 操作按钮
            VStack(spacing: 16) {
                // 分享按钮
                Button(action: {
                    showShareSheet = true
                }) {
                    Label("分享音频", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.green)
                        .cornerRadius(10)
                }
                
                // 关闭按钮
                Button(action: {
                    playerManager.stop()
                    dismiss()
                }) {
                    Text("关闭")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.systemGray5))
                        .cornerRadius(10)
                }
            }
            .padding(.horizontal, 30)
            
            Spacer()
        }
        .padding()
        .sheet(isPresented: $showShareSheet) {
            AudioPlayerShareSheet(items: [recording.fileURL])
        }
        .onAppear {
            playerManager.setupPlayer(url: recording.fileURL)
        }
        .onDisappear {
            playerManager.stop()
        }
    }
}

// MARK: - Audio Player Manager
class AudioPlayerManager: ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0.0
    @Published var currentTimeString = "00:00"
    @Published var durationString = "00:00"
    
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    
    func setupPlayer(url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            durationString = formatTime(audioPlayer?.duration ?? 0)
        } catch {
            print("❌ 无法加载音频文件: \(error)")
        }
    }
    
    func play(url: URL) {
        if audioPlayer == nil {
            setupPlayer(url: url)
        }
        
        audioPlayer?.play()
        isPlaying = true
        startTimer()
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        progress = 0
        currentTimeString = "00:00"
        stopTimer()
    }
    
    func skip(seconds: Double) {
        guard let player = audioPlayer else { return }
        
        let newTime = player.currentTime + seconds
        if newTime >= 0 && newTime <= player.duration {
            player.currentTime = newTime
            updateProgress()
        }
    }
    
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            self.updateProgress()
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateProgress() {
        guard let player = audioPlayer else { return }
        
        if player.duration > 0 {
            progress = player.currentTime / player.duration
        }
        
        currentTimeString = formatTime(player.currentTime)
        
        // 检查是否播放完成
        if !player.isPlaying && player.currentTime >= player.duration - 0.1 {
            stop()
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Player Share Sheet
struct AudioPlayerShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}