import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// Track intentional body bold separately from the title font and dynamic type size.
private let writingBoldAttribute = NSAttributedString.Key("TodoM0BodyBold")

private func writingParagraphStyle(title: Bool) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = title ? 2 : 4
    style.paragraphSpacing = title ? 12 : 6
    return style
}


struct TaskWriting: Equatable {
    var title = ""
    var body = ""
    var formatting: NoteFormatting?

    var hasText: Bool { !title.isEmpty || !body.isEmpty }
}

struct TaskWritingEditor: View {
    @Binding private var content: TaskWriting
    private let autofocus: Bool
    private let editable: Bool
    private let minimumHeight: CGFloat
    @StateObject private var controller = TaskWritingEditorController()

    init(content: Binding<TaskWriting>, autofocus: Bool = false, editable: Bool = true, minimumHeight: CGFloat = 260) {
        _content = content
        self.autofocus = autofocus
        self.editable = editable
        self.minimumHeight = minimumHeight
    }

    static func finishEditing() {
        #if os(macOS)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #else
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TaskWritingPlatformEditor(content: $content, autofocus: autofocus, editable: editable,
                                          controller: controller)
                    .frame(minHeight: minimumHeight)
                    .accessibilityIdentifier("taskWritingEditor")
                    .accessibilityLabel("任务编辑器；第一段为标题，换行后为正文")
            }
            .frame(minHeight: minimumHeight)
        }
    }
}

private enum TaskWritingCommand {
    case bold
    case bullets
    case numbers
}

private final class TaskWritingEditorController: ObservableObject {
    private var retainedCoordinator: AnyObject?

    func install(retaining coordinator: AnyObject) { retainedCoordinator = coordinator }
    func detach() { retainedCoordinator = nil }
}

private struct WritingSplit {
    let title: String
    let body: String
    let hasSeparator: Bool
    let separatorLocation: Int?
    let bodyStart: Int
}

enum WritingListKind {
    case bullets
    case numbers
}

private struct WritingListPrefix {
    let kind: WritingListKind
    let range: NSRange
}

private struct WritingLine {
    let range: NSRange
    let fullRange: NSRange
    let prefix: WritingListPrefix?
}

enum TaskWritingText {
    fileprivate static func split(_ text: String) -> WritingSplit {
        let value = text as NSString
        let newline = value.range(of: "\n").location
        guard newline != NSNotFound else {
            return WritingSplit(title: text, body: "", hasSeparator: false,
                                separatorLocation: nil, bodyStart: value.length)
        }
        let bodyStart = newline + 1
        return WritingSplit(title: value.substring(to: newline), body: value.substring(from: bodyStart),
                            hasSeparator: true, separatorLocation: newline, bodyStart: bodyStart)
    }

    fileprivate static func text(for content: TaskWriting, preservingSeparator: Bool) -> String {
        if !content.body.isEmpty || preservingSeparator {
            return content.title + "\n" + content.body
        }
        return content.title
    }

    private static func lines(in text: String, bodyStart: Int) -> [WritingLine] {
        let value = text as NSString
        let length = value.length
        guard bodyStart <= length else { return [] }

        var result: [WritingLine] = []
        var start = bodyStart
        while start <= length {
            let remaining = NSRange(location: start, length: length - start)
            let newline = value.range(of: "\n", options: [], range: remaining)
            let end = newline.location == NSNotFound ? length : newline.location
            let range = NSRange(location: start, length: end - start)
            let line = value.substring(with: range)
            let prefix = listPrefix(in: line, location: start)
            let fullEnd = newline.location == NSNotFound ? end : newline.location + 1
            result.append(WritingLine(range: range,
                                      fullRange: NSRange(location: start, length: fullEnd - start),
                                      prefix: prefix))
            guard newline.location != NSNotFound else { break }
            start = newline.location + 1
        }
        return result
    }

    private static func selectedLines(in text: String, bodyStart: Int, selection: NSRange) -> [WritingLine] {
        let lines = lines(in: text, bodyStart: bodyStart)
        guard !lines.isEmpty else { return [] }
        if selection.length == 0 {
            return lines.filter {
                selection.location >= $0.range.location && selection.location <= NSMaxRange($0.range)
            }
        }
        return lines.filter { NSIntersectionRange($0.fullRange, selection).length > 0 }
    }

    private static func listPrefix(in line: String, location: Int) -> WritingListPrefix? {
        let value = line as NSString
        if value.length >= 2, value.character(at: 0) == 0x2022, value.character(at: 1) == 0x20 {
            return WritingListPrefix(kind: .bullets, range: NSRange(location: location, length: 2))
        }

        var digitEnd = 0
        while digitEnd < value.length {
            let scalar = value.character(at: digitEnd)
            guard scalar >= 0x30 && scalar <= 0x39 else { break }
            digitEnd += 1
        }
        guard digitEnd > 0, value.length >= digitEnd + 2,
              value.character(at: digitEnd) == 0x2e,
              value.character(at: digitEnd + 1) == 0x20 else { return nil }
        return WritingListPrefix(kind: .numbers,
                                 range: NSRange(location: location, length: digitEnd + 2))
    }

