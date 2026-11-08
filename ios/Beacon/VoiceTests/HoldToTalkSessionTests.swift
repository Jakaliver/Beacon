import Foundation

@MainActor
private final class Microphone {
    var permissions: [CheckedContinuation<Bool, Never>] = []
    var returned = 0
    var starts = 0
    var sends = 0
    var discards = 0
    var denials = 0
    var canRecord = true

    lazy var session = HoldToTalkSession(
        requestPermission: {
            let allowed = await withCheckedContinuation { self.permissions.append($0) }
            self.returned += 1
            return allowed
        },
        startRecording: { self.starts += 1; return self.canRecord },
        sendRecording: { self.sends += 1 },
        discardRecording: { self.discards += 1 },
        permissionDenied: { self.denials += 1 }
    )
}

@main
struct HoldToTalkSessionTests {
    @MainActor
    static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Timed out waiting for the permission task")
    }

    @MainActor
    static func main() async {
        let mic = Microphone()
        mic.session.press()
        mic.session.press()
        await waitFor { mic.permissions.count == 1 }
        mic.permissions[0].resume(returning: true)
        await waitFor { mic.starts == 1 }
        precondition(mic.sends == 0, "A held button must not send automatically")
        mic.session.press()
        precondition(mic.starts == 1 && mic.sends == 0, "Repeated touch-down is not a toggle")
        mic.session.release()
        mic.session.release()
        precondition(mic.sends == 1 && mic.discards == 0, "Release sends exactly once")

        mic.session.press()
        await waitFor { mic.permissions.count == 2 }
        mic.permissions[1].resume(returning: true)
        await waitFor { mic.starts == 2 }
        mic.session.cancel()
        mic.session.release()
        precondition(mic.discards == 1 && mic.sends == 1, "A cancelled gesture discards instead of sending")

        // Release during the permission prompt, then press again before the old answer arrives.
        let delayed = Microphone()
        delayed.session.press()
        await waitFor { delayed.permissions.count == 1 }
        delayed.session.release()
        delayed.session.press()
        await waitFor { delayed.permissions.count == 2 }
        delayed.permissions[0].resume(returning: true)
        await waitFor { delayed.returned == 1 }
        await Task.yield()
        precondition(delayed.starts == 0, "A permission answer from a released hold must not open the mic")
        delayed.permissions[1].resume(returning: true)
        await waitFor { delayed.starts == 1 }
        delayed.session.release()
        precondition(delayed.sends == 1, "The current hold still works after an older prompt completes")

        let cancelled = Microphone()
        cancelled.session.press()
        await waitFor { cancelled.permissions.count == 1 }
        cancelled.session.cancel()
        cancelled.permissions[0].resume(returning: true)
        await waitFor { cancelled.returned == 1 }
        await Task.yield()
        cancelled.session.release()
        precondition(cancelled.starts == 0 && cancelled.sends == 0, "Cancellation while awaiting permission cannot start later")

        let denied = Microphone()
        denied.session.press()
        await waitFor { denied.permissions.count == 1 }
        denied.permissions[0].resume(returning: false)
        await waitFor { denied.denials == 1 }
        denied.session.release()
        precondition(denied.starts == 0 && denied.sends == 0, "Denied permission cannot record or send")

        let failed = Microphone()
        failed.canRecord = false
        failed.session.press()
        await waitFor { failed.permissions.count == 1 }
        failed.permissions[0].resume(returning: true)
        await waitFor { failed.starts == 1 }
        failed.session.release()
        precondition(failed.sends == 0, "A recorder that failed to start cannot send a stale file")

        let quick = Microphone()
        quick.session.press()
        quick.session.release()
        // Run a separate request to let both queued permission tasks finish their first turn.
        let next = Microphone()
        next.session.press()
        await waitFor { next.permissions.count == 1 }
        next.permissions[0].resume(returning: false)
        await waitFor { next.denials == 1 }
        next.session.release()
        precondition(quick.permissions.isEmpty && quick.starts == 0, "A released touch cannot request permission later")

        let action = Microphone()
        action.session.toggle()
        await waitFor { action.permissions.count == 1 }
        action.permissions[0].resume(returning: true)
        await waitFor { action.starts == 1 }
        precondition(action.session.isActive && action.sends == 0, "First Action activation keeps recording")
        action.session.toggle()
        precondition(!action.session.isActive && action.sends == 1, "Second Action activation sends exactly once")
        action.session.toggle()
        await waitFor { action.permissions.count == 2 }
        action.session.toggle()
        action.permissions[1].resume(returning: true)
        await waitFor { action.returned == 2 }
        await Task.yield()
        precondition(action.starts == 1 && action.sends == 1, "Second activation during permission cancels a pending start")
        print("Talk controls: screen hold/release, Action toggle, cancellation, stale permissions and recorder failure passed")
    }
}
