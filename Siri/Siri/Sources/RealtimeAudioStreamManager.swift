import Foundation
import AVFoundation
import os.log
import SocketIO
import Combine

@MainActor
public class RealtimeAudioStreamManager: NSObject, ObservableObject {
    
    @Published public var isProcessing: Bool = false
    @Published public var recognizedText: String = ""
    @Published public var errorMessage: String = ""
    
    // MARK: - Private Properties for text management
    private var previousText: String = ""
    private var shouldPreserveText: Bool = false
    private var currentPartialText: String = ""
    private var finalTextSegments: [String] = []
    
    // Socket.IO Properties
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private let serverURL = "https://api-test.pleaseprof.app"
    private let namespace = "/transcribe" // Same namespace as SpeechRecognitionManager but separate connection
    
    // Audio Processing Properties
    private var sampleRate: Double = 16000
    private var languageCode: String = "zh-CN"
    private var audioEngine = AVAudioEngine()
    private var audioSession = AVAudioSession.sharedInstance()
    @Published public var isConnected: Bool = false
    private var isRecording: Bool = false
    private let logger = Logger(subsystem: "dev.tuist2.Siri", category: "RealtimeAudio")
    private let appGroupID = "group.dev.tuist2.Siri"
    
    private var darwinNotificationCenter: CFNotificationCenter?
    private var audioBufferQueue = [CMSampleBuffer]()
    
    // 用于保存转换后的音频数据进行验证
    private var audioWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?
    private var convertedAudioFileURL: URL?
    private var processingQueue = DispatchQueue(label: "realtime.audio.processing", qos: .userInitiated)
    private var hasLoggedFormat = false
    
    // 保存音频到m4a文件 - 完全模仿ScreenBroadcastHandler的方式
    private var m4aAudioWriter: AVAssetWriter?
    private var m4aAudioWriterInput: AVAssetWriterInput?
    private var currentM4AFileURL: URL?
    private var m4aStartTime: CMTime?
    
    public override init() {
        super.init()
        // 设置音频会话确保扬声器输出
        setupAudioSession()
        setupSocketConnection()
        setupDarwinNotifications()
    }
    
    // MARK: - Socket.IO Setup
    private func setupSocketConnection() {
        guard let url = URL(string: serverURL) else {
            errorMessage = "Invalid server URL"
            logger.error("❌ Invalid server URL: \(self.serverURL)")
            return
        }
        
        logger.info("🔧 [RealtimeManager] Setting up Socket.IO connection to \(self.serverURL) with namespace \(self.namespace)")
        
        manager = SocketManager(socketURL: url, config: [
            .log(true),
            .compress,
            .forceWebsockets(true),
            .forcePolling(false),
            .reconnects(true),
            .reconnectAttempts(3),
            .reconnectWait(1),
            .reconnectWaitMax(5)
        ])
        
        socket = manager?.socket(forNamespace: namespace)
        setupSocketHandlers()
        
        logger.info("✅ Socket.IO client configured for realtime transcription")
    }
    
    private func setupSocketHandlers() {
        logger.info("🔌 Setting up Socket.IO handlers for realtime transcription...")
        
        socket?.on(clientEvent: .connect) { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.isConnected = true
                self?.logger.info("✅ [RealtimeManager] Connected to transcription service")
                self?.errorMessage = ""
            }
        }
        
        socket?.on("user-assigned") { [weak self] data, ack in
            guard let userInfo = data.first as? [String: Any],
                  let userId = userInfo["userId"] as? String else { return }
            DispatchQueue.main.async {
                self?.logger.info("📋 [RealtimeManager] User ID assigned: \(userId)")
            }
        }
        
