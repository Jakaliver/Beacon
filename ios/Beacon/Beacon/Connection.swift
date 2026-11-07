import Foundation

/// One auto-reconnecting WebSocket. Callbacks arrive on the main queue; `send` is safe from any thread.
final class Connection: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onText: ((String) -> Void)?

    private let path: String
    private var urlSession: URLSession!
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var connected = false
    private var host = ""
    private var backoff = 0.5
    private var pingTimer: Timer?

    init(path: String) {
        self.path = path
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    var isConnected: Bool { lock.withLock { connected } }

    func connect(host: String) {
        if host == self.host, lock.withLock({ task != nil }) { return }
        self.host = host
        backoff = 0.5
        open()
    }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let task = lock.withLock({ connected ? task : nil }) else { return completion(false) }
        task.send(message) { completion($0 == nil) }
    }

    func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        send(.string(text))
    }

    private func open() {
        let (old, wasConnected) = lock.withLock { () -> (URLSessionWebSocketTask?, Bool) in
            defer { task = nil; connected = false }
            return (task, connected)
        }
        old?.cancel(with: .goingAway, reason: nil)
        pingTimer?.invalidate()
        if wasConnected { onClose?() }
        guard let url = URL(string: "ws://\(host):8787\(path)") else { return scheduleReconnect() }
        let newTask = urlSession.webSocketTask(with: url)
        lock.withLock { task = newTask }
        newTask.resume()
        receive(on: newTask)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(task) else { return }
                switch result {
                case .success(.string(let text)):
                    self.onText?(text)
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.drop(task)
                }
            }
        }
    }

    private func isCurrent(_ t: URLSessionTask) -> Bool { lock.withLock { task === t } }

    private func drop(_ t: URLSessionTask) {
        guard isCurrent(t) else { return }
        let wasConnected = lock.withLock { () -> Bool in
            let was = connected
            connected = false
            task = nil
            return was
        }
        t.cancel()
        pingTimer?.invalidate()
        if wasConnected { onClose?() }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = backoff
        backoff = min(backoff * 2, 5)
        let hostAtSchedule = host
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.host == hostAtSchedule, self.lock.withLock({ self.task == nil }) else { return }
            self.open()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard isCurrent(webSocketTask) else { return }
        lock.withLock { connected = true }
        backoff = 0.5
        pingTimer?.invalidate()
        // Pings keep the idle timeout from closing a quiet control socket and detect dead Wi-Fi quickly.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self, weak webSocketTask] _ in
            webSocketTask?.sendPing { error in
                guard error != nil, let webSocketTask else { return }
                DispatchQueue.main.async { self?.drop(webSocketTask) }
            }
        }
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        drop(webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        drop(task)
    }
}
