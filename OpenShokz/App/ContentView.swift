import AppKit
import PostHog
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var volume = ShokzVolumeMonitor()
    @State private var download = DownloadService()
    @State private var library = LibraryViewModel()
    @State private var hasSeenConnection = false

    @State private var isAdding = false
    @State private var addFieldShown = false
    @State private var urlField = ""
    @State private var hoveredTrackID: DeviceTrack.ID?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if volume.isConnected && !volume.needsAccessGrant {
                VStack(alignment: .trailing, spacing: 8) {
                    // A failed download must stay visible — the progress row
                    // disappears with the job, which used to fail silently.
                    if let error = download.lastError, !download.isBusy {
                        Button {
                            download.clearURLDraft()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background {
                                // Native glass with a red error wash + hairline.
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.regularMaterial)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.red.opacity(0.12))
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(Color.red.opacity(0.28), lineWidth: 0.8)
                                    }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .focusEffectDisabled()
                        .accessibilityIdentifier(AccessibilityID.downloadError)
                        .transition(.opacity)
                    }
                    addChrome
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, LayoutMetrics.edge)
                .padding(.bottom, LayoutMetrics.edge)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            // Soft fade only — no solid glass “browser bar”. Scrolled rows
            // blur out under the traffic lights into the window glass.
            TitlebarScrollFade()
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            // Sit in the real titlebar row (fullSizeContentView still reports a
            // top safe-area inset). Ignore that inset, then pad to optically
            // center with the traffic lights.
            statusView
                .padding(.top, 12)
                .padding(.trailing, LayoutMetrics.edge)
                .ignoresSafeArea(edges: .top)
        }
        .foregroundStyle(.primary)
        .tint(.primary)
        .background { GlassWindowBackground() }
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .onExitCommand {
            if isAdding { dismissAddBar() }
        }
        .onKeyPress(.escape) {
            guard isAdding else { return .ignored }
            dismissAddBar()
            return .handled
        }
        .task {
            library.configure(modelContext: modelContext)
            UITestingSupport.seedCacheStatesIfNeeded(into: modelContext)
            volume.start()
            if volume.isConnected {
                await refreshLibrary()
            }
        }
        .task(id: volume.isConnected) {
            guard volume.isConnected else { return }
            await refreshLibrary()
            // The app is effectively the sole writer to this volume, so it never
            // re-lists on a timer. A cheap change token (root mtime + free space,
            // captured off-main) detects external edits; only a changed token —
            // or an explicit add/delete/retry — triggers another listing.
            var baseline = await VolumeChangeToken.capture(root: volume.rootURL)
            while !Task.isCancelled && volume.isConnected {
                try? await Task.sleep(for: ConnectionLifecycle.changeSignalInterval)
                guard !Task.isCancelled, volume.isConnected else { return }
                // Don't compete with an in-flight copy — POSIX/Finder I/O on the
                // same FSKit volume can stall each other for a long time.
                if download.isBusy { continue }
                let current = await VolumeChangeToken.capture(root: volume.rootURL)
                if VolumeChangeToken.changed(previous: baseline, current: current) {
                    baseline = current
                    await refreshLibrary()
                } else if baseline == nil {
                    baseline = current
                }
            }
        }
        .onChange(of: volume.isConnected) { wasConnected, connected in
            if connected {
                hasSeenConnection = true
                PostHogSDK.shared.capture("device_connected", properties: [
                    "volume_name": volume.volumeName ?? "unknown",
                ])
                Task { await refreshLibrary() }
            } else {
                library.clear()
                dismissAddBar()
                if UITestingSupport.isEnabled { return }
                if hasSeenConnection || wasConnected {
                    Task { @MainActor in
                        try? await Task.sleep(for: ConnectionLifecycle.disconnectQuitDelay)
                        guard ConnectionLifecycle.shouldConfirmQuit(
                            stillDisconnected: !volume.isConnected
                        ) else { return }
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        .onChange(of: volume.contentGeneration) { _, _ in
            // Files changed directly on the volume (e.g. deleted in Finder).
            guard volume.isConnected, !download.isBusy else { return }
            Task { await refreshLibrary() }
        }
        .onChange(of: download.job?.phase) { _, phase in
            if case .completed = phase {
                // The transfer just told us exactly which files landed —
                // insert them directly instead of re-walking the USB volume.
                library.recordTransfer(
                    volume: volume,
                    relativePaths: download.lastTransferredRelativePaths,
                    localURLs: download.lastTransferredLocalURLs,
                    info: download.preview,
                    mediaID: download.lastTransferredMediaID
                )
            }
        }
        .onDisappear { volume.stop() }
    }

    private var statusView: some View {
        // Read both connection flags so @Observable invalidates chrome immediately.
        let connected = volume.isConnected
        let name = volume.volumeName
        return HStack(spacing: 7) {
            Text(ConnectionStatusPresentation.label(isConnected: connected, volumeName: name))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.statusLabel)
            StatusDot(isConnected: connected)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.statusRoot)
        .accessibilityLabel(ConnectionStatusPresentation.label(isConnected: connected, volumeName: name))
    }

    /// Bottom chrome: closed = + circle; open = field + send (Esc closes; no ×).
    private var addChrome: some View {
        HStack(spacing: 8) {
            if isAdding {
                Group {
                    TextField("Paste a video or podcast link", text: $urlField)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .autocorrectionDisabled(true)
                        .focused($fieldFocused)
                        .accessibilityIdentifier(AccessibilityID.addURLField)
                        .background(URLFieldAutocompleteDisabled())
                        .onSubmit(submit)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                    .disabled(!AddURLControls.isSendEnabled(
                        urlText: urlField,
                        isConnected: volume.isConnected
                    ))
                    .opacity(
                        AddURLControls.isSendEnabled(
                            urlText: urlField,
                            isConnected: volume.isConnected
                        ) ? 1 : 0.35
                    )
                    .accessibilityIdentifier(AccessibilityID.sendButton)
                }
                .opacity(addFieldShown ? 1 : 0)
                .animation(.easeOut(duration: 0.07), value: addFieldShown)
            } else {
                Button(action: openAddBar) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .accessibilityIdentifier(AccessibilityID.addButton)
                .accessibilityLabel("Add")
            }
        }
        .padding(.horizontal, isAdding ? LayoutMetrics.chromeInset : 0)
        .frame(minHeight: 36)
        .frame(maxWidth: isAdding ? .infinity : 36, alignment: .trailing)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        }
        .animation(.snappy(duration: 0.24), value: isAdding)
        .task(id: urlField) {
            guard isAdding else { return }
            let trimmed = urlField.trimmingCharacters(in: .whitespacesAndNewlines)
            guard MediaURLResolver.normalize(trimmed) != nil && trimmed.contains(".") else { return }
            download.setURLText(trimmed)
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await download.loadPreview()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !volume.isConnected {
            ConnectGuide()
                .accessibilityIdentifier(AccessibilityID.connectGuide)
        } else if volume.needsAccessGrant {
            GrantAccessGuide(volumeName: volume.volumeName ?? "your Shokz") {
                Task {
                    if await volume.requestAccessGrant() {
                        PostHogSDK.shared.capture("device_access_granted", properties: [
                            "volume_name": volume.volumeName ?? "unknown",
                        ])
                        await refreshLibrary(force: true)
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.grantAccess)
        } else if !library.visibleTracks.isEmpty || download.isBusy {
            videoList
        } else if LibraryDisplayPolicy.showsReadProblem(
            trackCount: library.visibleTracks.count,
            isScanning: library.isScanning,
            lastError: library.lastError,
            usedBytes: volume.usedBytes
        ) {
            LibraryReadProblem(
                message: library.lastError
                    ?? "Headphones have data but files couldn’t be listed. Unplug/replug, then retry.",
                isScanning: library.isScanning,
                onRetry: { Task { await refreshLibrary(force: true) } }
            )
            .accessibilityIdentifier(AccessibilityID.libraryReadProblem)
        } else if LibraryDisplayPolicy.showsEmptyLibrary(
            trackCount: library.visibleTracks.count,
            isScanning: library.isScanning,
            lastError: library.lastError,
            usedBytes: volume.usedBytes,
            isDownloadBusy: download.isBusy
        ) {
            EmptyLibrary { openAddBar() }
                .accessibilityIdentifier(AccessibilityID.emptyState)
        } else {
            // Scanning with no rows yet — never block chrome with a full-window spinner.
            VStack(spacing: 8) {
                Text("Reading headphones…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.mini)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.libraryScanning)
        }
    }

    private var videoList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if download.isBusy {
                    DownloadRow(download: download)
                        .padding(.horizontal, LayoutMetrics.edge)
                        .padding(.vertical, 2)
                }
                ForEach(library.visibleTracks) { track in
                    Button {
                        _ = library.openOriginal(track)
                    } label: {
                        VideoRow(
                            title: library.displayTitle(for: track),
                            duration: library.displayDuration(for: track),
                            artwork: library.displayArtwork(for: track),
                            isHovered: hoveredTrackID == track.id
                        )
                        .padding(.horizontal, LayoutMetrics.edge)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowClickStyle(isHovered: hoveredTrackID == track.id))
                    .focusable(false)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            hoveredTrackID = track.id
                        } else if hoveredTrackID == track.id {
                            hoveredTrackID = nil
                        }
                    }
                    .contextMenu {
                        Button("Open Original") {
                            _ = library.openOriginal(track)
                        }
                        Button("Reveal in Finder") { library.revealInFinder(track) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            library.selection = [track.id]
                            hoveredTrackID = nil
                            library.deleteSelected(volume: volume)
                        }
                        .accessibilityIdentifier(AccessibilityID.videoRowDelete)
                    }
                    .accessibilityIdentifier(AccessibilityID.videoRow)
                    .accessibilityLabel(library.displayTitle(for: track))
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 52)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier(AccessibilityID.videoList)
    }

    /// Fresh session only: empty field, then optional one-shot clipboard paste.
    /// Never restores a previous draft — Esc/exit always clears.
    private func openAddBar() {
        PostHogSDK.shared.capture("add_url_opened")
        urlField = ""
        download.clearURLDraft()
        addFieldShown = false
        withAnimation(.snappy(duration: 0.24)) {
            isAdding = true
        }
        withAnimation(.easeOut(duration: 0.14).delay(0.04)) {
            addFieldShown = true
        }
        if let clip = NSPasteboard.general.string(forType: .string),
           clip.contains("http") {
            urlField = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            fieldFocused = true
        }
    }

    private func dismissAddBar() {
        urlField = ""
        fieldFocused = false
        addFieldShown = false
        download.clearURLDraft()
        withAnimation(.snappy(duration: 0.22)) {
            isAdding = false
        }
    }

    private func submit() {
        let trimmed = urlField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, volume.isConnected else { return }
        PostHogSDK.shared.capture("url_submitted", properties: [
            "has_preview": download.preview != nil,
        ])
        download.setURLText(trimmed)
        download.download(
            sendToDevice: true,
            volumeRoot: volume.rootURL,
            existingVideoIDs: library.existingVideoIDs
        )
        urlField = ""
        fieldFocused = false
        addFieldShown = false
        download.clearURLDraft()
        withAnimation(.snappy(duration: 0.22)) { isAdding = false }
    }

    private func refreshLibrary(force: Bool = false) async {
        await library.refresh(volume: volume, force: force)
        library.annotateMediaID(
            relativePaths: download.lastTransferredRelativePaths,
            mediaID: download.lastTransferredMediaID
        )
    }
}

// MARK: - Chrome

/// Turns off AppKit text completion so prior URLs are not suggested/restored into the field.
/// Runs once — re-touching NSTextField on every Observable update resets caret/scroll (URL flash).
private struct URLFieldAutocompleteDisabled: NSViewRepresentable {
    final class Coordinator {
        var didDisable = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.disable(in: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.didDisable else { return }
        DispatchQueue.main.async { Self.disable(in: nsView, coordinator: context.coordinator) }
    }

    private static func disable(in anchor: NSView, coordinator: Coordinator) {
        guard !coordinator.didDisable else { return }
        var current: NSView? = anchor.superview
        while let view = current {
            if let field = view as? NSTextField {
                apply(to: field)
                coordinator.didDisable = true
                return
            }
            for sub in view.subviews where sub is NSTextField {
                if let field = sub as? NSTextField {
                    apply(to: field)
                    coordinator.didDisable = true
                    return
                }
            }
            current = view.superview
        }
    }

    private static func apply(to field: NSTextField) {
        field.isAutomaticTextCompletionEnabled = false
        field.refusesFirstResponder = false
        field.isEditable = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
    }
}

private struct StatusDot: View {
    let isConnected: Bool

    var body: some View {
        Circle()
            .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            }
            .shadow(color: isConnected ? Color.green.opacity(0.5) : .clear, radius: 4)
            .help(isConnected ? "Shokz connected" : "No Shokz device")
    }
}

/// Soft top fade so list rows scrolling under the traffic lights blur away,
/// without drawing a solid glass toolbar strip.
private struct TitlebarScrollFade: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.55),
                Color.black.opacity(0.22),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 36)
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Rows

