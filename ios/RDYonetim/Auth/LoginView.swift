import RDCore
import RDDesign
import SwiftUI

struct LoginView: View {
  @Bindable var session: SessionViewModel
  @FocusState private var emailFocused: Bool
  @FocusState private var passwordFocused: Bool

  var body: some View {
    ScrollView {
      VStack(spacing: .rdXXL) {
        VStack(spacing: .rdS) {
          RDBrandMark()
          Text("RD İnşaat proje ve cari takibi")
            .font(RDFont.secondary)
            .foregroundStyle(RDColor.textSecondary)
        }
        .padding(.top, .rdXXL * 2)

        VStack(spacing: .rdL) {
          RDTextField(label: "E-posta", text: $session.email, prompt: "ad.soyad@rdinsaat.com", focus: $emailFocused)
            .textContentType(.username)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { passwordFocused = true }
          RDTextField(label: "Şifre", text: $session.password, isSecure: true, focus: $passwordFocused)
            .textContentType(.password)
            .submitLabel(.go)
            .onSubmit { submit() }
        }

        VStack(spacing: .rdM) {
          RDErrorBanner(message: session.errorMessage)
          if let info = session.infoMessage {
            Label(info, systemImage: "envelope")
              .font(RDFont.secondary)
              .foregroundStyle(RDColor.textSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          RDPrimaryButton(title: "Giriş yap", isLoading: session.isWorking, action: submit)
            .disabled(!session.canSubmit)
          Button("Şifremi unuttum") { Task { await session.sendPasswordReset() } }
            .font(RDFont.secondary.weight(.semibold))
            .frame(minHeight: Metrics.minTouchTarget)
            .disabled(session.isWorking)
        }

        Text("Hesaplar yalnızca yönetici tarafından açılır.")
          .font(RDFont.caption)
          .foregroundStyle(RDColor.textSecondary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, .rdXL)
      .frame(maxWidth: 480)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(RDColor.background.ignoresSafeArea())
  }

  private func submit() {
    emailFocused = false
    passwordFocused = false
    Task { await session.signIn() }
  }
}
