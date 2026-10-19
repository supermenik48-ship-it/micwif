import SwiftUI
import UIKit

public struct OnboardingView: View {
    public var onComplete: () -> Void

    public init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Header Hero
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.8), Color.indigo],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 96, height: 96)
                            .shadow(color: Color.blue.opacity(0.35), radius: 16, x: 0, y: 8)

                        Image(systemName: "mic.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.white)

                        // Wi-Fi badge
                        Image(systemName: "wifi")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.blue)
                            .clipShape(Circle())
                            .offset(x: 32, y: -30)
                    }
                    .padding(.top, 24)

                    VStack(spacing: 8) {
                        Text("Wi-Fi Microphone")
                            .font(.system(size: 28, weight: .bold, design: .rounded))

                        Text("Беспроводной микрофон для вашего ПК")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                // Description card
                VStack(alignment: .leading, spacing: 14) {
                    FeatureRow(
                        icon: "iphone.radiowaves.left.and.right",
                        iconColor: .blue,
                        title: "Звук высокого качества",
                        subtitle: "Используйте встроенный микрофон iPhone как беспроводной микрофон для Windows."
                    )

                    Divider().padding(.vertical, 2)

                    FeatureRow(
                        icon: "network",
                        iconColor: .green,
                        title: "Прямая передача по Wi-Fi",
                        subtitle: "Звук передаётся напрямую по вашей локальной сети — без облака и задержек интернета."
                    )

                    Divider().padding(.vertical, 2)

                    FeatureRow(
                        icon: "lock.shield",
                        iconColor: .purple,
                        title: "Приватность и безопасность",
                        subtitle: "Каждая сессия защищена уникальным токеном авторизации."
                    )
                }
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                // Steps section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Как подключиться")
                        .font(.headline)
                        .padding(.horizontal, 4)

                    VStack(spacing: 14) {
                        StepRow(
                            stepNumber: 1,
                            title: "Запустите Wi-Fi Mic на компьютере",
                            subtitle: "Убедитесь, что iPhone и компьютер подключены к одной Wi-Fi сети."
                        )

                        StepRow(
                            stepNumber: 2,
                            title: "Отсканируйте QR-код с экрана",
                            subtitle: "Нажмите «Сканировать QR» в приложении и наведите камеру."
                        )

                        StepRow(
                            stepNumber: 3,
                            title: "Нажмите «Начать передачу»",
                            subtitle: "Аудиопоток мгновенно начнёт передаваться на ваш ПК."
                        )
                    }
                }
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Spacer(minLength: 16)

                // Action button
                Button {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    onComplete()
                } label: {
                    Text("Начать")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Color.blue.opacity(0.3), radius: 10, x: 0, y: 5)
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

// MARK: - Subviews
private struct FeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StepRow: View {
    let stepNumber: Int
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(stepNumber)")
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Color.blue)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
