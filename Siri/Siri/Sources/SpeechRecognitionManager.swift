import Foundation
import AVFoundation
import Combine
import SocketIO
import os.log

// MARK: - Speech Recognition Manager (Using Socket.IO)
@MainActor
public class SpeechRecognitionManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published public var recognizedText: String = ""
    @Published public var isRecording: Bool = false
    @Published public var isAuthorized: Bool = true // Socket.IO doesn't need speech recognition permission
    @Published public var isConnected: Bool = false
    @Published public var errorMessage: String = ""
    
    // MARK: - Private Properties for text management
    private var previousText: String = ""
    private var appendToExistingText: Bool = false
    private var currentPartialText: String = "" // Track current partial result
    private var finalTextSegments: [String] = [] // Store finalized text segments
    
    // MARK: - Private Properties
    private var audioEngine = AVAudioEngine()
    private var audioSession = AVAudioSession.sharedInstance()
    private let logger = Logger(subsystem: "dev.tuist2.Siri", category: "SocketIOTranscription")
    
    // Socket.IO Properties
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private let serverURL = "https://api-test.pleaseprof.app" // Use https instead of wss
    private let namespace = "/transcribe" // Separate namespace
    
    // Audio Processing Properties
    private var sampleRate: Double = 16000
    private var languageCode: String = "zh-CN"
    
    // MARK: - Initialization
    public override init() {
        super.init()
        setupSocketConnection()
    }
    
    // MARK: - Socket.IO Setup
    private func setupSocketConnection() {
        guard let url = URL(string: serverURL) else {
            errorMessage = "Invalid server URL"
            logger.error("❌ Invalid server URL: \(self.serverURL)")
            return
        }
        
        logger.info("🔧 Setting up Socket.IO connection to \(self.serverURL)")
        
        // Force WebSocket transport only (no polling fallback)
        manager = SocketManager(socketURL: url, config: [
            .log(true),
            .compress,
            .forceWebsockets(true),     // Force WebSocket only
            .forcePolling(false),       // Disable polling
            .reconnects(true),
            .reconnectAttempts(3),
            .reconnectWait(1),
            .reconnectWaitMax(5)
        ])
        
        // Connect to the transcribe namespace
        socket = manager?.socket(forNamespace: namespace)
        setupSocketHandlers()
        
        // Don't auto-connect in setup, wait for explicit call
        logger.info("✅ Socket.IO client configured")
    }
    
    private func setupSocketHandlers() {
        logger.info("🔌 Setting up Socket.IO handlers...")
        
        socket?.on(clientEvent: .connect) { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.isConnected = true
                self?.logger.info("✅ Connected to transcription service")
                self?.logger.info("🔗 Socket status: \(self?.socket?.status.description ?? "unknown")")
                self?.errorMessage = ""
            }
        }
        
        socket?.on("user-assigned") { [weak self] data, ack in
            guard let userInfo = data.first as? [String: Any],
                  let userId = userInfo["userId"] as? String else { return }
            DispatchQueue.main.async {
                self?.logger.info("📋 Assigned user ID: \(userId)")
            }
        }
        
        socket?.on(clientEvent: .disconnect) { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.logger.info("❌ Disconnected from transcription service: \(data)")
                self?.errorMessage = "Disconnected from server"
            }
        }
        
        socket?.on(clientEvent: .error) { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.logger.error("⚠️ Socket error: \(data)")
                self?.errorMessage = "Connection error: \(data)"
            }
        }
        
        // Add more detailed connection event handlers
        socket?.on(clientEvent: .error) { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.logger.error("🔴 Socket error: \(data)")
                self?.errorMessage = "Socket error: \(data)"
            }
        }
        
        socket?.on("connect_error") { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.logger.error("🔴 Connect error: \(data)")
                self?.errorMessage = "Failed to connect: \(data)"
            }
        }
        
        socket?.on("reconnect") { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.logger.info("🔁 Reconnected: \(data)")
                self?.isConnected = true
                self?.errorMessage = ""
            }
        }
        
        // Engine events are handled internally by SocketManager
        
        socket?.on("transcription-started") { [weak self] data, ack in
            DispatchQueue.main.async {
                self?.logger.info("🎙️ Transcription started")
            }
        }
        
        socket?.on("transcription-result") { [weak self] data, ack in
            self?.logger.info("📝 Received transcription-result event: \(data)")
            
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
                self?.logger.error("❌ Transcription error: \(error)")
            }
        }
    }
    
    // MARK: - Permission Handling
    public func requestAuthorization() {
        // Only need microphone permission for Socket.IO approach
        audioSession.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                if !granted {
                    self?.errorMessage = "Microphone permission denied"
                } else {
                    self?.logger.info("✅ Microphone permission granted")
                    // Don't auto-connect here, let startRecording handle it
                }
            }
        }
    }
    
    // MARK: - Connection Management
    private func connectToServer(completion: @escaping () -> Void) {
        logger.info("🔌 Attempting to connect to server (current: \(self.isConnected))")
        
        if isConnected {
            logger.info("✅ Already connected")
            completion()
            return
        }
        
        // Clean reconnection approach
        logger.info("🔌 Initiating Socket.IO connection to \(self.serverURL)\(self.namespace)...")
        socket?.connect()
        
        // Wait for connection with timeout
        waitForConnection(timeout: 10.0, completion: completion)
    }
    
    private func waitForConnection(timeout: TimeInterval, completion: @escaping () -> Void) {
        let startTime = Date()
        
        func checkConnection() {
            if isConnected {
                logger.info("✅ Connected successfully!")
                completion()
                return
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > timeout {
                logger.error("⏰ Connection timeout after \(timeout)s")
                errorMessage = "Failed to connect to transcription server"
                // Still proceed with local recording
                completion()
                return
            }
            
            // Check again in 100ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                checkConnection()
            }
        }
        
        checkConnection()
    }
    
    // MARK: - Recording Control
    public func startRecording(clearPreviousText: Bool = true) {
        guard isAuthorized else {
            requestAuthorization()
            return
        }
        
        guard !isRecording else { return }
        
        // Force connection before recording
        connectToServer {
            self.startRecordingInternal(clearPreviousText: clearPreviousText)
        }
    }
    
    public func stopRecording() {
        guard isRecording else { return }
        
        logger.info("🛑 Stopping recording...")
        isRecording = false
        
        // Stop audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // Send stop signal to server
        socket?.emit("stop-transcription")
        
        // Finalize any pending partial text
        if !currentPartialText.isEmpty {
            finalTextSegments.append(currentPartialText)
            currentPartialText = ""
            logger.info("📝 Finalized pending partial text")
        }
        
        // Reset audio session
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            logger.info("✅ Audio session reset")
        } catch {
            logger.error("⚠️ Failed to reset audio session: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Text Management
    public func clearRecognizedText() {
        recognizedText = ""
        previousText = ""
        currentPartialText = ""
        finalTextSegments = []
        appendToExistingText = false
        logger.info("🗑️ Cleared all recognized text")
    }
    
    // MARK: - Audio Recording Implementation
    private func startRecordingInternal(clearPreviousText: Bool) {
        logger.info("🎤 Starting recording internal (connected: \(self.isConnected))")
        
        do {
        
            // Configure audio session
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            try audioSession.overrideOutputAudioPort(.speaker)
        
            // Send transcription config to server
            let config: [String: Any] = [
                "languageCode": languageCode,
                "sampleRateHertz": Int(sampleRate),
                "mediaEncoding": "pcm",
                "enableSpeakerDiarization": false,
                "maxSpeakerLabels": 2
            ]
            
            socket?.emit("start-transcription", config) {
                self.logger.info("📤✅ start-transcription acknowledged by server")
            }
            logger.info("📤 Sent transcription config: \(config)")
        
            // Start audio capture
            startAudioCapture()
        
            isRecording = true
            if clearPreviousText {
                recognizedText = ""
                previousText = ""
                appendToExistingText = false
                // Clear transcription state
                currentPartialText = ""
                finalTextSegments = []
            } else {
                previousText = recognizedText
                appendToExistingText = true
                // Keep current transcription state for continuation
            }
            errorMessage = ""
            
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            logger.error("❌ Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Audio Capture
    private func startAudioCapture() {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Create a format for 16kHz mono PCM
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            errorMessage = "Failed to create audio format"
            return
        }
        
        // Create converter for resampling if needed
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            errorMessage = "Failed to create audio converter"
            return
        }
        
        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, converter: converter, outputFormat: outputFormat)
        }
        
        // Prepare and start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            logger.info("🎤 Audio engine started")
        } catch {
            errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
            logger.error("❌ Failed to start audio engine: \(error.localizedDescription)")
        }
    }
    
    private func processAudioBuffer(_ inputBuffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
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
            logger.error("❌ Audio conversion error: \(error.localizedDescription)")
            return
        }
        
        // Convert to PCM data and send via Socket.IO
        if let pcmData = pcmDataFromBuffer(outputBuffer) {
            sendAudioData(pcmData)
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
        
        // Create Data from the audio buffer
        let data = Data(bytes: channelData, count: dataSize)
        
        // Apply simple noise reduction and normalization
        var processedData = Data()
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let int16Pointer = bytes.bindMemory(to: Int16.self).baseAddress else { return }
            
            var maxAmplitude: Int16 = 0
            for i in 0..<frameCount {
                maxAmplitude = max(maxAmplitude, abs(int16Pointer[i]))
            }
            
            let noiseThreshold: Int16 = 328 // ~1% of max int16 value
            let amplificationFactor = maxAmplitude > 0 ? min(Double(Int16.max) * 0.8 / Double(maxAmplitude), 3.0) : 1.0
            
            for i in 0..<frameCount {
                var sample = int16Pointer[i]
                
                // Simple noise gate
                if abs(sample) < noiseThreshold {
                    sample = Int16(Double(sample) * 0.1)
                } else {
                    sample = Int16(Double(sample) * amplificationFactor)
                }
                
                // Clamp to int16 range
                sample = max(Int16.min, min(Int16.max, sample))
                
                withUnsafeBytes(of: sample) { sampleBytes in
                    processedData.append(contentsOf: sampleBytes)
                }
            }
        }
        
        return processedData
    }
    
    private func sendAudioData(_ data: Data) {
        guard isConnected else {
            logger.warning("⚠️ Not connected, skipping audio send")
            return
        }
        
        // Convert to base64 for transmission
        let base64String = data.base64EncodedString()
        let audioData: [String: Any] = ["audio": base64String]
        
        socket?.emit("audio-data", audioData)
        
        // Log periodically to avoid spam
        if Int.random(in: 0..<100) < 5 { // 5% chance to log
            logger.debug("📤 Sent audio data: \(data.count) bytes (connected: \(self.isConnected))")
        }
    }
    
    // MARK: - Transcription Result Handling
    private func handleTranscriptionResult(transcript: String, isPartial: Bool) {
        logger.info("🎤 Transcription result: '\(transcript)' (partial: \(isPartial))")
        
        if !transcript.isEmpty {
            if isPartial {
                // Partial result: update current partial text
                currentPartialText = transcript
                logger.info("🔄 Partial result updated: '\(self.currentPartialText)'")
            } else {
                // Final result: add to segments and clear partial
                finalTextSegments.append(transcript)
                currentPartialText = ""
                logger.info("✅ Final result added. Total segments: \(self.finalTextSegments.count)")
            }
            
            // Rebuild complete text: all final segments + current partial
            var completeText = self.finalTextSegments.joined(separator: " ")
            if !self.currentPartialText.isEmpty {
                if !completeText.isEmpty {
                    completeText += " " + self.currentPartialText
                } else {
                    completeText = self.currentPartialText
                }
            }
            
            // Handle append mode for push-to-talk
            if appendToExistingText, !previousText.isEmpty {
                recognizedText = previousText + " " + completeText
            } else {
                recognizedText = completeText
            }
            
            logger.info("📝 Updated text: '\(self.recognizedText)'")
        }
    }
    
    deinit {
        socket?.disconnect()
    }
}