    private static func prefixText(for kind: WritingListKind, number: Int) -> String {
        switch kind {
        case .bullets: return "• "
        case .numbers: return "\(number). "
        }
    }

    static func listReplacements(in text: String, selection: NSRange,
                                 kind: WritingListKind) -> [(range: NSRange, text: String)] {
        let split = Self.split(text)
        guard split.hasSeparator else { return [] }
        let selected = selectedLines(in: text, bodyStart: split.bodyStart, selection: selection)
        guard !selected.isEmpty else { return [] }
        let remove = selected.allSatisfy { $0.prefix?.kind == kind }
        var replacements: [(range: NSRange, text: String)] = []
        for (index, line) in selected.enumerated() {
            if remove {
                if let prefix = line.prefix, prefix.kind == kind {
                    replacements.append((prefix.range, ""))
                }
            } else {
                let range = line.prefix?.range ?? NSRange(location: line.range.location, length: 0)
                replacements.append((range, prefixText(for: kind, number: index + 1)))
            }
        }
        return replacements
    }

    static func newlineEdit(in text: String, at location: Int)
        -> (range: NSRange, text: String, selection: NSRange)? {
        let split = Self.split(text)
        guard split.hasSeparator,
              let line = selectedLines(in: text, bodyStart: split.bodyStart,
                                        selection: NSRange(location: location, length: 0)).first,
              let prefix = line.prefix,
              location >= NSMaxRange(prefix.range) else { return nil }

        let value = text as NSString
        let remainderStart = NSMaxRange(prefix.range)
        let remainder = value.substring(with: NSRange(location: remainderStart,
                                                       length: NSMaxRange(line.range) - remainderStart))
        let replacementRange: NSRange
        let insertion: String
        if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
            replacementRange = line.range
            insertion = "\n"
        } else {
            replacementRange = NSRange(location: location, length: 0)
            let number = prefix.kind == .numbers ? nextNumber(in: text, line: line) : 0
            insertion = "\n" + prefixText(for: prefix.kind, number: number)
        }
        return (replacementRange, insertion,
                NSRange(location: replacementRange.location + insertion.utf16.count, length: 0))
    }

    private static func nextNumber(in text: String, line: WritingLine) -> Int {
        let value = text as NSString
        guard let prefix = line.prefix else { return 1 }
        let prefixText = value.substring(with: prefix.range) as NSString
        let digits = prefixText.substring(to: max(0, prefixText.length - 2))
        guard let number = Int(digits) else { return 1 }
        return number == Int.max ? Int.max : number + 1
    }

    static func adjustedSelection(_ selection: NSRange,
                                  replacements: [(range: NSRange, text: String)],
                                  textLength: Int) -> NSRange {
        func adjusted(_ offset: Int, includeAtOffset: Bool) -> Int {
            var result = offset
            for replacement in replacements where replacement.range.location < offset
                || includeAtOffset && replacement.range.location == offset {
                result += replacement.text.utf16.count - replacement.range.length
            }
            return max(0, min(result, textLength))
        }
        let collapsed = selection.length == 0
        let start = adjusted(selection.location, includeAtOffset: collapsed)
        let end = adjusted(NSMaxRange(selection), includeAtOffset: true)
        return NSRange(location: min(start, end), length: max(0, end - start))
    }

    fileprivate static func merged(_ spans: [NoteFormatting.Span]) -> [NoteFormatting.Span] {
        var result: [NoteFormatting.Span] = []
        for span in spans.sorted(by: { $0.location < $1.location }) where span.length > 0 {
            if let last = result.last, last.location + last.length >= span.location {
                result[result.count - 1].length = max(last.location + last.length,
                                                      span.location + span.length) - last.location
            } else {
                result.append(span)
            }
        }
        return result
    }
}

#if os(iOS)

