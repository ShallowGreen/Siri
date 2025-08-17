import Foundation
import AVKit
import UIKit
import SwiftUI
import AVFoundation

// MARK: - Picture in Picture Text Overlay View
public class PictureInPictureTextView: UIView {
    
    // MARK: - UI Components
    private let textLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let backgroundView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        view.layer.cornerRadius = 12
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    // MARK: - Initialization
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    // MARK: - Private Methods
    private func setupUI() {
        backgroundColor = .clear
        
        addSubview(backgroundView)
        backgroundView.addSubview(textLabel)
        
        // 创建约束并设置优先级以避免冲突
        let centerXConstraint = backgroundView.centerXAnchor.constraint(equalTo: centerXAnchor)
        let centerYConstraint = backgroundView.centerYAnchor.constraint(equalTo: centerYAnchor)
        centerYConstraint.priority = UILayoutPriority(999) // 略低于required
        
        let leadingConstraint = backgroundView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8)
        let trailingConstraint = backgroundView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        let topConstraint = backgroundView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4)
        let bottomConstraint = backgroundView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        
        // 设置边距约束为低优先级，允许在小窗口中被打破
        topConstraint.priority = UILayoutPriority(900)
        bottomConstraint.priority = UILayoutPriority(900)
        leadingConstraint.priority = UILayoutPriority(900)
        trailingConstraint.priority = UILayoutPriority(900)
        
        NSLayoutConstraint.activate([
            centerXConstraint,
            centerYConstraint,
            leadingConstraint,
            trailingConstraint,
            topConstraint,
            bottomConstraint,
            
            // Text label constraints - 使用更小的边距
            textLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -8),
            textLabel.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 4),
            textLabel.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -4)
        ])
    }
    
    // MARK: - Public Methods
    public func updateText(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.textLabel.text = text.isEmpty ? "等待语音输入..." : text
            print("📺 [PiPView] 更新文字: \(text)")
        }
    }
}

