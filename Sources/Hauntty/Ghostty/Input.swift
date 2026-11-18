// Adapted from Ghostty's macOS app (MIT license):
// macos/Sources/Ghostty/Ghostty.Input.swift and NSEvent+Extension.swift.

import AppKit
import GhosttyKit

enum GhosttyInput {
    /// Translate AppKit modifier flags to Ghostty mods, including sided mods.
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// Mods for mouse events, with cmd sent as ctrl. Mouse reports have no
    /// bit for cmd, so a cmd-click would reach tmux and the program in the
    /// pane as a plain click. As a ctrl-click, programs such as Neovim can
    /// map it, for example to open the link under the pointer.
    static func mouseMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = mods(flags).rawValue
        guard raw & GHOSTTY_MODS_SUPER.rawValue != 0 else { return ghostty_input_mods_e(raw) }
        raw &= ~(GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SUPER_RIGHT.rawValue)
        raw |= GHOSTTY_MODS_CTRL.rawValue
        return ghostty_input_mods_e(raw)
    }

    /// Translate Ghostty mods back to AppKit modifier flags.
    static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Pack scroll precision and momentum the way ghostty_input_scroll_mods_t
    /// expects: bit 0 is precision, bits 1 to 3 are the momentum phase.
    static func scrollMods(precision: Bool, momentum: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = precision ? 1 : 0
        value |= Int32(momentumPhase(momentum).rawValue) << 1
        return ghostty_input_scroll_mods_t(value)
    }

    private static func momentumPhase(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began: return GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: return GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: return GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: return GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: return GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: return GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }

    static func mouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_EIGHT // Back
        case 4: return GHOSTTY_MOUSE_NINE // Forward
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }
}

extension NSEvent {
    /// A Ghostty key event without text. The caller sets `text` for the
    /// lifetime of the call, since it is a C string.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var event = ghostty_input_key_s()
        event.action = action
        event.keycode = UInt32(keyCode)
        event.text = nil
        event.composing = false

        // Control and command never contribute to the text, so assume every
        // other modifier was consumed by translation.
        event.mods = GhosttyInput.mods(modifierFlags)
        event.consumed_mods = GhosttyInput.mods(
            (translationMods ?? modifierFlags).subtracting([.control, .command]))

        event.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            event.unshifted_codepoint = scalar.value
        }
        return event
    }

    /// The text to send with a key event. Ghostty encodes control characters
    /// itself, and function keys arrive as private use characters that must
    /// not be sent.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}

extension String {
    /// Text for a key event, or nil when it is empty or starts with an ASCII
    /// control character, which Ghostty encodes from the key itself.
    var keyEventText: String? {
        guard let first = unicodeScalars.first, first.value >= 0x20, first.value != 0x7F else {
            return nil
        }
        return self
    }
}
