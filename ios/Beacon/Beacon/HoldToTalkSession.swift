import Foundation

/// Keeps permission prompts and cancelled touches from starting a stale recording.
@MainActor
final class HoldToTalkSession {
    private let requestPermission: () async -> Bool
    private let startRecording: () -> Bool
    private let sendRecording: () -> Void
    private let discardRecording: () -> Void
    private let permissionDenied: () -> Void
    private var permissionTask: Task<Void, Never>?
    private var held = false
    private var recording = false

    init(requestPermission: @escaping () async -> Bool,
         startRecording: @escaping () -> Bool,
         sendRecording: @escaping () -> Void,
         discardRecording: @escaping () -> Void,
         permissionDenied: @escaping () -> Void) {
        self.requestPermission = requestPermission
        self.startRecording = startRecording
        self.sendRecording = sendRecording
        self.discardRecording = discardRecording
        self.permissionDenied = permissionDenied
    }

    func press() {
        guard !held else { return }
        held = true
        permissionTask = Task { [weak self] in
            guard let self, !Task.isCancelled, held else { return }
            let allowed = await requestPermission()
            guard !Task.isCancelled, held else { return }
            permissionTask = nil
            if allowed { recording = startRecording() }
            else { permissionDenied() }
        }
    }

    func release() {
        end(send: true)
    }

    func cancel() {
        end(send: false)
    }

    private func end(send: Bool) {
        held = false
        permissionTask?.cancel()
        permissionTask = nil
        guard recording else { return }
        recording = false
        if send { sendRecording() }
        else { discardRecording() }
    }
}
