import RDCore
import SwiftUI

struct LoginView: View {
  @Bindable var session: SessionViewModel
  @FocusState private var focused: Field?

  enum Field { case email, password }

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        VStack(spacing: 8) {
          Image(systemName: "building.2.crop.circle.fill")
            .font(.system(size: 64))
            .foregroundStyle(Theme.accent)
          Text("RD Yönetim")
            .font(.largeTitle.weight(.bold))
          Text("RD İnşaat proje ve cari takibi")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 48)

        VStack(spacing: 12) {
          TextField("E-posta", text: $session.email)
            .textContentType(.username)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused, equals: .email)
            .submitLabel(.next)
            .onSubmit { focused = .password }
          SecureField("Şifre", text: $session.password)
            .textContentType(.password)
            .focused($focused, equals: .password)
            .submitLabel(.go)
            .onSubmit { Task { await session.signIn() } }
        }
        .textFieldStyle(.roundedBorder)

        ErrorBanner(message: session.errorMessage)
        if let info = session.infoMessage {
          Label(info, systemImage: "envelope").font(.callout).foregroundStyle(.secondary)
        }

        Button {
          Task { await session.signIn() }
        } label: {
          Group {
            if session.isWorking { ProgressView() } else { Text("Giriş yap") }
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!session.canSubmit)

        Button("Şifremi unuttum") { Task { await session.sendPasswordReset() } }
          .font(.callout)
          .disabled(session.isWorking)

        Text("Hesaplar yalnızca yönetici tarafından açılır.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 24)
      .frame(maxWidth: 480)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Theme.pageBackground)
  }
}