        socket?.on(clientEvent: .disconnect) { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.logger.info("❌ [RealtimeManager] Disconnected from service: \(data)")
                self?.errorMessage = "Disconnected from server"
            }
        }
        
        socket?.on(clientEvent: .error) { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.logger.error("🔴 [RealtimeManager] Socket error: \(data)")
                self?.errorMessage = "Socket error: \(data)"
            }
        }
        
        socket?.on("connect_error") { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.logger.error("🔴 [RealtimeManager] Connect error: \(data)")
                self?.errorMessage = "Failed to connect: \(data)"
            }
        }
        
        socket?.on("transcription-started") { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.logger.info("🎙️ [RealtimeManager] Transcription started")
            }
        }
        
        socket?.on("transcription-result") { [weak self] data, ack in
            self?.logger.info("📝 [RealtimeManager] Received transcription result: \(data)")
            
            guard let resultData = data.first as? [String: Any] else {
                self?.logger.error("❌ Invalid transcription result format: \(data)")
                return
            }
            
            guard let result = resultData["result"] as? [String: Any] else {
                self?.logger.error("❌ Missing result field in: \(resultData)")
                return
            }
            
            guard let transcript = result["transcript"] as? String else {
                self?.logger.error("❌ Missing transcript field in: \(result)")
                return
            }
            
            let isPartial = result["isPartial"] as? Bool ?? false
            
            DispatchQueue.main.async {
                self?.handleTranscriptionResult(transcript: transcript, isPartial: isPartial)
            }
        }
        
        socket?.on("transcription-error") { [weak self] data, ack in
            guard let errorData = data.first as? [String: Any],
                  let error = errorData["error"] as? String else { return }
            DispatchQueue.main.async {
                self?.errorMessage = error
                self?.logger.error("❌ [RealtimeManager] Transcription error: \(error)")
            }
        }
    }
    
    // MARK: - Connection Management
    private func connectToServerAndStartRecording() {
        logger.info("🔌 Attempting to connect to realtime transcription server...")
        
        if isConnected {
            logger.info("✅ Already connected to realtime server")
            startRealtimeRecording()
            return
        }
        
        logger.info("🔌 Initiating Socket.IO connection to \(self.serverURL)\(self.namespace)...")
        socket?.connect()
        
        waitForConnection(timeout: 10.0) {
            self.startRealtimeRecording()
        }
    }
    
    private func waitForConnection(timeout: TimeInterval, completion: @escaping () -> Void) {
        let startTime = Date()
        
        func checkConnection() {
            if isConnected {
                logger.info("✅ Connected successfully to realtime service!")
                completion()
                return
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > timeout {
                logger.error("⏰ Connection timeout after \(timeout)s")
                errorMessage = "Failed to connect to realtime transcription server"
                completion()
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                checkConnection()
            }
        }
        
        checkConnection()
    }
    
    private func startRealtimeRecording() {
        logger.info("🎙️ Starting realtime recording...")
        
        guard !isRecording else { return }
        
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            try audioSession.overrideOutputAudioPort(.speaker)
            
            // Start M4A recording for audio file saving (same as original functionality)
            startM4ARecording()
            
            let config: [String: Any] = [
                "languageCode": languageCode,
                "sampleRateHertz": Int(sampleRate),
                "mediaEncoding": "pcm",
                "enableSpeakerDiarization": false,
                "maxSpeakerLabels": 2
            ]
            
            socket?.emit("start-transcription", config)
            logger.info("📤 Sent realtime transcription config: \(config)")
            
            startAudioCapture()
            
            isRecording = true
            isProcessing = true
            
            if shouldPreserveText {
                logger.info("🔒 Preserving previous text: '\(self.previousText)'")
            } else {
                recognizedText = ""
                previousText = ""
                currentPartialText = ""
                finalTextSegments = []
            }
            errorMessage = ""
            
        } catch {
            errorMessage = "Failed to start realtime recording: \(error.localizedDescription)"
            logger.error("❌ Failed to start realtime recording: \(error.localizedDescription)")
        }
    }
    
    private func startAudioCapture() {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            errorMessage = "Failed to create audio format"
            return
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            errorMessage = "Failed to create audio converter"
            return
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.processRealtimeAudioBuffer(buffer, converter: converter, outputFormat: outputFormat)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            logger.info("🎙️ Realtime audio engine started")
        } catch {
            errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
            logger.error("❌ Failed to start realtime audio engine: \(error.localizedDescription)")
        }
    }
    
    private func processRealtimeAudioBuffer(_ inputBuffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        guard isRecording else { return }
        
        let inputFrameCount = inputBuffer.frameLength
        let outputFrameCapacity = AVAudioFrameCount(Double(inputFrameCount) * (sampleRate / inputBuffer.format.sampleRate))
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            logger.error("❌ Realtime audio conversion error: \(error.localizedDescription)")
            return
        }
        
        if let pcmData = pcmDataFromBuffer(outputBuffer) {
            sendRealtimeAudioData(pcmData)
        }
    }
    
    private func pcmDataFromBuffer(_ buffer: AVAudioPCMBuffer) -> Data? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              let int16ChannelData = buffer.int16ChannelData else {
            return nil
        }
        
        let channelData = int16ChannelData[0]
        let dataSize = frameCount * MemoryLayout<Int16>.size
        
        let data = Data(bytes: channelData, count: dataSize)
        
        var processedData = Data()
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let int16Pointer = bytes.bindMemory(to: Int16.self).baseAddress else { return }
            
            var maxAmplitude: Int16 = 0
            for i in 0..<frameCount {
                maxAmplitude = max(maxAmplitude, abs(int16Pointer[i]))
            }
            
            let noiseThreshold: Int16 = 328
            let amplificationFactor = maxAmplitude > 0 ? min(Double(Int16.max) * 0.8 / Double(maxAmplitude), 3.0) : 1.0
            
            for i in 0..<frameCount {
                var sample = int16Pointer[i]
                
                if abs(sample) < noiseThreshold {
                    sample = Int16(Double(sample) * 0.1)
                } else {
                    sample = Int16(Double(sample) * amplificationFactor)
                }
                
                sample = max(Int16.min, min(Int16.max, sample))
                
                withUnsafeBytes(of: sample) { sampleBytes in
                    processedData.append(contentsOf: sampleBytes)
                }
            }
        }
        
        return processedData
    }
    
    private func sendRealtimeAudioData(_ data: Data) {
        guard isConnected else {
            logger.warning("⚠️ Not connected to realtime server, skipping audio send")
            return
        }
        
        let base64String = data.base64EncodedString()
        let audioData: [String: Any] = ["audio": base64String]
        
        socket?.emit("audio-data", audioData)
        
        if Int.random(in: 0..<100) < 5 {
            logger.debug("📤 Sent realtime audio data: \(data.count) bytes")
        }
    }
    
    private func stopAudioCapture() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        
        // Stop M4A recording when stopping audio capture
        stopM4ARecording()
        
        if !currentPartialText.isEmpty {
            finalTextSegments.append(currentPartialText)
            currentPartialText = ""
            logger.info("📝 Finalized pending partial text")
        }
        
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            logger.info("✅ Audio session reset")
        } catch {
            logger.error("⚠️ Failed to reset audio session: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Transcription Result Handling
    private func handleTranscriptionResult(transcript: String, isPartial: Bool) {
        logger.info("🎙️ Realtime transcription result: '\(transcript)' (partial: \(isPartial))")
        
        if !transcript.isEmpty {
            if isPartial {
                currentPartialText = transcript
                logger.info("🔄 Partial result updated: '\(self.currentPartialText)'")
            } else {
                finalTextSegments.append(transcript)
                currentPartialText = ""
                logger.info("✅ Final result added. Total segments: \(self.finalTextSegments.count)")
            }
            
            var completeText = self.finalTextSegments.joined(separator: " ")
            if !self.currentPartialText.isEmpty {
                if !completeText.isEmpty {
                    completeText += " " + self.currentPartialText
                } else {
                    completeText = self.currentPartialText
                }
            }
            
            if shouldPreserveText, !previousText.isEmpty {
                recognizedText = previousText + "\n" + completeText
            } else {
                recognizedText = completeText
            }
            
            logger.info("📝 Updated realtime text: '\(self.recognizedText)'")
        }
    }
    
    public func startMonitoring() {
        logger.info("🚀 Starting realtime audio monitoring with Socket.IO")
        
        audioSession.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.logger.info("✅ Microphone permission granted for realtime monitoring")
                    self?.connectToServerAndStartRecording()
                } else {
                    self?.errorMessage = "Microphone permission denied"
                }
            }
        }
    }
    
    public func stopMonitoring() {
        logger.info("🛑 停止实时音频流监控")
        stopRecognition()
        
        if isRecording {
            stopAudioCapture()
        }
        
        socket?.emit("stop-transcription")
    }
    
    // MARK: - Text Preservation Methods
    private var textPreservationRequested: Bool = false  // 跟踪是否请求了文字保留
    
    public func setTextPreservationMode(_ preserve: Bool) {
        textPreservationRequested = preserve
        shouldPreserveText = preserve
        if preserve {
            // 保存当前文字
            previousText = recognizedText
            logger.info("🔒 启用文字保留模式，保存文字: '\(self.previousText)'")
        } else {
            // 清除保存的文字
            previousText = ""
            textPreservationRequested = false
            logger.info("🔓 禁用文字保留模式")
        }
    }
    
    private func setupDarwinNotifications() {
        darwinNotificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        
        let notificationName = "dev.tuist2.Siri.audiodata" as CFString
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
        // 首先，使用原始数据重建CMSampleBuffer并保存到m4a文件（完全模仿ScreenBroadcastHandler）
        if let sampleBuffer = createSampleBufferFromData(data, formatInfo: formatInfo) {
            saveOriginalAudioToFile(sampleBuffer)
            
            // 使用重建的CMSampleBuffer进行语音识别（数据源已验证正常）
            if isProcessing {
                performSpeechRecognitionWithSampleBuffer(sampleBuffer)
                return
            }
        }
        
        guard isProcessing else {
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
        
        // 根据实际格式创建AVAudioFormat - 使用与成功WAV转换相同的格式
        // kAudioFormatLinearPCM = 1819304813 ('lpcm') 是线性PCM格式的标识符
        if formatID == kAudioFormatLinearPCM || formatID == 1819304813 {
            // PCM格式 - 参考成功的WAV转换格式
            if bitsPerChannel == 16 {
                // 16位整数 - 使用与WAV转换相同的格式参数
                // 参考AudioFileManager中成功的转换格式：
                // mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian
                var asbd = AudioStreamBasicDescription()
                asbd.mSampleRate = sampleRate
                asbd.mFormatID = kAudioFormatLinearPCM
                asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian
                asbd.mBitsPerChannel = 16
                asbd.mChannelsPerFrame = UInt32(channels)
                asbd.mBytesPerFrame = asbd.mChannelsPerFrame * 2
                asbd.mFramesPerPacket = 1
                asbd.mBytesPerPacket = asbd.mBytesPerFrame
                
                audioFormat = AVAudioFormat(streamDescription: &asbd)
                logger.info("🎵 使用WAV兼容格式: 16-bit signed integer, native endian, \(channels)声道")
            } else if bitsPerChannel == 32 {
                // 32位浮点 - 保持原有格式
                audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)
                logger.info("🎵 使用32位浮点格式")
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
        
        // 复制音频数据 - 16位格式使用交错数据（与WAV转换格式一致）
        data.withUnsafeBytes { (rawBytes: UnsafeRawBufferPointer) in
            if bitsPerChannel == 16 {
                // 16位整数数据 - 使用交错格式（与成功的WAV转换一致）
                guard let int16Pointer = rawBytes.bindMemory(to: Int16.self).baseAddress else {
                    return
                }
                
                // 对于交错格式，直接复制原始数据
                if let audioDataPointer = audioBuffer.audioBufferList.pointee.mBuffers.mData {
                    let sampleCount = Int(frameCount) * Int(channels)
                    let audioInt16Pointer = audioDataPointer.bindMemory(to: Int16.self, capacity: sampleCount)
                    audioInt16Pointer.initialize(from: int16Pointer, count: sampleCount)
                    
                    // 验证数据
                    let firstSample = int16Pointer[0]
                    let secondSample = channels > 1 ? int16Pointer[1] : firstSample
                    logger.info("🔍 交错格式复制: 首样本=\(firstSample), 次样本=\(secondSample), 总样本数=\(sampleCount)")
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
        
        // 注意：这里我们不直接保存audioBuffer，因为它是转换后的格式
        // 我们需要保存原始的CMSampleBuffer，但这里只有转换后的AVAudioPCMBuffer
        // 所以m4a保存需要在processAudioData中进行，使用原始数据
        
        // 保存转换后的音频数据用于验证
        saveConvertedAudioBuffer(audioBuffer)  // 重新启用，测试新的交错格式
        
        // Note: Using Socket.IO instead of traditional recognition request
        // The audio data is processed through Socket.IO connection
    }
    
    private func calculateAudioLevel(from audioBuffer: AVAudioPCMBuffer) -> Double {
        // 对于交错格式，使用audioBufferList访问数据
        guard let audioDataPointer = audioBuffer.audioBufferList.pointee.mBuffers.mData else {
            return 0.0
        }
        
        let frameCount = Int(audioBuffer.frameLength)
        let channels = Int(audioBuffer.format.channelCount)
        let sampleCount = frameCount * channels
        
        let int16Pointer = audioDataPointer.bindMemory(to: Int16.self, capacity: sampleCount)
        
        var sum: Double = 0.0
        
        for i in 0..<sampleCount {
            let sample = Double(int16Pointer[i]) / 32768.0 // 归一化到 -1.0 到 1.0
            sum += sample * sample
        }
        
        let rms = sqrt(sum / Double(sampleCount))
        return rms
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 使用 playback 模式，确保从扬声器输出，同时支持与其他音频混合
            // 移除 .duckOthers 选项，避免干扰其他音频播放
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // 强制设置音频路由到扬声器
            try audioSession.overrideOutputAudioPort(.speaker)
            logger.info("🎵 音频会话设置成功 (playback + default)")
        } catch {
            logger.error("❌ 音频会话设置失败: \(error.localizedDescription)")
        }
    }
    
    private func startRecognition() {
        logger.info("🚀 开始基于Socket.IO的语音识别")
        
        guard !isProcessing else {
            return
        }
        
        // 如果之前请求了文字保留模式，重新启用
        if textPreservationRequested {
            shouldPreserveText = true
            logger.info("🔄 恢复文字保留模式，之前保存的文字: '\(self.previousText)'")
        }
        
        // 确保音频从扬声器输出
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            logger.info("🔊 强制音频路由到扬声器")
        } catch {
            logger.error("❌ 设置扬声器输出失败: \(error.localizedDescription)")
        }
        
        isProcessing = true
        hasLoggedFormat = false
        
        // 重置m4a录制状态
        m4aStartTime = nil
        
        // 开始m4a文件录制 - 完全模仿ScreenBroadcastHandler
        startM4ARecording()
        
        // 开始录制转换后的音频用于验证 - 只保存WAV用于验证音频质量
        startConvertedAudioRecording()  // 保存用于语音识别的音频数据为WAV格式
        
        // 使用Socket.IO进行实时语音识别，而不是处理已录制的音频数据
        connectToServerAndStartRecording()
        
        logger.info("✅ 基于Socket.IO的语音识别任务已启动")
    }
    
    private func stopRecognition() {
        logger.info("🛑 停止Socket.IO语音识别")
        
        // 停止Socket.IO相关的录音
        if isRecording {
            stopAudioCapture()
        }
        
        // 发送停止信号到服务器
        socket?.emit("stop-transcription")
        
        isProcessing = false
        
        // 停止识别时暂时禁用文字保留模式，防止延迟回调导致文字重复
        if shouldPreserveText {
            logger.info("⏸️ 停止识别时暂时禁用文字保留模式")
            shouldPreserveText = false
        }
        
        // 停止m4a文件录制 - 模仿ScreenBroadcastHandler的stopAudioRecording
        stopM4ARecording()
        
        // 停止录制转换后的音频
        // stopConvertedAudioRecording()  // 暂时注释掉，只测试M4A到WAV转换
        
        logger.info("✅ Socket.IO语音识别已停止")
    }
    
    deinit {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveObserver(
            darwinNotificationCenter,
            observer,
            CFNotificationName("dev.tuist2.Siri.audiodata" as CFString),
            nil
        )
        socket?.disconnect()
    }
    
    // MARK: - Converted Audio Recording for Verification
    
    private func startConvertedAudioRecording() {
        // 简化：不再创建独立的音频文件，而是在结束时使用M4A文件转换
        logger.info("🎙️ 开始语音识别会话 - 将在录制结束时从M4A文件创建验证WAV")
    }
    
    private func saveConvertedAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        // 简化：不再保存音频数据，专注于语音识别功能
        // 验证音频质量的WAV文件将在录制结束时从M4A文件生成
        
        let frameCount = Int(audioBuffer.frameLength)
        let channels = Int(audioBuffer.format.channelCount)
        logger.debug("🔄 处理音频缓冲区: \(frameCount)帧, \(channels)声道")
    }
    
    private func stopConvertedAudioRecording() {
        // 使用最新的M4A文件转换为WAV用于验证语音识别音频质量
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        
        // 查找最新的M4A文件（与M4A转WAV转换使用相同数据源）
        do {
            let files = try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: [.creationDateKey])
            
            let m4aFiles = files.filter { $0.pathExtension == "m4a" && $0.lastPathComponent.hasPrefix("SystemAudio_") }
                .sorted { file1, file2 in
                    let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return date1 > date2
                }
            
            guard let latestM4A = m4aFiles.first else {
                logger.info("⚠️ 没有找到M4A文件用于验证")
                return
            }
            
            // 创建验证WAV文件名
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium).replacingOccurrences(of: ":", with: "-")
            let fileName = "RealtimeRecognition_\(timestamp).wav"
            let finalURL = audioDirectory.appendingPathComponent(fileName)
            
            // 使用与正常转换相同的方法转换M4A到WAV
            let audioFileManager = AudioFileManager()
            if let wavURL = audioFileManager.convertM4AToWAV(m4aURL: latestM4A) {
                // 重命名为验证文件
                try FileManager.default.moveItem(at: wavURL, to: finalURL)
                logger.info("✅ 语音识别验证WAV文件已创建: \(fileName)")
                notifyConvertedAudioFileCompleted(fileURL: finalURL)
            } else {
                logger.error("❌ M4A转WAV失败")
            }
            
        } catch {
            logger.error("❌ 查找M4A文件失败: \(error.localizedDescription)")
        }
        
        // 清理临时文件
        let tempDataURL = audioDirectory.appendingPathComponent("realtime_recognition_temp.pcm")
        try? FileManager.default.removeItem(at: tempDataURL)
        
        audioWriter = nil
        audioWriterInput = nil
        convertedAudioFileURL = nil
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
    
    // MARK: - M4A Audio Recording
    
    // 完全模仿ScreenBroadcastHandler的startAudioRecording方法
    private func startM4ARecording() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("❌ 无法获取App Group容器路径")
            return
        }
        
        // 创建音频目录
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        if !FileManager.default.fileExists(atPath: audioDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                logger.error("❌ 创建音频目录失败: \(error.localizedDescription)")
                return
            }
        }
        
        // 创建音频文件
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium).replacingOccurrences(of: ":", with: "-")
        let fileName = "RealtimeRecognition_\(timestamp).m4a"
        currentM4AFileURL = audioDirectory.appendingPathComponent(fileName)
        
        guard let audioFileURL = currentM4AFileURL else { return }
        
        // 设置音频写入器 - 完全复制ScreenBroadcastHandler的配置
        do {
            m4aAudioWriter = try AVAssetWriter(outputURL: audioFileURL, fileType: .m4a)
            
            // 配置音频设置 - 与ScreenBroadcastHandler完全一致
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            
            m4aAudioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            m4aAudioWriterInput?.expectsMediaDataInRealTime = true
            
            if let input = m4aAudioWriterInput {
                m4aAudioWriter?.add(input)
                m4aAudioWriter?.startWriting()
            }
            
            logger.info("🎙️ 开始录制音频: \(fileName)")
            
            // 通知主程序新文件已创建
            notifyM4AAudioFileCreated(fileName: fileName, fileURL: audioFileURL)
            
        } catch {
            logger.error("❌ 创建音频写入器失败: \(error.localizedDescription)")
        }
    }
    
    // 完全模仿ScreenBroadcastHandler的saveAudioToFile方法
    private func saveOriginalAudioToFile(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = m4aAudioWriter,
              let input = m4aAudioWriterInput else {
            logger.error("❌ m4aAudioWriter 或 m4aAudioWriterInput 为 nil")
            return
        }
        
        guard writer.status == .writing else {
            logger.error("❌ AVAssetWriter状态不是writing: \(writer.status.rawValue)")
            return
        }
        
        guard input.isReadyForMoreMediaData else {
            logger.warning("⚠️ AVAssetWriterInput 不准备接收更多数据")
            return
        }
        
        // 设置开始时间
        if m4aStartTime == nil {
            m4aStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            logger.info("🎵 准备开始M4A录制会话，时间戳: \(CMTimeGetSeconds(self.m4aStartTime!))")
            
            // 确保时间戳有效
            guard CMTIME_IS_VALID(m4aStartTime!) && CMTIME_IS_NUMERIC(m4aStartTime!) else {
                logger.error("❌ 无效的开始时间戳")
                m4aStartTime = nil
                return
            }
            
            writer.startSession(atSourceTime: m4aStartTime!)
            logger.info("✅ M4A录制会话已开始")
        }
        
        // 写入音频数据 - 完全模仿ScreenBroadcastHandler
        let success = input.append(sampleBuffer)
        if success {
            logger.debug("✅ 成功写入音频数据到M4A文件")
        } else {
            logger.error("❌ 写入音频数据到M4A文件失败")
        }
    }
    
    // 从原始音频数据重建CMSampleBuffer
    private func createSampleBufferFromData(_ data: Data, formatInfo: [String: Any]) -> CMSampleBuffer? {
        guard let sampleRate = formatInfo["sampleRate"] as? Double,
              let channels = formatInfo["channels"] as? UInt32,
              let formatID = formatInfo["formatID"] as? UInt32,
              let formatFlags = formatInfo["formatFlags"] as? UInt32,  // 关键：读取formatFlags
              let bitsPerChannel = formatInfo["bitsPerChannel"] as? UInt32,
              let bytesPerFrame = formatInfo["bytesPerFrame"] as? UInt32,
              let framesPerPacket = formatInfo["framesPerPacket"] as? UInt32,
              let bytesPerPacket = formatInfo["bytesPerPacket"] as? UInt32 else {
            logger.error("❌ 音频格式信息不完整: \(formatInfo)")
            return nil
        }
        
        logger.info("🔍 重建CMSampleBuffer - 数据大小: \(data.count)bytes, 格式: \(sampleRate)Hz, \(channels)声道, \(bitsPerChannel)位, formatID: \(formatID), flags: \(formatFlags)")
        
        // 创建音频流基本描述
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = formatID
        asbd.mChannelsPerFrame = channels
        asbd.mBitsPerChannel = bitsPerChannel
        asbd.mBytesPerFrame = bytesPerFrame
        asbd.mFramesPerPacket = framesPerPacket
        asbd.mBytesPerPacket = bytesPerPacket
        // 关键：直接使用从扩展程序发送的原始formatFlags
        asbd.mFormatFlags = formatFlags
        
        logger.info("🎵 使用原始音频格式标志: \(formatFlags)")
        
        // 创建音频格式描述
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        
        guard formatStatus == noErr, let audioFormatDescription = formatDescription else {
            logger.error("❌ 创建音频格式描述失败: \(formatStatus)")
            return nil
        }
        
        // 创建CMBlockBuffer - 使用拷贝方式确保数据安全
        var blockBuffer: CMBlockBuffer?
        let blockBufferStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,  // 让系统分配内存
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        // 将数据拷贝到CMBlockBuffer中
        if blockBufferStatus == noErr, let audioBlockBuffer = blockBuffer {
            let copyStatus = data.withUnsafeBytes { dataPtr in
                CMBlockBufferReplaceDataBytes(
                    with: dataPtr.baseAddress!,
                    blockBuffer: audioBlockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: data.count
                )
            }
            
            if copyStatus != noErr {
                logger.error("❌ 拷贝音频数据到CMBlockBuffer失败: \(copyStatus)")
                return nil
            }
        }
        
        guard blockBufferStatus == noErr, let audioBlockBuffer = blockBuffer else {
            logger.error("❌ 创建CMBlockBuffer失败: \(blockBufferStatus)")
            return nil
        }
        
        // 创建时间戳信息
        let frameCount = data.count / Int(bytesPerFrame)
        var sampleTiming = CMSampleTimingInfo()
        sampleTiming.duration = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(sampleRate))
        sampleTiming.presentationTimeStamp = CMTime(value: CMTimeValue(Date().timeIntervalSince1970 * sampleRate), timescale: CMTimeScale(sampleRate))
        sampleTiming.decodeTimeStamp = CMTime.invalid
        
        // 创建CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        let sampleBufferStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: audioBlockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: audioFormatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleBufferStatus == noErr else {
            logger.error("❌ 创建CMSampleBuffer失败: \(sampleBufferStatus)")
            return nil
        }
        
        return sampleBuffer
    }
    
    // MARK: - Speech Recognition with CMSampleBuffer
    
    private func performSpeechRecognitionWithSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Note: This method now processes audio for Socket.IO instead of SFSpeechRecognizer
        logger.info("🔄 Processing audio buffer for Socket.IO transcription")
        
        // 从 CMSampleBuffer 创建 AVAudioPCMBuffer 用于语音识别
        guard let audioBuffer = createAudioPCMBufferFromSampleBuffer(sampleBuffer) else {
            logger.warning("⚠️ 从CMSampleBuffer创建AVAudioPCMBuffer失败")
            return
        }
        
        // 检查音频数据是否有效（不是静音）
        let audioLevel = calculateSimpleAudioLevel(from: audioBuffer)
        logger.info("🎵 语音识别音频电平: \(String(format: "%.6f", audioLevel))")
        
        if audioLevel < 0.001 {
            logger.warning("⚠️ 音频电平太低，可能是静音数据")
        }
        
        // 保存转换后的音频数据用于验证
        saveConvertedAudioBuffer(audioBuffer)
        
        // Note: Audio data is processed through the existing Darwin notification system
        // which feeds into the Socket.IO connection established separately
        
        logger.debug("✅ 使用重建的CMSampleBuffer进行Socket.IO语音识别 (电平: \(String(format: "%.6f", audioLevel)))")
    }
    
    private func calculateSimpleAudioLevel(from audioBuffer: AVAudioPCMBuffer) -> Double {
        guard audioBuffer.frameLength > 0 else { return 0.0 }
        
        let format = audioBuffer.format
        let frameCount = Int(audioBuffer.frameLength)
        let channels = Int(format.channelCount)
        
        var sum: Double = 0.0
        var sampleCount = 0
        
        // 处理交错格式的音频数据
        if let audioData = audioBuffer.audioBufferList.pointee.mBuffers.mData {
            if format.commonFormat == .pcmFormatInt16 {
                // 16位整数格式
                let int16Pointer = audioData.bindMemory(to: Int16.self, capacity: frameCount * channels)
                for i in 0..<(frameCount * channels) {
                    let sample = Double(int16Pointer[i]) / 32768.0
                    sum += sample * sample
                    sampleCount += 1
                }
            } else if format.commonFormat == .pcmFormatFloat32 {
                // 32位浮点格式
                let floatPointer = audioData.bindMemory(to: Float.self, capacity: frameCount * channels)
                for i in 0..<(frameCount * channels) {
                    let sample = Double(floatPointer[i])
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        }
        
        guard sampleCount > 0 else { return 0.0 }
        
        let rms = sqrt(sum / Double(sampleCount))
        return rms
    }
    
    private func createAudioPCMBufferFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            logger.error("❌ 无法获取CMSampleBuffer格式描述")
            return nil
        }
        
        let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let audioStreamDescription = streamDescription else {
            logger.error("❌ 无法获取音频流描述")
            return nil
        }
        
        logger.info("🔍 输入音频格式: \(audioStreamDescription.pointee.mSampleRate)Hz, \(audioStreamDescription.pointee.mChannelsPerFrame)声道, \(audioStreamDescription.pointee.mBitsPerChannel)位")
        
        // 简化：直接使用原始格式进行语音识别，不进行复杂的格式转换
        guard let inputAVFormat = AVAudioFormat(streamDescription: audioStreamDescription) else {
            logger.error("❌ 创建输入音频格式失败")
            return nil
        }
        
        // 获取输入数据
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            logger.error("❌ 无法获取CMSampleBuffer数据缓冲区")
            return nil
        }
        
        let dataLength = CMBlockBufferGetDataLength(blockBuffer)
        let inputFrameCount = AVAudioFrameCount(dataLength / Int(audioStreamDescription.pointee.mBytesPerFrame))
        
        logger.info("🔍 音频数据: 长度=\(dataLength)字节, 帧数=\(inputFrameCount)")
        
        guard inputFrameCount > 0 else {
            logger.warning("⚠️ 音频帧数为0，跳过处理")
            return nil
        }
        
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputAVFormat, frameCapacity: inputFrameCount) else {
            logger.error("❌ 创建输入PCM缓冲区失败")
            return nil
        }
        
        // 复制数据到输入缓冲区
        var dataPointer: UnsafeMutablePointer<Int8>?
        let result = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
        
        guard result == noErr, let data = dataPointer else {
            logger.error("❌ 无法获取音频数据指针: \(result)")
            return nil
        }
        
        // 直接复制音频数据
        let audioBufferList = inputBuffer.mutableAudioBufferList
        audioBufferList.pointee.mBuffers.mData?.copyMemory(from: data, byteCount: dataLength)
        audioBufferList.pointee.mBuffers.mDataByteSize = UInt32(dataLength)
        inputBuffer.frameLength = inputFrameCount
        
        logger.info("✅ 音频PCM缓冲区创建成功: \(inputFrameCount)帧")
        
        return inputBuffer
    }
    
    // 完全模仿ScreenBroadcastHandler的stopAudioRecording方法
    private func stopM4ARecording() {
        guard let writer = m4aAudioWriter else { return }
        
        m4aAudioWriterInput?.markAsFinished()
        
        // 保存URL的副本，防止在异步块中被清空
        let audioFileURL = currentM4AFileURL
        
        writer.finishWriting { [weak self] in
            if writer.status == .completed {
                self?.logger.info("✅ 音频文件录制完成")
                if let url = audioFileURL {
                    Task { @MainActor in
                        self?.notifyM4AAudioFileCompleted(fileURL: url)
                    }
                    self?.logger.info("📁 音频文件已保存: \(url.lastPathComponent)")
                }
            } else if let error = writer.error {
                self?.logger.error("❌ 音频文件写入失败: \(error.localizedDescription)")
            }
            
            // 清理引用
            Task { @MainActor in
                self?.m4aAudioWriter = nil
                self?.m4aAudioWriterInput = nil
                self?.currentM4AFileURL = nil
                self?.m4aStartTime = nil  // 确保重置开始时间
            }
        }
    }
    
    private func notifyM4AAudioFileCreated(fileName: String, fileURL: URL) {
        let notification: [String: Any] = [
            "event": "audio_file_created",
            "fileName": fileName,
            "filePath": fileURL.path,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let notificationURL = containerURL.appendingPathComponent("realtime_audio_notification.json")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: notification, options: [])
            try jsonData.write(to: notificationURL)
            logger.info("📡 已通知M4A音频文件创建")
        } catch {
            logger.error("❌ 写入M4A音频创建通知失败: \(error.localizedDescription)")
        }
    }
    
    private func notifyM4AAudioFileCompleted(fileURL: URL) {
        let notification: [String: Any] = [
            "event": "audio_file_completed",
            "fileName": fileURL.lastPathComponent,
            "filePath": fileURL.path,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let notificationURL = containerURL.appendingPathComponent("realtime_audio_notification.json")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: notification, options: [])
            try jsonData.write(to: notificationURL)
            
            // 发送Darwin通知
            let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
            let notificationName = CFNotificationName("dev.tuist2.Siri.realtimeAudioSaved" as CFString)
            CFNotificationCenterPostNotification(darwinCenter, notificationName, nil, nil, true)
            
            logger.info("📡 已通知M4A音频文件完成")
        } catch {
            logger.error("❌ 写入M4A音频完成通知失败: \(error.localizedDescription)")
        }
    }
}

