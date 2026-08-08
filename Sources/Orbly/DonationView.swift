import AppKit
import SwiftUI

/// Spendenfenster im Look der Erst-Tour (dunkel, Nachthimmel, eine helle
/// Kapsel). Zwei Zustände: fragen und danken.
///
/// „Ich habe gespendet" erscheint erst, nachdem die Spendenseite geöffnet wurde.
/// Vorher wäre es nur ein zweiter Knopf zum Wegklicken.
struct DonationView: View {
    let dictations: Int
    /// Fenster schließen. Das Speichern passiert vorher hier in der Ansicht.
    let close: () -> Void

    @State private var pageOpened = false
    @State private var thanks = false

    var body: some View {
        ZStack {
            NightSky()
            if thanks {
                thanksPage
            } else {
                askPage
            }
        }
        .frame(width: 420, height: 480)
        .animation(.easeOut(duration: 0.25), value: thanks)
        .animation(.easeOut(duration: 0.2), value: pageOpened)
    }

    // MARK: - Fragen

    private var askPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            IconTile(symbol: "heart", size: 58)

            Text(L10n.t("donate.title"))
                .font(.system(size: 27, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(OB.title)
                .padding(.top, 18)

            Text(L10n.t("donate.body"))
                .font(.system(size: 14.5))
                .foregroundStyle(OB.text)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.horizontal, 34)

            Text(L10n.t("donate.count", dictations))
                .font(.system(size: 12.5))
                .foregroundStyle(OB.faint)
                .padding(.top, 12)

            Spacer(minLength: 24)

            PrimaryPillButton(title: L10n.t("donate.button"), systemImage: "arrow.up.right") {
                NSWorkspace.shared.open(Donation.pageURL)
                pageOpened = true
            }

            if pageOpened {
                Text(L10n.t("donate.opened"))
                    .font(.system(size: 12))
                    .foregroundStyle(OB.faint)
                    .padding(.top, 12)

                GhostPillButton(title: L10n.t("donate.confirm"), systemImage: "checkmark") {
                    AppSettings.shared.hasDonated = true
                    thanks = true
                    // Kurz stehen lassen, dann von selbst schließen.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { close() }
                }
                .padding(.top, 10)
            }

            HStack(spacing: 22) {
                QuietButton(title: L10n.t("donate.later")) {
                    AppSettings.shared.donationPromptLastShown = Date()
                    close()
                }
                QuietButton(title: L10n.t("donate.never")) {
                    AppSettings.shared.donationPromptDisabled = true
                    close()
                }
            }
            .padding(.top, 20)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 28)
    }

    // MARK: - Danken

    private var thanksPage: some View {
        VStack(spacing: 14) {
            IconTile(symbol: "checkmark", size: 58)
            Text(L10n.t("donate.thanks.title"))
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(OB.title)
            Text(L10n.t("donate.thanks.body"))
                .font(.system(size: 14.5))
                .foregroundStyle(OB.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
