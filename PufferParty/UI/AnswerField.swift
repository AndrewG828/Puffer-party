import SwiftUI
import UIKit

/// The answer box. A UITextField so the keyboard stays up after Return:
/// you can keep typing through the whole round, pre-type while someone else
/// holds the puffer, and fire with Return the moment it reaches you.
struct AnswerField: UIViewRepresentable {
    let text: String
    let placeholder: String
    let enabled: Bool
    /// Changing this focuses the field (e.g. when the puffer reaches you).
    let focusKey: Int
    let hot: Bool
    var onEdit: (_ newText: String, _ inserted: String, _ removedLength: Int) -> Void
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.textContentType = .none
        field.returnKeyType = .send
        field.enablesReturnKeyAutomatically = true
        field.keyboardAppearance = .dark
        field.font = Self.font
        field.adjustsFontForContentSizeCategory = true
        field.textColor = UIColor(Palette.foam)
        field.tintColor = UIColor(Palette.cyan)
        field.clearButtonMode = .never
        field.accessibilityLabel = "Your answer"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.markedTextRange == nil, field.text != text { field.text = text }
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(hot ? Palette.pink : Palette.drift), .font: Self.font]
        )
        if field.isEnabled != enabled { field.isEnabled = enabled }
        if context.coordinator.lastFocusKey != focusKey {
            context.coordinator.lastFocusKey = focusKey
            if enabled {
                DispatchQueue.main.async { field.becomeFirstResponder() }
            }
        }
    }

    private static var font: UIFont {
        let base = UIFont(name: "VT323", size: 28) ?? .monospacedSystemFont(ofSize: 22, weight: .regular)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, maximumPointSize: 36)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AnswerField
        var lastFocusKey: Int
        private var pendingInsert = ""
        private var pendingRemoved = 0

        init(parent: AnswerField) {
            self.parent = parent
            lastFocusKey = parent.focusKey
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            let current = textField.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return false }
            let next = current.replacingCharacters(in: swiftRange, with: string)
            if next.count > Party.maxAnswerLength && string.count > 0 { return false }
            pendingInsert = string
            pendingRemoved = range.length
            return true
        }

        @objc func editingChanged(_ textField: UITextField) {
            parent.onEdit(textField.text ?? "", pendingInsert, pendingRemoved)
            pendingInsert = ""
            pendingRemoved = 0
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
