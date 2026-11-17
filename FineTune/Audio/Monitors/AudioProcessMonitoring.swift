import AudioToolbox

@MainActor
protocol AudioProcessMonitoring: AnyObject {
    var activeApps: [AudioApp] { get }
    var onAppsChanged: (([AudioApp]) -> Void)? { get set }
    /// Every CoreAudio process object that currently exists, playing or not. Lets the
    /// engine keep an idle app's tap until the process actually exits. `nil` = unknown.
    var liveProcessObjectIDs: Set<AudioObjectID>? { get }

    func start()
    func stop()
}

extension AudioProcessMonitoring {
    var liveProcessObjectIDs: Set<AudioObjectID>? { nil }
}
