import AppKit
import SwiftUI

/// Native field-editor behavior preserves selection, clipboard shortcuts, and input methods.
struct NativeAddressField: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let focusToken: UUID
  let onSubmit: () -> Void
  let onMove: (Int) -> Void
  let onEscape: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> AddressTextField {
    let field = AddressTextField()
    field.isEditable = true
    field.isSelectable = true
    field.isEnabled = true
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.placeholderString = "Search or enter website name"
    field.lineBreakMode = .byTruncatingMiddle
    field.cell?.usesSingleLineMode = true
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.delegate = context.coordinator
    field.onFocus = { context.coordinator.parent.isFocused = true }
    field.setAccessibilityLabel("Address and search")
    return field
  }
  func updateNSView(_ field: AddressTextField, context: Context) {
    context.coordinator.parent = self
    field.wantsFocus = isFocused
    field.alignment = isFocused ? .left : .center
    // Never replace the field editor while it is composing marked text.
    if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = text
    }
    let requestsFocus = isFocused && context.coordinator.lastFocusToken != focusToken
    context.coordinator.lastFocusToken = focusToken
    if requestsFocus || (isFocused && field.currentEditor() == nil) {
      field.focusEditor()
    } else if !isFocused && field.currentEditor() != nil {
      field.window?.makeFirstResponder(nil)
    }
  }

  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: NativeAddressField
    var lastFocusToken: UUID?
    init(_ parent: NativeAddressField) { self.parent = parent }
    func controlTextDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) { parent.isFocused = false }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
      // Let the input method commit a composition before handling navigation keys.
      guard !textView.hasMarkedText() else { return false }
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.moveDown(_:)):
        parent.onMove(1)
        return true
      case #selector(NSResponder.moveUp(_:)):
        parent.onMove(-1)
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onEscape()
        return true
      default: return false
      }
    }
  }
}

final class AddressTextField: NSTextField {
  var wantsFocus = false
  var onFocus: (() -> Void)?
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if wantsFocus { focusEditor() }
  }
  func focusEditor() {
    guard let window else { return }
    window.makeFirstResponder(self)
    if let editor = currentEditor() {
      editor.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
    }
  }
  override func mouseDown(with event: NSEvent) {
    let wasEditing = currentEditor() != nil
    if !wasEditing {
      wantsFocus = true
      onFocus?()
      focusEditor()
    }
    super.mouseDown(with: event)
  }
}
