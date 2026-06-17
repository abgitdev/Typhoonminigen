import Foundation

/// Outcome line shown under the Models / LoRA / System actions. Errors used to render in
/// the same gray as successes ("Download error: …" looked like routine status) — the flag
/// lets the views paint failures red.
struct ActionMessage: Equatable, Sendable {
    let text: String
    let isError: Bool

    static func ok(_ text: String) -> ActionMessage { .init(text: text, isError: false) }
    static func error(_ text: String) -> ActionMessage { .init(text: text, isError: true) }
}
