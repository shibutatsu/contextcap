import AppKit
import ScreenCaptureKit
import ServiceManagement
import CaptureCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, SCContentSharingPickerObserver {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var archive: Archive?
    private var gate = RecordingGate()
    private var filter: SCContentFilter?
    private var task: Task<Void, Never>?
    private var captureTimer: Timer?
    private var expiryTimer: Timer?
    private var timeout: Timer?
    private var selecting = false
    private let status = NSTextField(labelWithString: "停止中")
    private let target = NSTextField(labelWithString: "ウィンドウ未選択")
    private let summary = NSTextField(labelWithString: "記録0件")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let timestamp = NSTextField(labelWithString: "記録なし")
    private let preview = NSImageView()
    private let ocr = NSTextView()
    private var choose: NSButton!
    private var toggle: NSButton!
    private var deleteButton: NSButton!
    private var folder: NSButton!
    private var login: NSButton!
    private let retention = NSPopUpButton()
    private var picker: SCContentSharingPicker { .shared }
    private var days: Int {
        let v = UserDefaults.standard.integer(forKey: "RetentionDays")
        return [1, 3, 7].contains(v) ? v : 3
    }
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ContextCap Private", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        makeMenu()
        do {
            archive = try Archive(root: root)
            try archive?.prune(retentionDays: days)
        } catch { showError(error) }
        picker.add(self)
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            nc.addObserver(self, selector: #selector(lockStop), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockStop), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        refresh()
        showWindow()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { stop(); picker.remove(self); picker.isActive = false }
    @objc private func lockStop() { stop(); filter = nil; target.stringValue = "ウィンドウ未選択"; refresh() }

    private func makeMenu() {
        let main = NSMenu()
        let item = NSMenuItem(); main.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "ContextCap Private を終了", action: #selector(quit), keyEquivalent: "q").target = self
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "編集"); editItem.submenu = edit
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "開く", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "停止", action: #selector(stopAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "").target = self
        statusItem.menu = menu
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded; b.font = .systemFont(ofSize: 16)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.setAccessibilityIdentifier(title)
        return b
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views); r.orientation = .horizontal; r.spacing = 12; r.alignment = .centerY
        return r
    }
    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ContextCap Private"; window.minSize = NSSize(width: 640, height: 760)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white; window.isReleasedWhenClosed = false
        window.center()
        let content = window.contentView!
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)])
        for label in [status, target, summary, errorLabel, timestamp] { label.font = .systemFont(ofSize: 16); label.textColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1) }
        status.font = .boldSystemFont(ofSize: 24)
        target.lineBreakMode = .byTruncatingMiddle
        errorLabel.textColor = NSColor(srgbRed: 0.65, green: 0.08, blue: 0.08, alpha: 1)
        errorLabel.setAccessibilityIdentifier("状態エラー")
        choose = button("ウィンドウを選択", #selector(selectWindow))
        toggle = button("記録開始", #selector(toggleRecording))
        toggle.keyEquivalent = "\r"
        let controls = row([choose, toggle])
        retention.addItems(withTitles: ["1日", "3日", "7日"])
        retention.selectItem(at: [1,3,7].firstIndex(of: days) ?? 1)
        retention.target = self; retention.action = #selector(changeRetention)
        retention.font = .systemFont(ofSize: 16)
        retention.setAccessibilityLabel("保持期間")
        retention.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        login = NSButton(checkboxWithTitle: "ログイン時に起動", target: self, action: #selector(changeLogin))
        login.font = .systemFont(ofSize: 16); login.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let retentionLabel = NSTextField(labelWithString: "画像・文字の保持"); retentionLabel.font = .systemFont(ofSize: 16)
        let settings = row([retentionLabel, retention, login])
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).cgColor
        preview.setAccessibilityLabel("最新の記録画像")
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder
        ocr.isEditable = false; ocr.isSelectable = true; ocr.font = .systemFont(ofSize: 16)
        ocr.textColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        ocr.backgroundColor = .white; ocr.textContainerInset = NSSize(width: 8, height: 8)
        ocr.autoresizingMask = [.width]; ocr.isVerticallyResizable = true; ocr.isHorizontallyResizable = false
        ocr.textContainer?.widthTracksTextView = true
        ocr.setAccessibilityLabel("認識した文字")
        scroll.documentView = ocr; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        folder = button("保存先", #selector(openFolder)); deleteButton = button("すべて削除", #selector(deleteAll))
        let footer = row([folder, deleteButton])
        for v in [status, target, controls, settings, summary, errorLabel, timestamp, preview, scroll, footer] { stack.addArrangedSubview(v) }
        for v in [target, summary, errorLabel, preview, scroll] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.initialFirstResponder = choose
    }
    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openFolder() { NSWorkspace.shared.open(root) }
    private func showError(_ error: Error) { errorLabel.stringValue = error.localizedDescription }
    private func refresh() {
        status.stringValue = gate.isRecording ? (task == nil ? "記録中" : "記録中 · 文字認識中") : "停止中"
        statusItem?.button?.title = gate.isRecording ? "● 記録中" : "○ 停止中"
        toggle.title = gate.isRecording ? "一時停止" : "記録開始"
        toggle.isEnabled = archive != nil && filter != nil && !selecting
        choose.isEnabled = true
        choose.title = selecting ? "選択をキャンセル" : "ウィンドウを選択"
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        do {
            let count = try archive?.count() ?? 0
            summary.stringValue = "記録\(count)件 · \(ByteCountFormatter.string(fromByteCount: try archive?.payloadBytes() ?? 0, countStyle: .file))"
            deleteButton.isEnabled = archive != nil // zero-data clear is safe and keyboard-accessible
            if let record = try archive?.latest() {
                preview.image = NSImage(data: record.image)
                ocr.string = record.text.isEmpty ? "文字0件" : record.text
                timestamp.stringValue = record.timestamp.formatted(date: .abbreviated, time: .standard)
            } else {
                preview.image = nil; ocr.string = "文字0件"; timestamp.stringValue = "記録なし"
            }
        } catch { showError(error) }
    }
    @objc private func selectWindow() {
        if selecting {
            picker.isActive = false; selecting = false; filter = nil
            target.stringValue = "ウィンドウ未選択"; refresh(); return
        }
        stop(); filter = nil; selecting = true; target.stringValue = "選択中"; errorLabel.stringValue = ""
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        config.allowsChangingSelectedContent = false
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "app.shibutatsu.contextcap.private"]
        picker.defaultConfiguration = config; picker.isActive = true
        refresh(); picker.present(using: .window)
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.stop(); self.filter = nil; self.selecting = false; self.target.stringValue = "ウィンドウ未選択"; self.refresh(); self.window.makeFirstResponder(self.choose) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard self.selecting else { return }
            self.stop(); self.selecting = false
            guard filter.style == .window else { self.filter = nil; self.target.stringValue = "ウィンドウ未選択"; self.errorLabel.stringValue = "ウィンドウを1つ選択してください"; self.refresh(); return }
            self.filter = filter
            if #available(macOS 15.2, *), let w = filter.includedWindows.first {
                self.target.stringValue = "\(w.owningApplication?.applicationName ?? "ウィンドウ") · \(w.title ?? "選択済み")"
            } else { self.target.stringValue = "ウィンドウ選択済み" }
            self.refresh(); self.showWindow(); self.window.makeFirstResponder(self.toggle)
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.selecting = false; self.filter = nil; self.target.stringValue = "ウィンドウ未選択"; self.showError(error); self.refresh() }
    }
    @objc private func toggleRecording() {
        if gate.isRecording { stop(); return }
        guard filter != nil, archive != nil, !selecting else { return }
        errorLabel.stringValue = ""; gate.start()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        tick(); refresh()
    }
    @objc private func stopAction() { stop() }
    private func stop() {
        gate.stop(); captureTimer?.invalidate(); captureTimer = nil
        timeout?.invalidate(); timeout = nil
        task?.cancel(); task = nil
        if window != nil { refresh() }
    }
    private func tick() {
        guard gate.isRecording, task == nil, let filter else { return }
        let token = gate.token
        let date = Date()
        let config = SCStreamConfiguration()
        config.width = max(1, min(8192, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))))
        config.height = max(1, min(8192, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.gate.accepts(token) else { return }
                self.stop(); self.errorLabel.stringValue = "記録がタイムアウトしました。再試行してください"
            }
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard self.gate.accepts(token), !Task.isCancelled else { return }
                let result = try await Task.detached(priority: .userInitiated) { try ImageRecognizer.recognize(image) }.value
                guard self.gate.accepts(token), !Task.isCancelled else { return }
                try self.archive?.save(image: result.0, text: result.1, at: date, retentionDays: self.days)
                self.timeout?.invalidate(); self.timeout = nil; self.task = nil; self.refresh()
            } catch {
                guard self.gate.accepts(token) else { return }
                self.stop(); self.showError(error)
            }
        }
        refresh()
    }
    @objc private func changeRetention() {
        let newDays = [1,3,7][retention.indexOfSelectedItem]
        if newDays < days {
            let a = NSAlert(); a.messageText = "保持期間を\(newDays)日に変更しますか？"; a.informativeText = "期限を過ぎた画像と文字を削除します。"
            a.addButton(withTitle: "変更して削除"); a.addButton(withTitle: "キャンセル")
            guard a.runModal() == .alertFirstButtonReturn else { retention.selectItem(at: [1,3,7].firstIndex(of: days)!); return }
        }
        do { try archive?.prune(retentionDays: newDays); UserDefaults.standard.set(newDays, forKey: "RetentionDays"); errorLabel.stringValue = ""; refresh() }
        catch { retention.selectItem(at: [1,3,7].firstIndex(of: days)!); stop(); showError(error) }
    }
    private func expire() {
        do { try archive?.prune(retentionDays: days); refresh() }
        catch { stop(); showError(error) }
    }
    @objc private func deleteAll() {
        stop() // pause also on cancellation, so the confirmation does not collect more data
        let a = NSAlert(); a.messageText = "すべての記録を削除しますか？"
        a.informativeText = "画像と認識した文字を削除します。元に戻せません。"
        a.addButton(withTitle: "削除"); a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { window.makeFirstResponder(deleteButton); return }
        do { try archive?.deleteAll(); errorLabel.stringValue = "削除しました"; refresh() }
        catch { showError(error) }
        window.makeFirstResponder(deleteButton)
    }
    @objc private func changeLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { errorLabel.stringValue = "ログイン項目の承認待ち" }
            else { errorLabel.stringValue = "" }
        } catch { showError(error) }
        refresh()
    }
}
