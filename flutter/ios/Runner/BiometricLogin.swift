import CryptoKit
import Flutter
import LocalAuthentication
import Security

/// Keychain protects a data key with the current Face ID / Touch ID enrollment.
/// The encrypted session can rotate without another prompt while unlocked.
final class BiometricLogin {
  private let payloadKey = "mdesk.biometric.payload.v1"
  private let service = (Bundle.main.bundleIdentifier ?? "mdesk") + ".biometric-login.v1"
  private var dataKey: SymmetricKey?
  private var context: LAContext?
  private var pending: FlutterResult?
  private var operation = 0

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "has_session":
      result(UserDefaults.standard.data(forKey: payloadKey) != nil)
    case "is_available":
      result(isAvailable())
    case "clear":
      cancel()
      clear()
      result(nil)
    case "cancel":
      cancel()
      result(nil)
    case "enroll", "unlock":
      guard pending == nil else { result(failure("busy")); return }
      guard isAvailable() else { result(failure("unavailable")); return }
      authenticate(call, result: result)
    case "update":
      guard let payload = call.arguments as? String, let key = dataKey else {
        result(failure("storage")); return
      }
      do { try save(payload, key: key); result(nil) }
      catch { result(failure("storage")) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func isAvailable() -> Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: "data-key"]
  }

  private func authenticate(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let enrolling = call.method == "enroll"
    if enrolling { clear() }
    let auth = LAContext()
    auth.localizedFallbackTitle = ""
    auth.localizedReason = "저장된 MDesk 계정으로 로그인합니다"
    context = auth
    pending = result
    operation += 1
    let current = operation

    if enrolling {
      auth.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                          localizedReason: "MDesk 생체인증 로그인을 설정합니다") { success, error in
        DispatchQueue.main.async {
          guard self.operation == current else { return }
          guard success else {
            let code = (error as? LAError)?.code
            self.finish(code == .userCancel || code == .systemCancel || code == .appCancel
                        ? nil : self.failure("unavailable"))
            return
          }
          do {
            guard let payload = call.arguments as? String,
                  let access = SecAccessControlCreateWithFlags(nil,
                    kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil) else {
              throw VaultError.storage
            }
            let key = SymmetricKey(size: .bits256)
            var item = self.query
            item[kSecAttrAccessControl as String] = access
            item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
              throw VaultError.storage
            }
            try self.save(payload, key: key)
            self.dataKey = key
            self.finish(true)
          } catch {
            self.clear()
            self.finish(self.failure("storage"))
          }
        }
      }
    } else {
      var item = query
      item[kSecReturnData as String] = true
      item[kSecMatchLimit as String] = kSecMatchLimitOne
      item[kSecUseAuthenticationContext as String] = auth
      DispatchQueue.global(qos: .userInitiated).async {
        var stored: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &stored)
        let secret = stored as? Data
        DispatchQueue.main.async {
          guard self.operation == current else { return }
          if status == errSecUserCanceled { self.finish(nil); return }
          guard status == errSecSuccess, let secret = secret else {
            self.finish(self.failure(status == errSecItemNotFound ? "invalidated" : "unavailable"))
            return
          }
          do {
            let key = SymmetricKey(data: secret)
            guard let encrypted = UserDefaults.standard.data(forKey: self.payloadKey) else {
              throw VaultError.storage
            }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key)
            guard let payload = String(data: plain, encoding: .utf8) else { throw VaultError.storage }
            self.dataKey = key
            self.finish(payload)
          } catch {
            self.clear()
            self.finish(self.failure("invalidated"))
          }
        }
      }
    }
  }

  private func save(_ payload: String, key: SymmetricKey) throws {
    let encrypted = try AES.GCM.seal(Data(payload.utf8), using: key)
    guard let combined = encrypted.combined else { throw VaultError.storage }
    UserDefaults.standard.set(combined, forKey: payloadKey)
  }

  private func finish(_ value: Any?) {
    let result = pending
    pending = nil
    context = nil
    result?(value)
  }

  private func cancel() {
    operation += 1
    context?.invalidate()
    finish(nil)
  }

  private func clear() {
    dataKey = nil
    UserDefaults.standard.removeObject(forKey: payloadKey)
    SecItemDelete(query as CFDictionary)
  }

  private func failure(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }
  private enum VaultError: Error { case storage }
}