private final class WritingUITextView: UITextView {
    var commandB: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(UIKeyCommand(input: "b", modifierFlags: .command,
                                     action: #selector(commandBPressed)))
        return commands
    }

    @objc private func commandBPressed() {
        commandB?()
    }

    override func paste(_ sender: Any?) {
        // The editor stores text plus explicit formatting spans, not attachments.
        // Prefer the clipboard's plain text representation so rich text keeps its
        // words while unsupported images/attachments are not inserted.
        guard let string = UIPasteboard.general.string else { return }
        insertText(string)
    }
}

private struct TaskWritingPlatformEditor: UIViewRepresentable {
    @Binding var content: TaskWriting
    let autofocus: Bool
    let editable: Bool
    let controller: TaskWritingEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: $content, controller: controller)
    }

    func makeUIView(context: Context) -> WritingUITextView {
        let textView = WritingUITextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.allowsEditingTextAttributes = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityIdentifier = "taskWritingEditor"
        textView.accessibilityLabel = "任务编辑器；第一段为标题，换行后为正文"
        textView.commandB = { [weak coordinator = context.coordinator] in coordinator?.perform(.bold) }
        context.coordinator.textView = textView
        controller.install(retaining: context.coordinator)
        context.coordinator.installInitial(content, autofocus: autofocus)
        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WritingUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1 else { return nil }
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }

    func updateUIView(_ textView: WritingUITextView, context: Context) {
        context.coordinator.update(binding: $content, editable: editable, autofocus: autofocus)
    }

    static func dismantleUIView(_ textView: WritingUITextView, coordinator: Coordinator) {
        coordinator.textView = nil
        coordinator.controller.detach()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var binding: Binding<TaskWriting>
        weak var textView: WritingUITextView?
        let controller: TaskWritingEditorController
        var lastPublishedContent: TaskWriting?
        var hasSeparatorAfterTitle = false
        var applyingExternal = false
        var internalEdit = false
        var isEditable = true
        var didAutofocus = false
        var refreshScheduled = false

        init(binding: Binding<TaskWriting>, controller: TaskWritingEditorController) {
            self.binding = binding
            self.controller = controller
        }

        func installInitial(_ value: TaskWriting, autofocus: Bool) {
            guard let textView else { return }
            isEditable = textView.isEditable
            lastPublishedContent = value
            hasSeparatorAfterTitle = !value.body.isEmpty && !value.title.isEmpty
            applyExternal(value, selectEnd: autofocus)
            if autofocus { focusIfNeeded() }
        }

        func update(binding: Binding<TaskWriting>, editable: Bool, autofocus: Bool) {
            self.binding = binding
            isEditable = editable
            textView?.isEditable = editable
            guard let textView else { return }
            let incoming = binding.wrappedValue
            if incoming != lastPublishedContent, !textView.isFirstResponder {
                let preserve = incoming.title == lastPublishedContent?.title
                    && incoming.body.isEmpty && lastPublishedContent?.body.isEmpty == true
                if !preserve { hasSeparatorAfterTitle = incoming.body.isEmpty ? false : true }
                applyExternal(incoming, selectEnd: true)
            }
            if autofocus && !didAutofocus { focusIfNeeded() }
            _ = textView
        }

        func perform(_ command: TaskWritingCommand) {
            guard isEditable, let textView, textView.markedTextRange == nil else { return }
            textView.becomeFirstResponder()
            publishCurrentContent()
            switch command {
            case .bold: toggleBold(textView)
            case .bullets: toggleList(textView, kind: .bullets)
            case .numbers: toggleList(textView, kind: .numbers)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !applyingExternal, !internalEdit, !refreshScheduled else { return }
            refreshScheduled = true
            // TextKit may still be updating the insertion point in this callback.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                guard let textView = self.textView, !self.applyingExternal else { return }
                if textView.markedTextRange == nil { self.applyStructuralStyles(textView) }
                self.publishCurrentContent()
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            publishCurrentContent()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            guard isEditable, !applyingExternal, !internalEdit,
                  text == "\n", range.length == 0,
                  textView.markedTextRange == nil else { return true }
            return handleNewline(textView, at: range.location)
        }

        private func focusIfNeeded() {
            guard !didAutofocus, isEditable, let textView else { return }
            didAutofocus = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.becomeFirstResponder()
                textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
            }
        }

        private func applyExternal(_ value: TaskWriting, selectEnd: Bool) {
            guard let textView else { return }
            let text = TaskWritingText.text(for: value, preservingSeparator: hasSeparatorAfterTitle)
            let split = TaskWritingText.split(text)
            let attributed = NSMutableAttributedString(string: text)
            applyBaseAttributes(to: attributed, split: split, formatting: value.formatting)
            applyingExternal = true
            textView.attributedText = attributed
            textView.typingAttributes = typingAttributes(for: textView, split: split,
                                                          at: selectEnd ? attributed.length : 0)
            if selectEnd {
                textView.selectedRange = NSRange(location: attributed.length, length: 0)
            } else {
                textView.selectedRange = NSRange(location: 0, length: 0)
            }
            applyingExternal = false
            lastPublishedContent = value
            hasSeparatorAfterTitle = split.hasSeparator
        }

        private func applyStructuralStyles(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            let storage = textView.textStorage
            let split = TaskWritingText.split(storage.string)
            let titleEnd = split.hasSeparator ? split.bodyStart : storage.length
            var changes: [(NSRange, Bool, Bool)] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                let pieces = [NSIntersectionRange(range, NSRange(location: 0, length: titleEnd)),
                              NSIntersectionRange(range, NSRange(location: titleEnd, length: storage.length - titleEnd))]
                for piece in pieces where piece.length > 0 {
                    let isTitle = piece.location < titleEnd
                    let bold = !isTitle && attributes[writingBoldAttribute] as? Bool == true
                    let font = isTitle ? titleFont() : (bold ? boldFont() : bodyFont())
                    if ((attributes[.font] as? UIFont).map { $0.isEqual(font) } != true) ||
                        (attributes[.paragraphStyle] as? NSParagraphStyle)?.isEqual(writingParagraphStyle(title: isTitle)) != true ||
                        isTitle && attributes[writingBoldAttribute] as? Bool == true {
                        changes.append((piece, isTitle, bold))
                    }
                }
            }
            // Avoid resetting the selection or rewriting unchanged attributes while
            // TextKit is finishing a keystroke/IME edit. That can move the caret.
            if !changes.isEmpty {
                storage.beginEditing()
                for (range, isTitle, bold) in changes {
                    storage.addAttributes([.font: isTitle ? titleFont() : (bold ? boldFont() : bodyFont()),
                                           writingBoldAttribute: bold, .foregroundColor: UIColor.label,
                                           .paragraphStyle: writingParagraphStyle(title: isTitle)], range: range)
                }
                storage.endEditing()
            }
            let body = split.hasSeparator && textView.selectedRange.location >= split.bodyStart
            let bold = body && textView.typingAttributes[writingBoldAttribute] as? Bool == true
            let font = body ? (bold ? boldFont() : bodyFont()) : titleFont()
            if (textView.typingAttributes[.font] as? UIFont).map({ $0.isEqual(font) }) != true {
                textView.typingAttributes = [.font: font, writingBoldAttribute: bold, .foregroundColor: UIColor.label, .paragraphStyle: writingParagraphStyle(title: !body)]
            }
        }

        private func applyBaseAttributes(to attributed: NSMutableAttributedString, split: WritingSplit,
                                         formatting: NoteFormatting?) {
            guard attributed.length > 0 else { return }
            let titleLength = split.hasSeparator ? split.separatorLocation! + 1 : attributed.length
            attributed.setAttributes([.font: titleFont(), .foregroundColor: UIColor.label, .paragraphStyle: writingParagraphStyle(title: true)],
                                     range: NSRange(location: 0, length: titleLength))
            guard split.hasSeparator else { return }
            let bodyRange = NSRange(location: split.bodyStart, length: attributed.length - split.bodyStart)
            attributed.setAttributes([.font: bodyFont(), .foregroundColor: UIColor.label, .paragraphStyle: writingParagraphStyle(title: false)], range: bodyRange)
            for span in formatting?.bold ?? [] {
                guard span.location >= 0, span.length > 0,
                      span.location <= split.body.utf16.count,
                      span.length <= split.body.utf16.count - span.location else { continue }
                attributed.addAttributes([.font: boldFont(), writingBoldAttribute: true],
                                        range: NSRange(location: split.bodyStart + span.location, length: span.length))
            }
        }

        private func publishCurrentContent() {
            guard let textView else { return }
            let text = textView.text ?? ""
            let split = TaskWritingText.split(text)
            let spans = boldSpans(in: textView, split: split)
            let value = TaskWriting(title: split.title, body: split.body,
                                    formatting: spans.isEmpty ? nil : NoteFormatting(bold: spans))
            hasSeparatorAfterTitle = split.hasSeparator
            lastPublishedContent = value
            if binding.wrappedValue != value { binding.wrappedValue = value }
        }

        private func toggleBold(_ textView: UITextView) {
            let split = TaskWritingText.split(textView.text ?? "")
            let selection = textView.selectedRange
            let bodyStart = split.bodyStart
            if selection.length == 0 {
                guard split.hasSeparator, selection.location >= bodyStart else { return }
                let bold = !isTypingBold(in: textView, split: split, location: selection.location)
                var attributes = textView.typingAttributes
                attributes[.font] = bold ? boldFont() : bodyFont()
                attributes[writingBoldAttribute] = bold
                textView.typingAttributes = attributes
                return
            }
            guard split.hasSeparator else { return }
            let selectionEnd = min(NSMaxRange(selection), textView.text.utf16.count)
            let start = max(selection.location, bodyStart)
            guard selectionEnd > start else { return }
            let bodySelection = NSRange(location: start, length: selectionEnd - start)
            let allBold = isBold(in: textView, range: bodySelection)
            let oldAttributes = textView.textStorage.attributedSubstring(from: bodySelection)
            textView.textStorage.beginEditing()
            textView.textStorage.addAttributes([.font: allBold ? bodyFont() : boldFont(), writingBoldAttribute: !allBold], range: bodySelection)
            textView.textStorage.endEditing()
            registerFormattingUndo(in: textView, range: bodySelection, oldAttributes: oldAttributes)
            textView.typingAttributes = typingAttributes(for: textView, split: split, at: selection.location)
            publishCurrentContent()
        }

        private func registerFormattingUndo(in textView: UITextView, range: NSRange,
                                            oldAttributes: NSAttributedString) {
            guard let undoManager = textView.undoManager else { return }
            undoManager.registerUndo(withTarget: self) { [weak textView] target in
                guard let textView else { return }
                target.restoreFormatting(in: textView, range: range, attributes: oldAttributes)
            }
            undoManager.setActionName("粗体")
        }

        private func restoreFormatting(in textView: UITextView, range: NSRange,
                                       attributes: NSAttributedString) {
            guard range.location >= 0, range.length == attributes.length,
                  NSMaxRange(range) <= textView.textStorage.length else { return }
            let current = textView.textStorage.attributedSubstring(from: range)
            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] target in
                guard let textView else { return }
                target.restoreFormatting(in: textView, range: range, attributes: current)
            }
            let selection = textView.selectedRange
            internalEdit = true
            attributes.enumerateAttributes(in: NSRange(location: 0, length: attributes.length)) { value, subrange, _ in
                textView.textStorage.setAttributes(value,
                                                    range: NSRange(location: range.location + subrange.location,
                                                                   length: subrange.length))
            }
            internalEdit = false
            applyStructuralStyles(textView)
            textView.selectedRange = selection
            publishCurrentContent()
        }

        private func toggleList(_ textView: UITextView, kind: WritingListKind) {
            let text = textView.text ?? ""
            let originalSelection = textView.selectedRange
            let replacements = TaskWritingText.listReplacements(in: text, selection: originalSelection, kind: kind)
            guard !replacements.isEmpty else { return }
            internalEdit = true
            for replacement in replacements.reversed() {
                replaceNative(replacement.range, with: replacement.text, in: textView)
            }
            internalEdit = false
            let newSelection = TaskWritingText.adjustedSelection(originalSelection,
                                                                  replacements: replacements,
                                                                  textLength: textView.text.utf16.count)
            textView.selectedRange = newSelection
            applyStructuralStyles(textView)
            publishCurrentContent()
        }

        private func handleNewline(_ textView: UITextView, at location: Int) -> Bool {
            let text = textView.text ?? ""
            guard let edit = TaskWritingText.newlineEdit(in: text, at: location) else { return true }
            internalEdit = true
            replaceNative(edit.range, with: edit.text, in: textView)
            internalEdit = false
            textView.selectedRange = edit.selection
            applyStructuralStyles(textView)
            publishCurrentContent()
            return false
        }

        private func replaceNative(_ range: NSRange, with replacement: String, in textView: UITextView) {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return }
            textView.replace(textRange, withText: replacement)
        }

        private func boldSpans(in textView: UITextView, split: WritingSplit) -> [NoteFormatting.Span] {
            guard split.hasSeparator, !split.body.isEmpty else { return [] }
            let range = NSRange(location: split.bodyStart, length: split.body.utf16.count)
            var spans: [NoteFormatting.Span] = []
            textView.textStorage.enumerateAttribute(writingBoldAttribute, in: range) { value, subrange, _ in
                guard value as? Bool == true else { return }
                spans.append(.init(location: subrange.location - split.bodyStart, length: subrange.length))
            }
            return TaskWritingText.merged(spans)
        }

        private func isBold(in textView: UITextView, range: NSRange) -> Bool {
            var allBold = range.length > 0
            textView.textStorage.enumerateAttribute(writingBoldAttribute, in: range) { value, _, _ in
                if value as? Bool != true { allBold = false }
            }
            return allBold
        }

        private func boldAtTextCaret(in textView: UITextView, split: WritingSplit, location: Int) -> Bool {
            guard split.hasSeparator, location > split.bodyStart else { return false }
            let index = min(location - 1, textView.textStorage.length - 1)
            return textView.textStorage.attribute(writingBoldAttribute, at: index, effectiveRange: nil) as? Bool == true
        }

        private func isTypingBold(in textView: UITextView, split: WritingSplit, location: Int) -> Bool {
            textView.typingAttributes[writingBoldAttribute] as? Bool == true
        }

        private func typingAttributes(for textView: UITextView, split: WritingSplit, at location: Int)
            -> [NSAttributedString.Key: Any] {
            let body = split.hasSeparator && location >= split.bodyStart
            let bold = body && boldAtTextCaret(in: textView, split: split, location: location)
            return [.font: bold ? boldFont() : (body ? bodyFont() : titleFont()),
                    writingBoldAttribute: bold, .foregroundColor: UIColor.label, .paragraphStyle: writingParagraphStyle(title: !body)]
        }

        private func titleFont() -> UIFont {
            let base = UIFont.systemFont(ofSize: 26, weight: .semibold)
            return UIFontMetrics(forTextStyle: .title2).scaledFont(for: base)
        }

        private func bodyFont() -> UIFont {
            UIFont.preferredFont(forTextStyle: .body)
        }

        private func boldFont() -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: .body)
            return UIFont.systemFont(ofSize: base.pointSize, weight: .bold)
        }
    }
}

