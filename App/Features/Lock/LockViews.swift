import SwiftUI
import UIKit

/// The lock screen, or the plain cover the app switcher sees, in a window of its own
/// above the app's: the player and sheets are presented over the app's window, and would
/// show over anything drawn inside it.
@MainActor
final class LockWindow {
    private var window: UIWindow?

    func update(shown: Bool, state: AppState) {
        if shown { show(state) } else { hide() }
    }

    private func show(_ state: AppState) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState != .background }) ?? scenes.first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: LockRoot().environment(state))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
    }

    private func hide() {
        guard let window else { return }
        self.window = nil
        window.rootViewController?.dismiss(animated: false)
        // The app's own window takes the keyboard back.
        window.windowScene?.windows.first { $0 !== window && !$0.isHidden }?.makeKey()
        UIView.animate(withDuration: 0.2) {
            window.alpha = 0
        } completion: { _ in
            window.isHidden = true
        }
    }
}

private struct LockRoot: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if state.lock.isLocked {
                LockScreen()
            } else {
                // Away for a moment: nothing of the library shows in the app switcher.
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 54)).foregroundStyle(Color.plexGold)
                    Text("jellymc").font(.title2.bold())
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// The PIN, asked for when the app opens.
private struct LockScreen: View {
    @Environment(AppState.self) private var state
    @State private var message: String?
    @State private var shakes = 0
    @State private var forgot = false

    var body: some View {
        let lock = state.lock
        VStack(spacing: 0) {
            // Ticks while a wrong PIN has to wait, for the count down.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let until = lock.waitUntil
                PINPad(
                    title: "Enter PIN",
                    message: until.map { "Too many tries. Try again in \(Self.remaining(until: $0, from: context.date))." } ?? message,
                    isDisabled: until != nil,
                    shakes: shakes
                ) { pin in
                    switch lock.attempt(pin) {
                    case .unlocked:
                        message = nil
                    case let .wrong(left):
                        message = left == 1 ? "Wrong PIN. One more try before a wait." : "Wrong PIN"
                        shakes += 1
                    case .wait:
                        message = nil
                        shakes += 1
                    }
                }
            }
            Button("Forgot PIN?") { forgot = true }
                .font(.subheadline)
                .tint(.secondary)
                .padding(.top, 8)
        }
        .padding()
        .sheet(isPresented: $forgot) { ForgotPINView() }
    }

    private static func remaining(until: Date, from now: Date) -> String {
        let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
        return seconds < 60 ? "\(seconds) s" : "\(Int((Double(seconds) / 60).rounded(.up))) min"
    }
}

/// Instead of the PIN, the account's Jellyfin password: the server checks it and the lock
/// turns off. Nothing is signed out.
private struct ForgotPINView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(submit)
                } header: {
                    Text("Jellyfin password for \(state.session?.userName ?? "your account")")
                } footer: {
                    Text(error ?? "The server checks it, and the PIN is turned off. You stay signed in, and can choose a new PIN in Settings.")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
                Section {
                    Button(action: submit) {
                        if working { ProgressView() } else { Text("Turn Off PIN") }
                    }
                    .disabled(working)
                }
            }
            .navigationTitle("Forgot PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func submit() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await state.unlockWithPassword(password)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// Settings' PIN sheet: choose one, change it, or turn it off. Changing and turning off
/// ask for the current one first.
struct SetPINView: View {
    enum Mode: String, Identifiable {
        case new, change, turnOff
        var id: String { rawValue }
    }

    private enum Step: Hashable {
        case current
        case new
        case confirm(String)
    }

    let mode: Mode
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var message: String?
    @State private var shakes = 0

    init(mode: Mode) {
        self.mode = mode
        _step = State(initialValue: mode == .new ? .new : .current)
    }

    var body: some View {
        NavigationStack {
            PINPad(title: title, message: message, shakes: shakes, onComplete: entered)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(mode == .turnOff ? "Turn Off PIN" : mode == .change ? "Change PIN" : "Set a PIN")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    private var title: String {
        switch step {
        case .current: return "Enter Your PIN"
        case .new: return mode == .change ? "Choose a New PIN" : "Choose a PIN"
        case .confirm: return "Enter It Again"
        }
    }

    private func entered(_ pin: String) {
        let lock = state.lock
        switch step {
        case .current:
            switch lock.check(pin) {
            case .unlocked:
                message = nil
                if mode == .turnOff {
                    lock.turnOff()
                    dismiss()
                } else {
                    step = .new
                }
            case .wrong:
                message = "Wrong PIN"
                shakes += 1
            case .wait:
                message = "Too many tries. Try again in a little while."
                shakes += 1
            }
        case .new:
            message = nil
            step = .confirm(pin)
        case let .confirm(first):
            if pin == first {
                lock.setPIN(pin)
                dismiss()
            } else {
                message = "Those didn’t match. Choose one again."
                step = .new
                shakes += 1
            }
        }
    }
}

/// The dots and the keypad. Fills in as digits are tapped, and hands on the PIN once it
/// has all four.
private struct PINPad: View {
    let title: String
    var message: String?
    var isDisabled = false
    /// Goes up for each wrong PIN: the dots shake.
    var shakes = 0
    let onComplete: (String) -> Void
    @State private var entered = ""

    private static let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "delete"]]

    var body: some View {
        GeometryReader { proxy in
            // Keys as large as the space allows, up to the phone's own: a phone on its
            // side has room for the keypad only beside the dots.
            let wide = proxy.size.width > proxy.size.height * 1.2
            let key = max(44, min(76, (proxy.size.height - (wide ? 30 : 190)) / 4 - 14))
            Group {
                if wide {
                    HStack(spacing: 48) {
                        header
                        keypad(key)
                    }
                } else {
                    VStack(spacing: 28) {
                        header
                        keypad(key)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var header: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.title).foregroundStyle(Color.plexGold)
            Text(title).font(.title3.weight(.semibold))
            HStack(spacing: 20) {
                ForEach(0 ..< AppLock.length, id: \.self) { index in
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
                        .background(Circle().fill(index < entered.count ? Color.primary : Color.clear))
                        .frame(width: 14, height: 14)
                }
            }
            .modifier(Shake(travel: CGFloat(shakes)))
            .animation(.linear(duration: 0.4), value: shakes)
            Text(message ?? " ")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280, minHeight: 36, alignment: .top)
        }
    }

    private func keypad(_ size: CGFloat) -> some View {
        VStack(spacing: size * 0.2) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: size * 0.35) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key, size: size)
                    }
                }
            }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }

    @ViewBuilder
    private func keyButton(_ key: String, size: CGFloat) -> some View {
        switch key {
        case "":
            Color.clear.frame(width: size, height: size)
        case "delete":
            Button {
                if !entered.isEmpty { entered.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(.title2)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(entered.isEmpty ? 0 : 1)
            .accessibilityLabel("Delete")
        default:
            Button {
                type(key)
            } label: {
                Text(key)
                    .font(.system(size: size * 0.42, design: .rounded))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(KeyStyle())
        }
    }

    private func type(_ digit: String) {
        guard entered.count < AppLock.length else { return }
        entered.append(digit)
        guard entered.count == AppLock.length else { return }
        let pin = entered
        // A beat with the last dot filled in, then on, and the dots empty for what is next.
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            onComplete(pin)
            entered = ""
        }
    }
}

/// A key lights up while it is held, as the phone's own keypad does.
private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.25 : 0)
    }
}

/// A shake from side to side, once for each step `travel` takes.
private struct Shake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(travel * .pi * 4), y: 0))
    }
}
