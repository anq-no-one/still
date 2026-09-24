import LocalAuthentication

@MainActor
struct SystemOwnerAuthenticator: OwnerAuthenticator {
    func authenticate(reason: String) async -> OwnerAuthenticationResult {
        let context = LAContext()
        var availability: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availability) else {
            return .unavailable(
                String(localized: "Set a passcode for this device in Settings, then unlock Still with it.")
            )
        }

        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return .success
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
