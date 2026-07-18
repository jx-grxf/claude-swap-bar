import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateService: NSObject {
    static let shared = UpdateService()

    enum Channel: String, CaseIterable, Identifiable {
        case stable
        case beta

        var id: Self { self }

        var displayName: String {
            switch self {
            case .stable: "Stable"
            case .beta: "Beta"
            }
        }
    }

    private let controller: SPUStandardUpdaterController
    private let updaterDelegate: UpdaterDelegate
    private let userDriverDelegate: UserDriverDelegate

    var channel: Channel {
        didSet {
            UserDefaults.standard.set(channel.rawValue, forKey: Keys.channel)
            availableUpdateVersion = nil
            updaterDelegate.channel = channel
            controller.updater.resetUpdateCycle()
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private(set) var availableUpdateVersion: String?
    private(set) var lastCheckDate: Date?

    var isUpdateAvailable: Bool { availableUpdateVersion != nil }

    private override init() {
        let storedChannel = UserDefaults.standard.string(forKey: Keys.channel)
            .flatMap(Channel.init(rawValue:)) ?? .stable
        let delegate = UpdaterDelegate(channel: storedChannel)
        let userDelegate = UserDriverDelegate()
        self.channel = storedChannel
        self.updaterDelegate = delegate
        self.userDriverDelegate = userDelegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: userDelegate
        )
        super.init()

        lastCheckDate = controller.updater.lastUpdateCheckDate
        delegate.onCheckCompleted = { [weak self] date in
            Task { @MainActor in self?.lastCheckDate = date }
        }
        delegate.onFoundUpdate = { [weak self] version in
            Task { @MainActor in self?.availableUpdateVersion = version }
        }
        userDelegate.onGentleUpdate = { [weak self] version in
            Task { @MainActor in self?.availableUpdateVersion = version }
        }
        delegate.onUserChoice = { [weak self] keepsReminder in
            Task { @MainActor in
                if !keepsReminder { self?.availableUpdateVersion = nil }
            }
        }
        delegate.onNoPendingUpdate = { [weak self] in
            Task { @MainActor in self?.availableUpdateVersion = nil }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private enum Keys {
        static let channel = "updates.channel"
    }
}

/// A scheduled check must not steal focus from whatever the user is doing.
/// CSwapBar surfaces the available update through its menu bar button; clicking
/// that button presents Sparkle's standard update window in focus.
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var onGentleUpdate: ((String) -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            onGentleUpdate?(update.displayVersionString)
        }
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var channel: UpdateService.Channel
    var onFoundUpdate: ((String) -> Void)?
    var onUserChoice: ((Bool) -> Void)?
    var onNoPendingUpdate: (() -> Void)?
    var onCheckCompleted: ((Date?) -> Void)?

    init(channel: UpdateService.Channel) {
        self.channel = channel
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        switch channel {
        case .stable: []
        case .beta: ["beta"]
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard channel == .beta else { return nil }
        let stableFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        return stableFeed?.replacingOccurrences(
            of: "releases/latest/download",
            with: "releases/download/beta"
        ) ?? "https://github.com/jx-grxf/claude-swap-bar/releases/download/beta/appcast.xml"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onFoundUpdate?(item.displayVersionString)
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        onUserChoice?(choice == .dismiss)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        onNoPendingUpdate?()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        onNoPendingUpdate?()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        onCheckCompleted?(updater.lastUpdateCheckDate)
    }
}
