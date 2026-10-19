import SwiftUI
import UIKit

public struct ManualEntryView: View {
    @Environment(\.dismiss) private var dismiss

    public var onConnect: (String, UInt16, UUID) -> Void

    @State private var ipAddress: String = ""
    @State private var portString: String = "45455"
    @State private var tokenString: String = ""
    @State private var errorMessage: String?

    public init(
        initialIp: String = "",
        initialPort: UInt16 = 45455,
        initialToken: String = "",
        onConnect: @escaping (String, UInt16, UUID) -> Void
    ) {
        self.onConnect = onConnect
        _ipAddress = State(initialValue: initialIp)
        _portString = State(initialValue: "\(initialPort)")
        _tokenString = State(initialValue: initialToken)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("IP-адрес компьютера")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Например: 192.168.1.100", text: $ipAddress)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Порт управления (TCP)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("45455", text: $portString)
                            .keyboardType(.numberPad)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Токен сессии (GUID / UUID)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("a1b2c3d4-e5f6-7890-abcd-ef1234567890", text: $tokenString)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Параметры сервера")
                } footer: {
                    Text("Все эти параметры отображаются в окне приложения Wi-Fi Mic на компьютере.")
                }

                if let error = errorMessage {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                    }
                }

                Section {
                    Button {
                        validateAndConnect()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Подключиться")
                                .font(.headline)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Ручной ввод")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func validateAndConnect() {
        let trimmedIp = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = portString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = tokenString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedIp.isEmpty else {
            errorMessage = "Пожалуйста, введите IP-адрес."
            return
        }

        guard let portNum = UInt16(trimmedPort), portNum > 0 else {
            errorMessage = "Неверный номер порта (допустимо 1–65535)."
            return
        }

        guard let token = UUID(uuidString: trimmedToken) else {
            errorMessage = "Неверный формат токена. Требуется UUID (например, a1b2c3d4-e5f6-7890-abcd-ef1234567890)."
            return
        }

        errorMessage = nil
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        dismiss()
        onConnect(trimmedIp, portNum, token)
    }
}
