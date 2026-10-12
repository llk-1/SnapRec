import ScreenCaptureKit

@MainActor
final class WindowPickerController {
    private var callbacks: PickerCallbacks?
    private var selection: ((SCContentFilter) -> Void)?
    private var cancellation: (() -> Void)?
    private var failure: ((String) -> Void)?
    private var generation: UUID?

    func begin(selection: @escaping (SCContentFilter) -> Void, cancellation: @escaping () -> Void,
               failure: @escaping (String) -> Void) {
        end()
        self.selection = selection
        self.cancellation = cancellation
        self.failure = failure
        let generation = UUID()
        self.generation = generation
        let callbacks = PickerCallbacks { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event, generation: generation) }
        }
        self.callbacks = callbacks
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "com.snaprec.SnapRec"]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(callbacks)
        picker.isActive = true
        picker.present(using: .window)
    }
    private func receive(_ event: PickerEvent, generation: UUID) {
        guard self.generation == generation else { return }
        switch event {
        case .selected(let selected):
            let callback = selection
            selection = nil
            cancellation = nil
            failure = nil
            // Keep the picker active for the stream's lifetime to preserve its grant.
            callback?(selected.filter)
        case .cancelled:
            let callback = cancellation
            end()
            callback?()
        case .failed(let message):
            let callback = failure
            end()
            callback?(message)
        }
    }
    func end() {
        let picker = SCContentSharingPicker.shared
        if let callbacks { picker.remove(callbacks) }
        callbacks = nil
        generation = nil
        picker.isActive = false
        selection = nil
        cancellation = nil
        failure = nil
    }
}

// The immutable native filter is handed once to MainActor. It is never mutated
// or read on the delegate queue after this transfer.
private struct PickerSelection: @unchecked Sendable { let filter: SCContentFilter }
private enum PickerEvent: Sendable { case selected(PickerSelection), cancelled, failed(String) }
private final class PickerCallbacks: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    let handler: @Sendable (PickerEvent) -> Void
    init(handler: @escaping @Sendable (PickerEvent) -> Void) { self.handler = handler }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) { handler(.cancelled) }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        handler(.selected(PickerSelection(filter: filter)))
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) { handler(.failed(error.localizedDescription)) }
}
