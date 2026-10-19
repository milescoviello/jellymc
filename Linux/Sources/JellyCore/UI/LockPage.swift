import CGtk
import Foundation

/// The four dots and a keypad: digits from the keys or the keyboard, handed on once all
/// four are in.
@MainActor
final class PINPad {
    let root: Widget
    var onComplete: (@MainActor (String) -> Void)?
    private let title: Label
    private let message: Label
    private let dots: [Widget]
    private let keypad: Grid
    private var entered = ""
    private var isDisabled = false

    init(title text: String) {
        let title = Label(text, "title-2")
        let message = Label(" ", "dim-label").wrap().justify(GTK_JUSTIFY_CENTER).maxWidthChars(34)
        let dots = (0 ..< AppLock.length).map { _ in Box().css("pin-dot").valign(GTK_ALIGN_CENTER) }
        let row = Box.horizontal(spacing: 18).halign(GTK_ALIGN_CENTER)
        for dot in dots { row.append(dot) }
        let keypad = Grid(rowSpacing: 12, columnSpacing: 18)
        self.title = title
        self.message = message
        self.dots = dots
        self.keypad = keypad
        root = Box.vertical(spacing: 18) {
            Icon("system-lock-screen-symbolic", size: 32).css("accent")
            title.halign(GTK_ALIGN_CENTER)
            row
            message.halign(GTK_ALIGN_CENTER)
            keypad.halign(GTK_ALIGN_CENTER).margins(top: 6)
        }
        .halign(GTK_ALIGN_CENTER)
        .valign(GTK_ALIGN_CENTER)
        for (index, key) in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"].enumerated() {
            let column = Int32(index % 3), line = Int32(index / 3)
            switch key {
            case "": continue
            case "⌫":
                keypad.attach(Button(icon: "edit-clear-symbolic", "flat", "circular", "pin-key") { [weak self] in self?.backspace() }
                    .tooltip("Delete"), column: column, row: line)
            default:
                keypad.attach(Button(key, "circular", "pin-key") { [weak self] in self?.type(key) }, column: column, row: line)
            }
        }
        root.keep(self)
    }

    func setTitle(_ text: String) { title.text = text }

    func setMessage(_ text: String?) { message.text = text ?? " " }

    /// While a wrong PIN has to wait: no keys.
    func setDisabled(_ value: Bool) {
        isDisabled = value
        keypad.sensitive(!value)
    }

    /// A digit, Backspace or the keypad's digits from the keyboard; true if it was one.
    func key(_ keyval: UInt32) -> Bool {
        switch Int32(keyval) {
        case GDK_KEY_0 ... GDK_KEY_9:
            type(String(Int32(keyval) - GDK_KEY_0))
        case GDK_KEY_KP_0 ... GDK_KEY_KP_9:
            type(String(Int32(keyval) - GDK_KEY_KP_0))
        case GDK_KEY_BackSpace, GDK_KEY_Delete:
            backspace()
        default:
            return false
        }
        return true
    }

    /// Wrong: the dots shake, and empty.
    func shake() {
        root.setCSS("pin-shake", false)
        root.setCSS("pin-shake", true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            self?.root.setCSS("pin-shake", false)
        }
    }

    private func type(_ digit: String) {
        guard !isDisabled, entered.count < AppLock.length else { return }
        entered.append(digit)
        redraw()
        guard entered.count == AppLock.length else { return }
        let pin = entered
        // A beat with the last dot filled in, then on, and the dots empty for what is next.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self else { return }
            self.entered = ""
            self.redraw()
            self.onComplete?(pin)
        }
    }

    private func backspace() {
        guard !entered.isEmpty else { return }
        entered.removeLast()
        redraw()
    }

    private func redraw() {
        for (index, dot) in dots.enumerated() { dot.setCSS("filled", index < entered.count) }
    }
}

/// The PIN, asked for over the whole window when the app opens and when it comes back
/// after a while away. Nothing is signed out; a forgotten PIN gives way to the account's
/// Jellyfin password.
@MainActor
final class LockPage {
    let root: Widget
    private let pad = PINPad(title: "Enter PIN")
    private unowned let state: AppState
    private var ticking = false

    init(state: AppState) {
        self.state = state
        let forgot = Button("Forgot PIN?", "flat")
        let pad = pad
        root = Box.vertical(spacing: 18) {
            pad.root
            forgot.halign(GTK_ALIGN_CENTER)
        }
        .halign(GTK_ALIGN_CENTER)
        .valign(GTK_ALIGN_CENTER)
        .vexpand()
        .hexpand()
        forgot.onClicked { [weak self] in self?.askForPassword() }
        pad.onComplete = { [weak self] pin in self?.entered(pin) }
        root.keep(self)
        showWait()
    }