#elseif os(macOS)

private final class WritingNSTextView: NSTextView {
    var commandB: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "b" {
            commandB?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        insertText(string, replacementRange: selectedRange())
    }
}

private final class WritingScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? WritingNSTextView else { return }
        let width = contentView.bounds.width
        guard width > 0 else { return }
        var frame = textView.frame
        let height = max(frame.height, contentView.bounds.height)
        if frame.width != width || frame.height != height {
            frame.size = NSSize(width: width, height: height)
            textView.frame = frame
        }
    }
}

private struct TaskWritingPlatformEditor: NSViewRepresentable {
    @Binding var content: TaskWriting
    let autofocus: Bool
    let editable: Bool
    let controller: TaskWritingEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: $content, controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = WritingNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)
        textView.identifier = NSUserInterfaceItemIdentifier("taskWritingEditor")
        textView.setAccessibilityIdentifier("taskWritingEditor")
        textView.setAccessibilityLabel("任务编辑器；第一段为标题，换行后为正文")
        textView.commandB = { [weak coordinator = context.coordinator] in coordinator?.perform(.bold) }

        let scrollView = WritingScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        textView.frame = NSRect(x: 0, y: 0, width: 1, height: 300)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        controller.install(retaining: context.coordinator)
        context.coordinator.installInitial(content, autofocus: autofocus)
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1,
              let textView = nsView.documentView as? WritingNSTextView else { return nil }
        // Measuring must not resize the live NSTextView: SwiftUI probes several
        // widths, and changing its frame here continuously invalidates layout.
        let inset = textView.textContainerInset
        let bounds = textView.attributedString().boundingRect(
            with: CGSize(width: max(1, width - inset.width * 2), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: ceil(max(44, bounds.height + inset.height * 2 + 2)))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(binding: $content, editable: editable, autofocus: autofocus)
        if let textView = scrollView.documentView as? WritingNSTextView {
            textView.isEditable = editable
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView = nil
        coordinator.controller.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<TaskWriting>
        weak var textView: WritingNSTextView?
        let controller: TaskWritingEditorController
        var lastPublishedContent: TaskWriting?
        var hasSeparatorAfterTitle = false
        var applyingExternal = false
        var internalEdit = false
        var isEditable = true
        var didAutofocus = false
        var refreshScheduled = false

        init(binding: Binding<TaskWriting>, controller: TaskWritingEditorController) {
            self.binding = binding
            self.controller = controller
        }

        func installInitial(_ value: TaskWriting, autofocus: Bool) {
            guard let textView else { return }
            isEditable = textView.isEditable
            lastPublishedContent = value
            hasSeparatorAfterTitle = !value.body.isEmpty && !value.title.isEmpty
            applyExternal(value, selectEnd: autofocus)
            if autofocus { focusIfNeeded() }
        }

        func update(binding: Binding<TaskWriting>, editable: Bool, autofocus: Bool) {
            self.binding = binding
            isEditable = editable
            textView?.isEditable = editable
            guard let textView else { return }
            let incoming = binding.wrappedValue
            if incoming != lastPublishedContent, textView.window?.firstResponder !== textView {
                let preserve = incoming.title == lastPublishedContent?.title
                    && incoming.body.isEmpty && lastPublishedContent?.body.isEmpty == true
                if !preserve { hasSeparatorAfterTitle = incoming.body.isEmpty ? false : true }
                applyExternal(incoming, selectEnd: true)
            }
            if autofocus && !didAutofocus { focusIfNeeded() }
            _ = textView
        }

        func perform(_ command: TaskWritingCommand) {
            guard isEditable, let textView, !textView.hasMarkedText() else { return }
            textView.window?.makeFirstResponder(textView)
            publishCurrentContent()
            switch command {
            case .bold: toggleBold(textView)
            case .bullets: toggleList(textView, kind: .bullets)
            case .numbers: toggleList(textView, kind: .numbers)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingExternal, !internalEdit, !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                guard let textView = self.textView, !self.applyingExternal else { return }
                if !textView.hasMarkedText() { self.applyStructuralStyles(textView) }
                self.publishCurrentContent()
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            publishCurrentContent()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard isEditable, !applyingExternal, !internalEdit,
                  replacementString == "\n", affectedCharRange.length == 0,
                  !textView.hasMarkedText() else { return true }
            return handleNewline(textView, at: affectedCharRange.location)
        }

        private func focusIfNeeded() {
            guard !didAutofocus, isEditable, let textView else { return }
            didAutofocus = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
            }
        }

        private func applyExternal(_ value: TaskWriting, selectEnd: Bool) {
            guard let textView else { return }
            let text = TaskWritingText.text(for: value, preservingSeparator: hasSeparatorAfterTitle)
            let split = TaskWritingText.split(text)
            let attributed = NSMutableAttributedString(string: text)
            applyBaseAttributes(to: attributed, split: split, formatting: value.formatting)
            applyingExternal = true
            textView.textStorage?.setAttributedString(attributed)
            if selectEnd {
                textView.setSelectedRange(NSRange(location: attributed.length, length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            textView.typingAttributes = typingAttributes(for: textView, split: split,
                                                          at: selectEnd ? attributed.length : 0)
            applyingExternal = false
            lastPublishedContent = value
            hasSeparatorAfterTitle = split.hasSeparator
        }

        private func applyStructuralStyles(_ textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            guard let storage = textView.textStorage else { return }
            let split = TaskWritingText.split(storage.string)
            let titleEnd = split.hasSeparator ? split.bodyStart : storage.length
            var changes: [(NSRange, Bool, Bool)] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                let pieces = [NSIntersectionRange(range, NSRange(location: 0, length: titleEnd)),
                              NSIntersectionRange(range, NSRange(location: titleEnd, length: storage.length - titleEnd))]
                for piece in pieces where piece.length > 0 {
                    let isTitle = piece.location < titleEnd
                    let bold = !isTitle && attributes[writingBoldAttribute] as? Bool == true
                    let font = isTitle ? titleFont() : (bold ? boldFont() : bodyFont())
                    if ((attributes[.font] as? NSFont).map { $0.isEqual(font) } != true) ||
                        (attributes[.paragraphStyle] as? NSParagraphStyle)?.isEqual(writingParagraphStyle(title: isTitle)) != true ||
                        isTitle && attributes[writingBoldAttribute] as? Bool == true {
                        changes.append((piece, isTitle, bold))
                    }
                }
            }
            // Avoid resetting the selection or rewriting unchanged attributes while
            // TextKit is finishing a keystroke/IME edit. That can move the caret.
            if !changes.isEmpty {
                storage.beginEditing()
                for (range, isTitle, bold) in changes {
                    storage.addAttributes([.font: isTitle ? titleFont() : (bold ? boldFont() : bodyFont()),
                                           writingBoldAttribute: bold, .foregroundColor: NSColor.labelColor,
                                           .paragraphStyle: writingParagraphStyle(title: isTitle)], range: range)
                }
                storage.endEditing()
            }
            let body = split.hasSeparator && textView.selectedRange().location >= split.bodyStart
            let bold = body && textView.typingAttributes[writingBoldAttribute] as? Bool == true
            let font = body ? (bold ? boldFont() : bodyFont()) : titleFont()
            if (textView.typingAttributes[.font] as? NSFont).map({ $0.isEqual(font) }) != true {
                textView.typingAttributes = [.font: font, writingBoldAttribute: bold, .foregroundColor: NSColor.labelColor, .paragraphStyle: writingParagraphStyle(title: !body)]
            }
        }

        private func applyBaseAttributes(to attributed: NSMutableAttributedString, split: WritingSplit,
                                         formatting: NoteFormatting?) {
            guard attributed.length > 0 else { return }
            let titleLength = split.hasSeparator ? split.separatorLocation! + 1 : attributed.length
            attributed.setAttributes([.font: titleFont(), .foregroundColor: NSColor.labelColor, .paragraphStyle: writingParagraphStyle(title: true)],
                                     range: NSRange(location: 0, length: titleLength))
            guard split.hasSeparator else { return }
            let bodyRange = NSRange(location: split.bodyStart, length: attributed.length - split.bodyStart)
            attributed.setAttributes([.font: bodyFont(), .foregroundColor: NSColor.labelColor, .paragraphStyle: writingParagraphStyle(title: false)], range: bodyRange)
            for span in formatting?.bold ?? [] {
                guard span.location >= 0, span.length > 0,
                      span.location <= split.body.utf16.count,
                      span.length <= split.body.utf16.count - span.location else { continue }
                attributed.addAttributes([.font: boldFont(), writingBoldAttribute: true],
                                        range: NSRange(location: split.bodyStart + span.location, length: span.length))
            }
        }

        private func publishCurrentContent() {
            guard let textView, let storage = textView.textStorage else { return }
            let split = TaskWritingText.split(storage.string)
            let spans = boldSpans(in: textView, split: split)
            let value = TaskWriting(title: split.title, body: split.body,
                                    formatting: spans.isEmpty ? nil : NoteFormatting(bold: spans))
            hasSeparatorAfterTitle = split.hasSeparator
            lastPublishedContent = value
            if binding.wrappedValue != value { binding.wrappedValue = value }
        }

        private func toggleBold(_ textView: NSTextView) {
            let split = TaskWritingText.split(textView.string)
            let selection = textView.selectedRange()
            let bodyStart = split.bodyStart
            if selection.length == 0 {
                guard split.hasSeparator, selection.location >= bodyStart else { return }
                let bold = !isTypingBold(in: textView, split: split, location: selection.location)
                var attributes = textView.typingAttributes
                attributes[.font] = bold ? boldFont() : bodyFont()
                attributes[writingBoldAttribute] = bold
                textView.typingAttributes = attributes
                return
            }
            guard split.hasSeparator, let storage = textView.textStorage else { return }
            let selectionEnd = min(NSMaxRange(selection), storage.length)
            let start = max(selection.location, bodyStart)
            guard selectionEnd > start else { return }
            let bodySelection = NSRange(location: start, length: selectionEnd - start)
            let allBold = isBold(in: textView, range: bodySelection)
            let oldAttributes = storage.attributedSubstring(from: bodySelection)
            storage.beginEditing()
            storage.addAttributes([.font: allBold ? bodyFont() : boldFont(), writingBoldAttribute: !allBold], range: bodySelection)
            storage.endEditing()
            registerFormattingUndo(in: textView, range: bodySelection, oldAttributes: oldAttributes)
            textView.typingAttributes = typingAttributes(for: textView, split: split, at: selection.location)
            publishCurrentContent()
        }

        private func registerFormattingUndo(in textView: NSTextView, range: NSRange,
                                            oldAttributes: NSAttributedString) {
            guard let undoManager = textView.undoManager else { return }
            undoManager.registerUndo(withTarget: self) { [weak textView] target in
                guard let textView else { return }
                target.restoreFormatting(in: textView, range: range, attributes: oldAttributes)
            }
            undoManager.setActionName("粗体")
        }

        private func restoreFormatting(in textView: NSTextView, range: NSRange,
                                       attributes: NSAttributedString) {
            guard let storage = textView.textStorage,
                  range.location >= 0, range.length == attributes.length,
                  NSMaxRange(range) <= storage.length else { return }
            let current = storage.attributedSubstring(from: range)
            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] target in
                guard let textView else { return }
                target.restoreFormatting(in: textView, range: range, attributes: current)
            }
            let selection = textView.selectedRange()
            internalEdit = true
            attributes.enumerateAttributes(in: NSRange(location: 0, length: attributes.length)) { value, subrange, _ in
                storage.setAttributes(value,
                                      range: NSRange(location: range.location + subrange.location,
                                                     length: subrange.length))
            }
            internalEdit = false
            applyStructuralStyles(textView)
            textView.setSelectedRange(selection)
            publishCurrentContent()
        }

        private func toggleList(_ textView: NSTextView, kind: WritingListKind) {
            guard let storage = textView.textStorage else { return }
            let text = storage.string
            let originalSelection = textView.selectedRange()
            let replacements = TaskWritingText.listReplacements(in: text, selection: originalSelection, kind: kind)
            guard !replacements.isEmpty else { return }
            internalEdit = true
            for replacement in replacements.reversed() {
                textView.insertText(replacement.text, replacementRange: replacement.range)
            }
            internalEdit = false
            let newSelection = TaskWritingText.adjustedSelection(originalSelection,
                                                                  replacements: replacements,
                                                                  textLength: textView.textStorage?.length ?? 0)
            textView.setSelectedRange(newSelection)
            applyStructuralStyles(textView)
            publishCurrentContent()
        }

        private func handleNewline(_ textView: NSTextView, at location: Int) -> Bool {
            let text = textView.string
            guard let edit = TaskWritingText.newlineEdit(in: text, at: location) else { return true }
            internalEdit = true
            textView.insertText(edit.text, replacementRange: edit.range)
            internalEdit = false
            textView.setSelectedRange(edit.selection)
            applyStructuralStyles(textView)
            publishCurrentContent()
            return false
        }

        private func boldSpans(in textView: NSTextView, split: WritingSplit) -> [NoteFormatting.Span] {
            guard split.hasSeparator, !split.body.isEmpty, let storage = textView.textStorage else { return [] }
            let range = NSRange(location: split.bodyStart, length: split.body.utf16.count)
            var spans: [NoteFormatting.Span] = []
            storage.enumerateAttribute(writingBoldAttribute, in: range) { value, subrange, _ in
                guard value as? Bool == true else { return }
                spans.append(.init(location: subrange.location - split.bodyStart, length: subrange.length))
            }
            return TaskWritingText.merged(spans)
        }

        private func isBold(in textView: NSTextView, range: NSRange) -> Bool {
            guard let storage = textView.textStorage else { return false }
            var allBold = range.length > 0
            storage.enumerateAttribute(writingBoldAttribute, in: range) { value, _, _ in
                if value as? Bool != true { allBold = false }
            }
            return allBold
        }

        private func boldAtTextCaret(in textView: NSTextView, split: WritingSplit, location: Int) -> Bool {
            guard split.hasSeparator, location > split.bodyStart, let storage = textView.textStorage else { return false }
            let index = min(location - 1, storage.length - 1)
            return storage.attribute(writingBoldAttribute, at: index, effectiveRange: nil) as? Bool == true
        }

        private func isTypingBold(in textView: NSTextView, split: WritingSplit, location: Int) -> Bool {
            textView.typingAttributes[writingBoldAttribute] as? Bool == true
        }

        private func typingAttributes(for textView: NSTextView, split: WritingSplit, at location: Int)
            -> [NSAttributedString.Key: Any] {
            let body = split.hasSeparator && location >= split.bodyStart
            let bold = body && boldAtTextCaret(in: textView, split: split, location: location)
            return [.font: bold ? boldFont() : (body ? bodyFont() : titleFont()),
                    writingBoldAttribute: bold, .foregroundColor: NSColor.labelColor, .paragraphStyle: writingParagraphStyle(title: !body)]
        }

        private func titleFont() -> NSFont {
            NSFont.systemFont(ofSize: 18, weight: .semibold)
        }

        private func bodyFont() -> NSFont {
            NSFont.systemFont(ofSize: 14, weight: .regular)
        }

        private func boldFont() -> NSFont {
            NSFont.systemFont(ofSize: 14, weight: .bold)
        }
    }
}

#endif
