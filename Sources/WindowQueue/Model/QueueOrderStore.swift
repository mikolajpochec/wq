import Combine
import Foundation

/// Remembers the queue's order between runs.
///
/// Window ids only exist for the lifetime of a login session, so what is saved is a list of
/// `ManagedWindow.orderKey` values — application plus title. Restoring is best-effort by design: it
/// happens once, as soon as the first windows are discovered, and anything that fails to match is
/// simply left in discovery order.
final class QueueOrderStore {
    private static let defaultsKey = "queueOrder.v1"
    private static let saveDelay: TimeInterval = 2

    private var cancellable: AnyCancellable?
    private var hasRestored = false

    /// Reorders the queue to match the last saved arrangement, once.
    func restore(into model: WindowQueueModel) {
        guard !hasRestored, !model.windows.isEmpty else { return }
        hasRestored = true

        guard let saved = UserDefaults.standard.stringArray(forKey: Self.defaultsKey),
              !saved.isEmpty
        else { return }
        model.applyOrder(keys: saved)
    }

    /// Starts recording the order, well after the churn of a window being opened or closed.
    func startSaving(_ model: WindowQueueModel) {
        cancellable = model.$windows
            // An empty queue is a transient state — during launch, or while the last window closes
            // — and saving it would throw away a perfectly good arrangement.
            .filter { !$0.isEmpty }
            .debounce(for: .seconds(Self.saveDelay), scheduler: RunLoop.main)
            .sink { windows in
                UserDefaults.standard.set(windows.map(\.orderKey), forKey: Self.defaultsKey)
            }
    }
}