    func key(_ keyval: UInt32) -> Bool { pad.key(keyval) }

    private func entered(_ pin: String) {
        switch state.lock.attempt(pin) {
        case .unlocked:
            pad.setMessage(nil)
        case let .wrong(left):
            pad.setMessage(left == 1 ? "Wrong PIN. One more try before a wait." : "Wrong PIN")
            pad.shake()
        case .wait:
            pad.shake()
            showWait()
        }
    }

    /// Counts down while a wrong PIN has to wait, and opens the keys again after.
    private func showWait() {
        guard let until = state.lock.waitUntil else {
            pad.setDisabled(false)
            return
        }
        pad.setDisabled(true)
        let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
        pad.setMessage("Too many tries. Try again in \(seconds < 60 ? "\(seconds) s" : "\(Int((Double(seconds) / 60).rounded(.up))) min").")
        guard !ticking else { return }
        ticking = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.ticking = false
            if self.state.lock.waitUntil == nil { self.pad.setMessage(nil) }
            self.showWait()
        }
    }

    private func askForPassword() {
        let entry = Entry(placeholder: "Password").password()
        gtk_entry_set_activates_default(entry.widget.cast(), 1)
        let state = state
        Dialogs.alert(
            "Forgot PIN",
            body: "Your Jellyfin password for \(state.session?.userName ?? "this account") turns the PIN off. You stay signed in.",
            responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("off", "Turn Off PIN", ADW_RESPONSE_SUGGESTED)],
            defaultResponse: "off",
            extra: entry
        ) { response in
            guard response == "off" else { return }
            let password = entry.text
            Task {
                do {
                    try await state.unlockWithPassword(password)
                    Desktop.main?.toast("PIN turned off. Choose a new one in Settings.")
                } catch {
                    Desktop.main?.toast(error.localizedDescription)
                }
            }
        }
        entry.grabFocus()
    }
}

/// Settings' PIN dialog: choose one, change it, or turn it off. Changing and turning off
/// ask for the current one first.
@MainActor
enum PINSetup {
    enum Mode { case new, change, turnOff }

    private enum Step: Equatable {
        case current
        case new
        case confirm(String)
    }

    /// `done` says whether it went through; closed or cancelled, it did not.
    static func present(_ mode: Mode, state: AppState, done: @escaping @MainActor (Bool) -> Void) {
        let pad = PINPad(title: "")
        var step: Step = mode == .new ? .new : .current
        var finished = false
        let content = pad.root.margin(24)
        let dialog = Dialogs.sheet(mode == .turnOff ? "Turn Off PIN" : mode == .change ? "Change PIN" : "Set a PIN", content: content, width: 380, height: 560)

        func show() {
            switch step {
            case .current: pad.setTitle("Enter Your PIN")
            case .new: pad.setTitle(mode == .change ? "Choose a New PIN" : "Choose a PIN")
            case .confirm: pad.setTitle("Enter It Again")
            }
        }
        func finish(_ succeeded: Bool) {
            finished = true
            done(succeeded)
            Dialogs.close(dialog)
        }
        show()
        pad.onComplete = { pin in
            let lock = state.lock
            switch step {
            case .current:
                switch lock.check(pin) {
                case .unlocked:
                    pad.setMessage(nil)
                    if mode == .turnOff {
                        lock.turnOff()
                        finish(true)
                        return
                    }
                    step = .new
                case .wrong:
                    pad.setMessage("Wrong PIN")
                    pad.shake()
                case .wait:
                    pad.setMessage("Too many tries. Try again in a little while.")
                    pad.shake()
                }
            case .new:
                pad.setMessage(nil)
                step = .confirm(pin)
            case let .confirm(first):
                if pin == first {
                    lock.setPIN(pin)
                    finish(true)
                    return
                }
                pad.setMessage("Those didn’t match. Choose one again.")
                pad.shake()
                step = .new
            }
            show()
        }
        // Typed digits go to the pad.
        let keys = gtk_event_controller_key_new()!
        Signal.connect(keys, "key-pressed", key: { keyval, _, _ in pad.key(keyval) })
        gtk_widget_add_controller(dialog.cast(), keys)
        Signal.connect(dialog, "closed") {
            if !finished { done(false) }
        }
    }
}