// MARK: - Picture in Picture Manager
@MainActor
public class PictureInPictureManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published public var isPipActive: Bool = false
    @Published public var canStartPip: Bool = false
    @Published public var errorMessage: String = ""
    @Published public var recognizedText: String = ""
    
    // MARK: - Private Properties
    private var pipController: AVPictureInPictureController?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var pipTextView: PictureInPictureTextView?
    private var pipWindow: UIWindow?
    private var suspectedWindows: [UIWindow] = []
    
    // MARK: - Initialization
    public override init() {
        print("🎬 [PiP] 初始化PictureInPictureManager")
        super.init()
        setupPictureInPicture()
    }
    
    // MARK: - Public Methods
    public func updateText(_ text: String) {
        recognizedText = text
        pipTextView?.updateText(text)
        print("📝 [PiP] 更新识别文字: \(text)")
    }
    
    public func startPictureInPicture() {
        print("🎬 [PiP] 开始启动画中画...")
        
        // 🔑 关键修复：在启动画中画之前确保通知监听已设置
        if pipWindow == nil {
            print("📡 [PiP] pipWindow为空，重新设置窗口监听以捕获新窗口...")
            print("   - 当前疑似窗口数量: \(suspectedWindows.count)")
            // 注意：不清空疑似窗口，保留已收集的窗口
            // 重新设置通知监听以捕获可能的新窗口
            setupNotifications()
        }
        
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("❌ [PiP] 设备不支持画中画功能")
            errorMessage = "此设备不支持画中画功能"
            return
        }
        
        guard let pipController = pipController else {
            print("❌ [PiP] 画中画控制器未初始化")
            errorMessage = "画中画控制器未初始化"
            return
        }
        
        guard canStartPip else {
            print("❌ [PiP] 当前无法启动画中画")
            errorMessage = "当前无法启动画中画"
            return
        }
        
        // 确保播放器和播放器层都在正确状态
        guard let player = player, let playerLayer = playerLayer else {
            print("❌ [PiP] 播放器或播放器层未初始化")
            errorMessage = "播放器未正确初始化"
            return
        }
        
        // 检查播放器层是否在视图层次中
        print("🎬 [PiP] 检查播放器层状态...")
        print("   - 播放器层父视图: \(playerLayer.superlayer != nil ? "存在" : "不存在")")
        print("   - 播放器状态: \(player.timeControlStatus)")
        
        print("🎬 [PiP] 启动播放器...")
        player.play()
        
        // 延迟一点确保播放器准备好
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            print("🎬 [PiP] 调用 startPictureInPicture...")
            pipController.startPictureInPicture()
        }
    }
    
    public func stopPictureInPicture() {
        print("🛑 [PiP] 停止画中画...")
        pipController?.stopPictureInPicture()
    }
    
    public func setupPlayerLayer(in view: UIView) {
        guard let playerLayer = playerLayer else {
            print("❌ [PiP] 播放器层不存在，无法设置到视图")
            return
        }
        
        print("📺 [PiP] 设置播放器层到容器视图")
        playerLayer.frame = view.bounds
        view.layer.addSublayer(playerLayer)
        
        // 确保视图在屏幕可见区域内且保持可见
        view.isHidden = false
        view.alpha = 0.01 // 几乎透明，但仍然可见
        view.backgroundColor = UIColor.clear
        
        // 立即开始播放以确保画中画可用
        player?.play()
        
        print("📺 [PiP] 播放器层设置完成，开始播放")
    }
    
    // MARK: - Private Methods
    private func setupPictureInPicture() {
        print("🎬 [PiP] 开始设置画中画...")
        setupAudioSession()
        createVideoPlayer()
        createPictureInPictureController()
        setupNotifications()
        updateCanStartPip()
        print("🎬 [PiP] 画中画设置完成")
    }
    
    private func setupAudioSession() {
        print("🎵 [PiP] 设置音频会话...")
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 使用 playAndRecord 模式支持同时录音和播放，添加 allowBluetooth 选项
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true)
            print("✅ [PiP] 音频会话设置成功")
        } catch {
            print("❌ [PiP] 音频会话设置失败: \(error.localizedDescription)")
            errorMessage = "音频会话设置失败: \(error.localizedDescription)"
        }
    }
    
    private func createVideoPlayer() {
        print("🎥 [PiP] 创建视频播放器...")
        
        // 创建占位视频
        guard let videoURL = VideoGenerator.createPlaceholderVideo(width: 2000, height: 400) else {
            print("❌ [PiP] 占位视频创建失败")
            errorMessage = "占位视频创建失败"
            return
        }
        
        // 创建播放器
        let playerItem = AVPlayerItem(url: videoURL)
        player = AVPlayer(playerItem: playerItem)
        
        // 禁用自动暂停
        player?.automaticallyWaitsToMinimizeStalling = false
        player?.preventsDisplaySleepDuringVideoPlayback = false
        
        // 创建播放器层
        playerLayer = AVPlayerLayer(player: player)
        playerLayer?.videoGravity = .resizeAspectFill
        playerLayer?.backgroundColor = UIColor.black.cgColor
        
        // 设置循环播放
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player?.seek(to: .zero)
                self?.player?.play()
            }
        }
        
        print("✅ [PiP] 视频播放器创建成功")
    }
    
    private func createPictureInPictureController() {
        print("🎮 [PiP] 创建画中画控制器...")
        
        guard let playerLayer = playerLayer else {
            print("❌ [PiP] 播放器层不存在")
            errorMessage = "无法创建播放器层"
            return
        }
        
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("❌ [PiP] 设备不支持画中画")
            errorMessage = "此设备不支持画中画功能"
            return
        }
        
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController?.delegate = self
        pipController?.requiresLinearPlayback = true
        
        // 使用私有API隐藏播放控件
        if pipController?.responds(to: NSSelectorFromString("setControlsStyle:")) == true {
            pipController?.setValue(1, forKey: "controlsStyle")
            print("✅ [PiP] 播放控件已隐藏")
        }
        
        // 启用自动画中画
        pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        
        print("✅ [PiP] 画中画控制器创建成功")
    }
    
    private func setupNotifications() {
        print("📡 [PiP] 设置窗口显示通知监听...")
        
        // 先移除旧的监听器，避免重复添加
        NotificationCenter.default.removeObserver(
            self,
            name: UIWindow.didBecomeVisibleNotification,
            object: nil
        )
        
        // 重新添加监听窗口显示通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeVisible(_:)),
            name: UIWindow.didBecomeVisibleNotification,
            object: nil
        )
        print("✅ [PiP] 窗口显示通知监听设置完成")
    }
    
    @objc private func windowDidBecomeVisible(_ notification: Notification) {
        guard let window = notification.object as? UIWindow else { return }
        
        let windowType = NSStringFromClass(type(of: window))
        print("🪟 [PiP] 检测到窗口显示:")
        print("   - 窗口类型: \(windowType)")
        print("   - 窗口大小: \(window.frame)")
        print("   - 窗口级别: \(window.windowLevel.rawValue)")
        print("   - 当前疑似窗口数量: \(suspectedWindows.count)")
        
        // 检查是否是画中画窗口
        if windowType.contains("PGHostedWindow") {
            print("✅ [PiP] 找到PGHostedWindow")
            pipWindow = window
            setupTextOverlay()
            print("🚫 [PiP] 移除窗口显示通知监听器")
            NotificationCenter.default.removeObserver(
                self,
                name: UIWindow.didBecomeVisibleNotification,
                object: nil
            )
        } else {
            // 加入疑似窗口列表
            suspectedWindows.append(window)
            print("📝 [PiP] 添加疑似窗口: \(windowType)")
            
            // 🔑 关键修复：如果画中画已激活但还没找到PGHostedWindow，尝试立即过滤
            if isPipActive && pipWindow == nil {
                print("🔍 [PiP] 画中画已激活但未找到窗口，尝试从疑似窗口中查找...")
                if let foundWindow = filterTargetWindow() {
                    print("✅ [PiP] 从疑似窗口中找到目标窗口")
                    pipWindow = foundWindow
                    setupTextOverlay()
                    print("🚫 [PiP] 移除窗口显示通知监听器")
                    NotificationCenter.default.removeObserver(
                        self,
                        name: UIWindow.didBecomeVisibleNotification,
                        object: nil
                    )
                }
            }
        }
    }
    
    private func filterTargetWindow() -> UIWindow? {
        print("🔍 [PiP] 开始过滤目标窗口...")
        
        // 🔑 新策略：同时检查系统中所有窗口
        let allWindows = UIApplication.shared.windows
        print("   - 系统中所有窗口总数: \(allWindows.count)")
        print("   - 疑似窗口总数: \(suspectedWindows.count)")
        
        // 打印系统中所有窗口
        for (index, window) in allWindows.enumerated() {
            let windowType = NSStringFromClass(type(of: window))
            print("   - 系统窗口[\(index)]: \(windowType)")
            print("     大小: \(window.frame)")
            print("     级别: \(window.windowLevel.rawValue)")
            print("     可见: \(window.isHidden ? "否" : "是")")
        }
        
        // 打印疑似窗口的详细信息
        for (index, window) in suspectedWindows.enumerated() {
            let windowType = NSStringFromClass(type(of: window))
            print("   - 疑似窗口[\(index)]: \(windowType)")
            print("     大小: \(window.frame)")
            print("     级别: \(window.windowLevel.rawValue)")
        }
        
        // 🔑 首先从系统所有窗口中查找画中画窗口
        for (index, window) in allWindows.enumerated() {
            let windowType = NSStringFromClass(type(of: window))
            // 扩展画中画窗口类型检测
            if windowType.contains("PGHostedWindow") || 
               windowType.contains("PictureInPicture") ||
               windowType.contains("AVPictureInPicture") ||
               windowType.contains("PiP") {
                print("✅ [PiP] 在系统窗口[\(index)]中找到画中画窗口: \(windowType)")
                return window
            }
        }
        
        // 然后从疑似窗口中查找
        for (index, window) in suspectedWindows.enumerated() {
            let windowType = NSStringFromClass(type(of: window))
            if windowType.contains("PGHostedWindow") || 
               windowType.contains("PictureInPicture") ||
               windowType.contains("AVPictureInPicture") ||
               windowType.contains("PiP") {
                print("✅ [PiP] 在疑似窗口[\(index)]中找到画中画窗口: \(windowType)")
                return window
            }
        }
        print("❌ [PiP] 未找到画中画相关窗口")
        
        // 查找特殊的窗口级别 - 从系统窗口
        for (index, window) in allWindows.enumerated() {
            if window.windowLevel.rawValue == -10000000 {
                print("✅ [PiP] 在系统窗口[\(index)]中找到特殊级别窗口")
                return window
            }
        }
        // 查找特殊的窗口级别 - 从疑似窗口
        for (index, window) in suspectedWindows.enumerated() {
            if window.windowLevel.rawValue == -10000000 {
                print("✅ [PiP] 在疑似窗口[\(index)]中找到特殊级别窗口")
                return window
            }
        }
        print("❌ [PiP] 未找到特殊级别窗口")
        
        // 根据高度过滤 - 从系统窗口
        for (index, window) in allWindows.enumerated() {
            let height = window.frame.size.height
            let windowType = NSStringFromClass(type(of: window))
            // 跳过主应用窗口
            if windowType.contains("UITextEffectsWindow") && height > 500 {
                continue
            }
            // 接受小高度窗口(< 300) 或 零大小窗口(可能是初始状态)
            if height < 300 || (height == 0 && window.frame.size.width == 0) {
                print("✅ [PiP] 在系统窗口[\(index)]中找到目标窗口: \(window.frame.size)")
                return window
            }
        }
        // 根据高度过滤 - 从疑似窗口
        for (index, window) in suspectedWindows.enumerated() {
            let height = window.frame.size.height
            // 接受小高度窗口(< 300) 或 零大小窗口(可能是初始状态)
            if height < 300 || (height == 0 && window.frame.size.width == 0) {
                print("✅ [PiP] 在疑似窗口[\(index)]中找到目标窗口: \(window.frame.size)")
                return window
            }
        }
        print("❌ [PiP] 未找到符合条件的窗口")
        
        // 🚫 不要使用主应用窗口作为fallback！
        // UITextEffectsWindow 通常是主应用窗口，不是画中画窗口
        for window in suspectedWindows {
            let windowType = NSStringFromClass(type(of: window))
            if windowType.contains("UITextEffectsWindow") && window.frame.height > 500 {
                print("🚫 [PiP] 跳过主应用窗口: \(windowType) - \(window.frame)")
                continue
            }
        }
        
        print("❌ [PiP] 没有找到合适的画中画窗口")
        print("💡 [PiP] 提示：真正的画中画窗口可能还未创建，或者需要等待更多窗口事件")
        
        return nil
    }
    
    private func setupTextOverlay() {
        guard let pipWindow = pipWindow else { return }
        
        print("📺 [PiP] 设置文字覆盖层...")
        
        pipTextView = PictureInPictureTextView()
        pipTextView?.translatesAutoresizingMaskIntoConstraints = false
        pipTextView?.updateText(recognizedText)
        
        pipWindow.addSubview(pipTextView!)
        
        NSLayoutConstraint.activate([
            pipTextView!.leadingAnchor.constraint(equalTo: pipWindow.leadingAnchor),
            pipTextView!.trailingAnchor.constraint(equalTo: pipWindow.trailingAnchor),
            pipTextView!.topAnchor.constraint(equalTo: pipWindow.topAnchor),
            pipTextView!.bottomAnchor.constraint(equalTo: pipWindow.bottomAnchor)
        ])
        
        print("✅ [PiP] 文字覆盖层设置完成")
    }
    
    private func updateCanStartPip() {
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        let controllerExists = pipController != nil
        let notActive = !isPipActive
        
        canStartPip = supported && controllerExists && notActive
        
        print("🔄 [PiP] 更新canStartPip状态:")
        print("   - 设备支持: \(supported)")
        print("   - 控制器存在: \(controllerExists)")
        print("   - 未激活: \(notActive)")
        print("   - 最终状态: \(canStartPip)")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: @preconcurrency AVPictureInPictureControllerDelegate {
    
    nonisolated public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("📺 [PiP] 委托: 即将启动画中画")
        Task { @MainActor in
            isPipActive = true
            updateCanStartPip()
        }
    }
    
    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ [PiP] 委托: 画中画已启动")
        Task { @MainActor in
            // 如果还没有找到窗口，尝试过滤
            if pipWindow == nil {
                print("🔍 [PiP] pipWindow为空，开始寻找目标窗口...")
                pipWindow = filterTargetWindow()
                
                if let foundWindow = pipWindow {
                    print("✅ [PiP] 找到目标窗口，开始设置文字覆盖层")
                    setupTextOverlay()
                    suspectedWindows.removeAll()
                } else {
                    print("❌ [PiP] 未找到目标窗口，启动延迟重试机制...")
                    // 延迟重试，真正的画中画窗口可能稍后创建
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        print("🔄 [PiP] 延迟重试寻找画中画窗口...")
                        if self.pipWindow == nil && self.isPipActive {
                            self.pipWindow = self.filterTargetWindow()
                            if let retryFoundWindow = self.pipWindow {
                                print("✅ [PiP] 延迟重试成功找到窗口")
                                self.setupTextOverlay()
                                self.suspectedWindows.removeAll()
                            } else {
                                print("❌ [PiP] 延迟重试仍未找到窗口")
                            }
                        }
                    }
                }
            } else {
                print("✅ [PiP] pipWindow已存在，直接使用")
            }
        }
    }
    
    nonisolated public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("📺 [PiP] 委托: 即将停止画中画")
        Task { @MainActor in
            isPipActive = false
            updateCanStartPip()
        }
    }
    
    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🛑 [PiP] 委托: 画中画已停止")
        Task { @MainActor in
            print("🧹 [PiP] 清理资源...")
            print("   - 移除pipTextView: \(pipTextView != nil ? "是" : "否")")
            print("   - 清空pipWindow: \(pipWindow != nil ? "是" : "否")")
            print("   - 保留疑似窗口列表，当前数量: \(suspectedWindows.count)")
            
            pipTextView?.removeFromSuperview()
            pipTextView = nil
            pipWindow = nil
            
            // 🔑 关键修复：不清空疑似窗口列表！
            // suspectedWindows.removeAll() // 注释掉这行
            // 保留疑似窗口，下次启动时可能还能用到
            
            // 注意：不需要在这里重新设置通知监听
            // 会在下次 startPictureInPicture() 调用时按需设置
            
            print("✅ [PiP] 资源清理完成")
        }
    }
    
    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("❌ [PiP] 委托: 画中画启动失败 - \(error.localizedDescription)")
        Task { @MainActor in
            errorMessage = "画中画启动失败: \(error.localizedDescription)"
            updateCanStartPip()
        }
    }
}