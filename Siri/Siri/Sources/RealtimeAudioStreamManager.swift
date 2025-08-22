import Foundation
import AVFoundation
import Speech
import os.log

@MainActor
public class RealtimeAudioStreamManager: NSObject, ObservableObject {
    
    @Published public var isProcessing: Bool = false
    @Published public var recognizedText: String = ""
    @Published public var errorMessage: String = ""
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let logger = Logger(subsystem: "dev.tuist.Siri", category: "RealtimeAudio")
    private let appGroupID = "group.dev.tuist.Siri"
    
    private var darwinNotificationCenter: CFNotificationCenter?
    private var audioBufferQueue = [CMSampleBuffer]()
    
    // 用于保存转换后的音频数据进行验证
    private var audioWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?
    private var convertedAudioFileURL: URL?
    private var processingQueue = DispatchQueue(label: "realtime.audio.processing", qos: .userInitiated)
    private var hasLoggedFormat = false
    
    public override init() {
        super.init()
        // 暂时移除音频会话设置，避免干扰原有录制功能
        // setupAudioSession()
        speechRecognizer?.delegate = self
        setupDarwinNotifications()
    }
    
    public func startMonitoring() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "语音识别器不可用"
            return
        }
        
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self?.startRecognition()
                case .denied:
                    self?.errorMessage = "语音识别权限被拒绝"
                case .restricted:
                    self?.errorMessage = "语音识别权限受限"
                case .notDetermined:
                    self?.errorMessage = "语音识别权限未确定"
                @unknown default:
                    self?.errorMessage = "未知的权限状态"
                }
            }
        }
    }
    
    public func stopMonitoring() {
        logger.info("🛑 停止实时音频流监控")
        stopRecognition()
    }
    
    private func setupDarwinNotifications() {
        darwinNotificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        
        let notificationName = "dev.tuist.Siri.audiodata" as CFString
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        CFNotificationCenterAddObserver(
            darwinNotificationCenter,
            observer,
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let manager = Unmanaged<RealtimeAudioStreamManager>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    manager.handleAudioDataNotification()
                }
            },
            notificationName,
            nil,
            .deliverImmediately
        )
        
        logger.info("📡 Darwin通知监听已设置")
    }
    
    private func handleAudioDataNotification() {
        logger.debug("📱 收到音频数据通知")
        readAudioDataFromSharedMemory()
    }
    
    private func readAudioDataFromSharedMemory() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let audioDataURL = containerURL.appendingPathComponent("realtime_audio_buffer.data")
        let formatURL = containerURL.appendingPathComponent("realtime_audio_format.json")
        
        guard FileManager.default.fileExists(atPath: audioDataURL.path),
              FileManager.default.fileExists(atPath: formatURL.path),
              let audioData = try? Data(contentsOf: audioDataURL),
              let formatData = try? Data(contentsOf: formatURL),
              let formatInfo = try? JSONSerialization.jsonObject(with: formatData) as? [String: Any] else {
            return
        }
        
        processingQueue.async { [weak self] in
            Task { @MainActor in
                self?.processAudioData(audioData, formatInfo: formatInfo)
            }
        }
    }
    
    private func processAudioData(_ data: Data, formatInfo: [String: Any]) {
        guard isProcessing,
              let recognitionRequest = recognitionRequest else {
            return
        }
        
        // 从格式信息中获取音频参数
        guard let sampleRate = formatInfo["sampleRate"] as? Double,
              let channels = formatInfo["channels"] as? UInt32,
              let formatID = formatInfo["formatID"] as? UInt32,
              let bitsPerChannel = formatInfo["bitsPerChannel"] as? UInt32 else {
            logger.error("❌ 无法解析音频格式信息")
            return
        }
        
        // 只在首次识别格式时记录
        if !hasLoggedFormat && (formatID == kAudioFormatLinearPCM || formatID == 1819304813) {
            logger.info("🎵 PCM格式: \(sampleRate)Hz, \(channels)声道, \(bitsPerChannel)位")
            hasLoggedFormat = true
        }
        
        // 创建合适的音频格式
        var audioFormat: AVAudioFormat?
        
        // 根据实际格式创建AVAudioFormat
        // kAudioFormatLinearPCM = 1819304813 ('lpcm') 是线性PCM格式的标识符
        if formatID == kAudioFormatLinearPCM || formatID == 1819304813 {
            // PCM格式 - 使用非交错格式（参考正确的 demo）
            if bitsPerChannel == 32 {
                // 32位浮点 - 非交错格式
                audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)
            } else if bitsPerChannel == 16 {
                // 16位整数 - 非交错格式
                audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)
            }
        }
        
        guard let format = audioFormat else {
            logger.error("❌ 不支持的音频格式: formatID=\(formatID), bitsPerChannel=\(bitsPerChannel)")
            return
        }
        
        // 计算帧数量
        let bytesPerSample = bitsPerChannel / 8
        let frameCount = AVAudioFrameCount(data.count / (Int(bytesPerSample) * Int(channels)))
        
        guard frameCount > 0 else {
            return
        }
        
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        
        audioBuffer.frameLength = frameCount
        
        // 复制音频数据 - 使用非交错格式（参考 demo 的正确做法）
        data.withUnsafeBytes { rawBytes in
            if bitsPerChannel == 16 {
                // 16位整数数据 - 从交错转为非交错
                guard let int16Pointer = rawBytes.bindMemory(to: Int16.self).baseAddress,
                      let channelData = audioBuffer.int16ChannelData else {
                    return
                }
                
                if channels == 2 {
                    // 立体声：将交错数据分离到两个通道（按 demo 方式）
                    let leftChannel = channelData[0]
                    let rightChannel = channelData[1]
                    
                    for frame in 0..<Int(frameCount) {
                        let interleavedIndex = frame * 2
                        leftChannel[frame] = int16Pointer[interleavedIndex]     // 左声道
                        rightChannel[frame] = int16Pointer[interleavedIndex + 1] // 右声道
                    }
                    
                    let firstLeft = leftChannel[0]
                    let firstRight = rightChannel[0]
                    logger.info("🔍 非交错转换: L=\(firstLeft), R=\(firstRight), 帧数=\(frameCount)")
                    
                } else {
                    // 单声道：直接复制（像Demo一样）
                    let channel = channelData[0]
                    channel.initialize(from: int16Pointer, count: Int(frameCount))
                    logger.info("🔍 单声道复制: 首样本=\(channel[0]), 帧数=\(frameCount)")
                }
                
            } else if bitsPerChannel == 32 {
                // 32位浮点数据 - 从交错转为非交错
                guard let floatPointer = rawBytes.bindMemory(to: Float.self).baseAddress,
                      let channelData = audioBuffer.floatChannelData else {
                    return
                }
                
                if channels == 2 {
                    // 立体声：分离交错数据
                    let leftChannel = channelData[0]
                    let rightChannel = channelData[1]
                    
                    for frame in 0..<Int(frameCount) {
                        let interleavedIndex = frame * 2
                        leftChannel[frame] = floatPointer[interleavedIndex]
                        rightChannel[frame] = floatPointer[interleavedIndex + 1]
                    }
                } else {
                    // 单声道：直接复制
                    let channel = channelData[0]
                    channel.initialize(from: floatPointer, count: Int(frameCount))
                }
            }
        }
        
        // 保存转换后的音频数据用于验证
        // saveConvertedAudioBuffer(audioBuffer)  // 暂时注释掉，只测试M4A到WAV转换
        
        // 发送到语音识别器
        recognitionRequest.append(audioBuffer)
    }
    
    private func calculateAudioLevel(from audioBuffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = audioBuffer.int16ChannelData?[0] else {
            return 0.0
        }
        
        let frameCount = Int(audioBuffer.frameLength)
        let channels = Int(audioBuffer.format.channelCount)
        
        var sum: Double = 0.0
        let sampleCount = frameCount * channels
        
        for i in 0..<sampleCount {
            let sample = Double(channelData[i]) / 32768.0 // 归一化到 -1.0 到 1.0
            sum += sample * sample
        }
        
        let rms = sqrt(sum / Double(sampleCount))
        return rms
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 使用 playback 模式，保持原有的扬声器输出，同时支持与其他音频混合
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            logger.info("🎵 音频会话设置成功 (playback + default)")
        } catch {
            logger.error("❌ 音频会话设置失败: \(error.localizedDescription)")
        }
    }
    
    private func startRecognition() {
        logger.info("🚀 开始语音识别")
        
        guard !isProcessing else {
            return
        }
        
        isProcessing = true
        hasLoggedFormat = false
        
        // 开始录制转换后的音频用于验证
        // startConvertedAudioRecording()  // 暂时注释掉，只测试M4A到WAV转换
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            errorMessage = "无法创建识别请求"
            isProcessing = false
            return
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result = result {
                    let newText = result.bestTranscription.formattedString
                    
                    if !newText.isEmpty {
                        self?.recognizedText = newText
                        self?.logger.info("🎯 识别: \(newText)")
                    }
                    
                    // 删除最终结果日志，减少输出
                }
                
                if let error = error {
                    self?.logger.error("❌ 识别错误: \(error.localizedDescription)")
                    // 检查是否是"No speech detected"错误
                    if error.localizedDescription.contains("No speech") {
                        self?.logger.info("⚠️ 未检测到语音 - 可能音频内容为静音或音量过低")
                    }
                    self?.errorMessage = error.localizedDescription
                    self?.stopRecognition()
                }
            }
        }
        
        logger.info("✅ 语音识别任务已启动")
    }
    
    private func stopRecognition() {
        logger.info("🛑 停止语音识别")
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isProcessing = false
        
        // 停止录制转换后的音频
        // stopConvertedAudioRecording()  // 暂时注释掉，只测试M4A到WAV转换
        
        logger.info("✅ 语音识别已停止")
    }
    
    deinit {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveObserver(
            darwinNotificationCenter,
            observer,
            CFNotificationName("dev.tuist.Siri.audiodata" as CFString),
            nil
        )
    }
    
    // MARK: - Converted Audio Recording for Verification
    
    private func startConvertedAudioRecording() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        // 创建音频目录
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        if !FileManager.default.fileExists(atPath: audioDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return
            }
        }
        
        // 创建转换后音频文件
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium).replacingOccurrences(of: ":", with: "-")
        let fileName = "ConvertedAudio_\(timestamp).m4a"
        convertedAudioFileURL = audioDirectory.appendingPathComponent(fileName)
        
        guard let audioFileURL = convertedAudioFileURL else { return }
        
        // 设置音频写入器
        do {
            audioWriter = try AVAssetWriter(outputURL: audioFileURL, fileType: .m4a)
            
            // 配置音频设置 - 使用与转换后相同的格式
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            
            audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioWriterInput?.expectsMediaDataInRealTime = true
            
            if let input = audioWriterInput {
                audioWriter?.add(input)
                audioWriter?.startWriting()
            }
            
            logger.info("🎙️ 开始录制转换后音频: \(fileName)")
            
        } catch {
            logger.error("❌ 创建转换音频写入器失败: \(error.localizedDescription)")
        }
    }
    
    private func saveConvertedAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
              let int16Data = audioBuffer.int16ChannelData else {
            return
        }
        
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        let tempDataURL = audioDirectory.appendingPathComponent("converted_audio_temp.pcm")
        
        let frameCount = Int(audioBuffer.frameLength)
        let channels = Int(audioBuffer.format.channelCount)
        let interleavedDataSize = frameCount * channels * MemoryLayout<Int16>.size
        
        // 将非交错数据转换为交错格式（WAV标准，参考demo正确做法）
        var interleavedData = Data(capacity: interleavedDataSize)
        
        if channels == 2 {
            // 立体声：交错左右声道
            let leftChannel = int16Data[0]
            let rightChannel = int16Data[1]
            
            for frame in 0..<frameCount {
                // 交错格式：L, R, L, R, ...
                withUnsafeBytes(of: leftChannel[frame]) { interleavedData.append(contentsOf: $0) }
                withUnsafeBytes(of: rightChannel[frame]) { interleavedData.append(contentsOf: $0) }
            }
            
            logger.info("💾 保存立体声数据: L首样本=\(leftChannel[0]), R首样本=\(rightChannel[0]), 帧数=\(frameCount)")
            
        } else {
            // 单声道：直接复制（参考demo方式）
            let channel = int16Data[0]
            for frame in 0..<frameCount {
                withUnsafeBytes(of: channel[frame]) { interleavedData.append(contentsOf: $0) }
            }
            
            logger.info("💾 保存单声道数据: 首样本=\(channel[0]), 帧数=\(frameCount)")
        }
        
        
        do {
            if FileManager.default.fileExists(atPath: tempDataURL.path) {
                let fileHandle = try FileHandle(forWritingTo: tempDataURL)
                defer { try? fileHandle.close() }
                _ = try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: interleavedData)
            } else {
                try interleavedData.write(to: tempDataURL)
            }
        } catch {
            // 保存失败不影响主要功能
        }
    }
    
    
    private func stopConvertedAudioRecording() {
        // 将临时PCM数据转换为可播放的音频文件
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        let tempDataURL = audioDirectory.appendingPathComponent("converted_audio_temp.pcm")
        
        // 检查临时文件是否存在
        guard FileManager.default.fileExists(atPath: tempDataURL.path) else {
            logger.info("⚠️ 没有转换后的音频数据需要保存")
            return
        }
        
        // 创建最终的音频文件名
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium).replacingOccurrences(of: ":", with: "-")
        let fileName = "ConvertedAudio_\(timestamp).wav"
        let finalURL = audioDirectory.appendingPathComponent(fileName)
        
        // 将PCM数据转换为WAV文件
        convertPCMToWAV(inputURL: tempDataURL, outputURL: finalURL)
        
        // 清理临时文件
        try? FileManager.default.removeItem(at: tempDataURL)
        
        audioWriter = nil
        audioWriterInput = nil
        convertedAudioFileURL = nil
        
        logger.info("✅ 转换后音频文件录制完成: \(fileName)")
        notifyConvertedAudioFileCompleted(fileURL: finalURL)
    }
    
    private func convertPCMToWAV(inputURL: URL, outputURL: URL) {
        do {
            let pcmData = try Data(contentsOf: inputURL)
            guard pcmData.count > 0 else {
                logger.error("❌ PCM数据为空，无法创建WAV文件")
                return
            }
            
            let wavData = createWAVHeader(dataLength: pcmData.count) + pcmData
            try wavData.write(to: outputURL)
            logger.info("📁 WAV文件已创建: \(outputURL.lastPathComponent), 大小: \(wavData.count) bytes (PCM: \(pcmData.count) bytes)")
        } catch {
            logger.error("❌ 转换PCM为WAV失败: \(error.localizedDescription)")
        }
    }
    
    private func createWAVHeader(dataLength: Int) -> Data {
        var header = Data()
        
        // RIFF header (12 bytes)
        header.append("RIFF".data(using: .ascii)!)                                    // "RIFF" (4 bytes)
        header.append(withUnsafeBytes(of: UInt32(36 + dataLength).littleEndian) { Data($0) }) // File size - 8 (4 bytes)
        header.append("WAVE".data(using: .ascii)!)                                    // "WAVE" (4 bytes)
        
        // fmt sub-chunk (24 bytes)
        header.append("fmt ".data(using: .ascii)!)                                    // "fmt " (4 bytes)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })      // fmt chunk size (4 bytes)
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })       // PCM = 1 (2 bytes)
        header.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })       // 2 channels (2 bytes)
        header.append(withUnsafeBytes(of: UInt32(44100).littleEndian) { Data($0) })   // Sample rate (4 bytes)
        header.append(withUnsafeBytes(of: UInt32(44100 * 2 * 2).littleEndian) { Data($0) }) // Byte rate (4 bytes)
        header.append(withUnsafeBytes(of: UInt16(4).littleEndian) { Data($0) })       // Block align = channels * bits/8 (2 bytes)
        header.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })      // Bits per sample (2 bytes)
        
        // data sub-chunk (8 bytes header + data)
        header.append("data".data(using: .ascii)!)                                    // "data" (4 bytes)
        header.append(withUnsafeBytes(of: UInt32(dataLength).littleEndian) { Data($0) }) // Data length (4 bytes)
        
        logger.info("📋 WAV头创建: 总大小=\(header.count + dataLength), 头=\(header.count)字节, PCM=\(dataLength)字节")
        
        return header
    }
    
    private func notifyConvertedAudioFileCompleted(fileURL: URL) {
        let notification: [String: Any] = [
            "event": "converted_audio_file_completed",
            "fileName": fileURL.lastPathComponent,
            "filePath": fileURL.path,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let notificationURL = containerURL.appendingPathComponent("converted_audio_notification.json")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: notification, options: [])
            try jsonData.write(to: notificationURL)
            logger.info("📡 已通知转换后音频文件完成")
        } catch {
            logger.error("❌ 写入转换后音频通知失败: \(error.localizedDescription)")
        }
    }
}

extension RealtimeAudioStreamManager: SFSpeechRecognizerDelegate {
    nonisolated public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            logger.info("🎤 语音识别器可用性变化: \(available)")
            if !available && isProcessing {
                stopRecognition()
            }
        }
    }
}