import Foundation
import Speech
import AVFoundation
import Combine

// MARK: - Speech Recognition Manager
@MainActor
public class SpeechRecognitionManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published public var recognizedText: String = ""
    @Published public var isRecording: Bool = false
    @Published public var isAuthorized: Bool = false
    @Published public var errorMessage: String = ""
    
    // MARK: - Private Properties
    private var audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioSession = AVAudioSession.sharedInstance()
    
    // MARK: - Initialization
    public override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) // 中文识别
        guard speechRecognizer != nil else {
            self.errorMessage = "Speech recognizer not available for this locale"
            return
        }
        
        // Check if speech recognizer is available
        speechRecognizer?.delegate = self
    }
    
    // MARK: - Permission Handling
    public func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self?.isAuthorized = true
                    self?.requestMicrophonePermission()
                case .denied, .restricted, .notDetermined:
                    self?.isAuthorized = false
                    self?.errorMessage = "Speech recognition authorization denied"
                @unknown default:
                    self?.isAuthorized = false
                    self?.errorMessage = "Unknown authorization status"
                }
            }
        }
    }
    
    private func requestMicrophonePermission() {
        audioSession.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if !granted {
                    self?.errorMessage = "Microphone permission denied"
                }
            }
        }
    }
    
    // MARK: - Recording Control
    public func startRecording() {
        guard isAuthorized else {
            requestAuthorization()
            return
        }
        
        guard !isRecording else { return }
        
        do {
            try startSpeechRecognition()
        } catch {
            self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }
    
    public func stopRecording() {
        guard isRecording else { return }
        
        print("🛑 [Speech] 停止录音...")
        isRecording = false
        
        // 安全地停止所有组件
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        
        // 重置音频会话，避免冲突
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            print("✅ [Speech] 音频会话已重置")
        } catch {
            print("⚠️ [Speech] 音频会话重置失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Speech Recognition Implementation
    private func startSpeechRecognition() throws {
        // Cancel any previous task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Configure audio session - 使用 playAndRecord 避免与画中画的播放冲突
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .mixWithOthers, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "SpeechRecognitionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        // Get audio input node
        let inputNode = audioEngine.inputNode
        
        // Create recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result = result {
                    self?.recognizedText = result.bestTranscription.formattedString
                }
                
                if let error = error {
                    self?.errorMessage = "Recognition error: \(error.localizedDescription)"
                    self?.stopRecording()
                }
            }
        }
        
        // Configure audio format
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()
        
        isRecording = true
        recognizedText = ""
        errorMessage = ""
    }
}

// MARK: - SFSpeechRecognizerDelegate
extension SpeechRecognitionManager: @preconcurrency SFSpeechRecognizerDelegate {
    nonisolated public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            if !available {
                self.isAuthorized = false
                self.errorMessage = "Speech recognizer became unavailable"
            }
        }
    }
}