private struct DownloadRow: View {
    @Bindable var download: DownloadService

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Thumbnail(url: download.preview?.thumbnailURL, systemFallback: "play.rectangle")
                .frame(width: 44, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                ScrollingTitle(
                    title: download.preview?.title ?? "Downloading…",
                    weight: .medium,
                    isSecondary: false,
                    isHovered: false
                )
                VStack(alignment: .leading, spacing: 3) {
                    // Start/metadata and tail phases show an animated indeterminate
                    // bar (the "empty" bar sweeping) until real byte progress
                    // arrives and drives the determinate fill.
                    if showsIndeterminateProgress {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .tint(.secondary)
                    } else if let progress = download.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .tint(.secondary)
                    }
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if let duration = download.preview?.duration {
                Text(VideoDuration.format(duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
    }

    private var showsIndeterminateProgress: Bool {
        guard let phase = download.job?.phase else { return true }
        switch phase {
        case .queued, .fetchingMetadata, .processing, .transferring:
            return true
        case .downloading(let progress):
            return progress >= 0.99
        case .completed, .failed, .cancelled:
            return false
        }
    }

    private var statusLabel: String {
        if let message = download.statusMessage, !message.isEmpty {
            return message
        }
        guard let phase = download.job?.phase else { return "Working…" }
        switch phase {
        case .queued, .fetchingMetadata: return "Fetching video info…"
        case .downloading(let progress) where progress >= 0.99: return "Converting audio…"
        case .downloading: return "Downloading…"
        case .processing: return "Adding cover art…"
        case .transferring: return "Copying to headphones…"
        case .completed: return "Done"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

private struct VideoRow: View {
    let title: String
    let duration: TimeInterval?
    let artwork: NSImage?
    var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Thumbnail(nsImage: artwork, systemFallback: "play.rectangle.fill")
                .frame(width: 44, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            ScrollingTitle(
                title: title,
                weight: .medium,
                isSecondary: false,
                isHovered: isHovered
            )

            Text(duration.map(VideoDuration.format) ?? "–:––")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 36, alignment: .trailing)
        }
    }
}

enum VideoDuration {
    static func format(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Single-line title that clips (no ellipsis) and marquee-loops from the start while hovered.
private struct ScrollingTitle: View {
    let title: String
    var weight: Font.Weight = .medium
    var isSecondary: Bool = false
    var isHovered: Bool = false

    @State private var textWidth: CGFloat = 0
    /// Wall-clock anchor when hover began — scroll always starts at offset 0.
    @State private var loopAnchor: Date?

    /// Gap between the end of one copy and the start of the next.
    private let loopGap: CGFloat = 40
    /// Points scrolled per second while looping.
    private let pointsPerSecond: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let overflow = max(0, textWidth - geo.size.width)
            let shouldLoop = isHovered && overflow > 0

            TimelineView(
                .animation(
                    minimumInterval: 1 / 30,
                    paused: !shouldLoop
                )
            ) { context in
                let offset = ScrollingTitleLogic.scrollOffset(
                    isHovered: isHovered,
                    textWidth: textWidth,
                    containerWidth: geo.size.width,
                    loopGap: loopGap,
                    pointsPerSecond: pointsPerSecond,
                    anchor: loopAnchor,
                    now: context.date
                )

                HStack(spacing: loopGap) {
                    titleLabel
                    if shouldLoop {
                        titleLabel
                    }
                }
                .offset(x: offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 20, idealHeight: 20, maxHeight: 20, alignment: .leading)
        .onChange(of: isHovered) { _, hovering in
            loopAnchor = hovering ? Date() : nil
        }
        .help(title)
    }

    private var titleLabel: some View {
        Text(title)
            .font(.callout.weight(weight))
            .foregroundStyle(isSecondary ? .secondary : .primary)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { textGeo in
                    Color.clear.onAppear {
                        textWidth = textGeo.size.width
                    }
                    .onChange(of: textGeo.size.width) { _, width in
                        textWidth = width
                    }
                }
            )
    }
}

private struct Thumbnail: View {
    var url: URL?
    var nsImage: NSImage?
    var systemFallback: String

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
    }

    private var fallback: some View {
        ZStack {
            Color.primary.opacity(0.10)
            Image(systemName: systemFallback)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Empty / Connect

private struct ConnectGuide: View {
    private static let learnMoreURL = URL(
        string: "https://help.shokz.com/s/article/How-to-transfer-upload-MP3-to-Shokz-Swimming-Headphones"
    )!

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                deviceIcon("headphones")
                Image(systemName: "chevron.compact.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                deviceIcon("cable.connector")
                Image(systemName: "chevron.compact.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                deviceIcon("laptopcomputer")
            }

            VStack(spacing: 3) {
                Text("Connect to get started")
                    .font(.callout.weight(.semibold))
                Text("Plug in your Shokz to load videos and podcasts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.connectGuideSubtitle)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Attach the magnetic charging cable")
                step(2, "Plug the USB end into your Mac")
                step(3, "Wait for the disk to appear (e.g. OpenSwim, SWIM PRO)")
            }

            Link("Learn more", destination: Self.learnMoreURL)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .center)
                // Don't let the window's initial key focus land here — the link
                // rendered with a focus highlight on every launch.
                .focusable(false)
                .focusEffectDisabled()
                .accessibilityIdentifier(AccessibilityID.connectGuideLearnMore)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func deviceIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 42, height: 42)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
            }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.10))
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 17, height: 17)

            Text(text)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Sandbox one-time volume grant: shown between connect and first listing.
private struct GrantAccessGuide: View {
    let volumeName: String
    var onGrant: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.person.crop")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Allow access to \(volumeName)")
                .font(.callout.weight(.medium))
            Text("macOS asks once per device. Click below, then choose Grant Access.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onGrant) {
                Text("Grant Access…")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            .accessibilityIdentifier(AccessibilityID.grantAccessButton)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct LibraryReadProblem: View {
    let message: String
    let isScanning: Bool
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Can’t read library")
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Text(isScanning ? "Retrying…" : "Retry")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
            .focusable(false)
            .focusEffectDisabled()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct EmptyLibrary: View {
    var onAdd: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No videos yet")
                .font(.callout.weight(.medium))
                .accessibilityLabel("No videos")
            Button(action: onAdd) {
                Text("Tap + to add a video or podcast")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: LayoutMetrics.emptyStateNudge)
        .padding(24)
        .accessibilityElement(children: .contain)
    }
}

/// Press feedback without List selection highlight.
private struct RowClickStyle: ButtonStyle {
    var isHovered: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(
                        configuration.isPressed ? 0.12 : (isHovered ? 0.07 : 0)
                    ))
                    .padding(.horizontal, 2)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

private extension View {
    func plainRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 2,
                leading: LayoutMetrics.edge,
                bottom: 2,
                trailing: LayoutMetrics.edge
            ))
    }
}

#Preview {
    ContentView()
        .modelContainer(for: TrackState.self, inMemory: true)
        .frame(minWidth: 280, minHeight: 320)
        .frame(width: 360, height: 480)
}
