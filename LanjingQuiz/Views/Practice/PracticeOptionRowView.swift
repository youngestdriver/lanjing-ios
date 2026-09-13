import SwiftUI

/// Stateless option row for practice questions (OptionRowView is bound to the
/// exam QuizViewModel, so the styling is ported here). Empty option slots
/// (填空) render as a gray non-tappable placeholder, keeping the answer
/// letters aligned with the original slots. State comes from the session's
/// per-question `answers` — after the data-layer fix the wrongly-tapped
/// option is in `selected`, so it can be marked red (问题 2).
/// 翻页手势标记:横向翻页成立期间置位,选项行据此忽略这一摸。
///
/// 刻意用**引用类型**而不是 `@State Bool`:它在一次手势里会被反复赋值,若是
/// 被观察的状态,每次赋值都要重渲染整页(观感发卡)并连带刷新选项行样式;而
/// 它只在「抬手那一刻」被读一次,不需要驱动任何渲染。`generation` 用来防止
/// 上一次手势的落定回调把新手势的标记误清(连续快速翻页时会发生)。
final class PagingFlag {
    private(set) var isActive = false
    private(set) var generation = 0

    /// 手势成立(每次 onChanged 都会调,只有第一次推进代号)。
    func activate() {
        if !isActive { generation += 1 }
        isActive = true
    }

    /// 手势落定:期间没有新手势开始才清位。
    func settle(_ token: Int) {
        guard token == generation else { return }
        isActive = false
    }
}

struct PracticeOptionRowView: View {
    let question: BankQuestion
    let letter: String
    /// Current question's per-question state; nil = 未作答.
    let answer: PracticeSession.PracticeAnswer?
    /// 翻页手势标记:手势成立期间这一摸不该算点击(见 body 里的守卫)。
    let paging: PagingFlag
    let onTap: () -> Void

    private var optionText: String? {
        let idx = question.letters.firstIndex(of: letter) ?? 0
        guard idx < question.options.count else { return nil }
        return question.options[idx]
    }

    private var isEmptySlot: Bool {
        guard let text = optionText else { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isCorrect: Bool {
        question.keys[question.letters.firstIndex(of: letter) ?? 0]
    }

    private var isAnswered: Bool { answer?.revealed ?? false }
    private var isSelected: Bool { answer?.selected.contains(letter) ?? false }

    /// nil while pending or after a 无答案 reveal (correct == nil) — the row
    /// then falls back to the selected/unselected styling below.
    private var resultMark: QuizLogic.OptionResult? {
        guard isAnswered, answer?.correct != nil else { return nil }
        return BankLogic.optionResult(isAnswered: true, isSelected: isSelected, isCorrect: isCorrect)
    }

    private var background: Color {
        switch resultMark {
        case .correct: return DS.accent.opacity(0.12)
        case .wrong: return DS.red.opacity(0.12) // 问题 2: 选错的选项标红
        case nil: break
        }
        // Covers both "多选未提交的 pending" and "无答案题已选" — keycap
        // distinguishes them (answered → gray key).
        if isSelected { return DS.blue.opacity(0.12) }
        return Color(.secondarySystemBackground)
    }

    private var borderColor: Color {
        switch resultMark {
        case .correct: return DS.accent
        case .wrong: return DS.red
        case nil: break
        }
        if isSelected { return DS.blue }
        return Color(.systemGray4)
    }

    /// Accessibility handle for UI tests: wrong-answered rows get
    /// "option-<letter>-wrong", selected rows "option-<letter>-selected".
    /// The Button's accessible label stays the keycap letter ("A"), so
    /// existing app.buttons["A"]-style lookups are unaffected.
    private var accessibilityID: String {
        if isAnswered, resultMark == .wrong { return "option-\(letter)-wrong" }
        if isSelected { return "option-\(letter)-selected" }
        return ""
    }

    var body: some View {
        // 翻页手势成立时这一摸不算点击:翻页在松手时才切页,抬手那一刻手指
        // 下已经是新页的选项,不拦就会误选。只忽略动作、**不改任何样式**——
        // 早先用 .disabled(isPaging) 会让选项在每次翻页时整片变灰。
        Button {
            guard !paging.isActive else { return }
            onTap()
        } label: {
            // 居中对齐,单行选项的文字才在框里垂直居中(顶对齐会把它顶到框
            // 上部:实测墨迹上 15.3pt / 下 25.3pt);多行时字母块落在文字块
            // 中间。选项里的独立图块也左对齐,和文字选项一致。
            HStack(alignment: .center, spacing: 12) {
                keycap
                if isEmptySlot {
                    Text("（填空）")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                } else if let optionText {
                    RichHTMLContent(
                        html: optionText,
                        fontSize: 16,
                        allowsTextSelection: false,
                        imageAlignment: .leading
                    )
                    .id("\(question.id)-option-\(letter)")
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(borderColor, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
        }
        .buttonStyle(.plain)
        .disabled(isAnswered || isEmptySlot)
        // Default state: identifier = the keycap letter itself. The UI tests
        // look the option up by letter — with native text rendering the
        // button label is "A, <选项文字>" now, so matching can't rely on the
        // label (XCUI identifier query falls back to label, which used to be
        // exactly "A" back when the row content lived in a WKWebView).
        // Answered states keep their verdict ids ("option-B-wrong").
        .accessibilityIdentifier(accessibilityID.isEmpty ? letter : accessibilityID)
    }

    private var keycap: some View {
        Group {
            if isAnswered {
                if let resultMark {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(resultMark == .correct ? DS.accent : DS.red)
                            .frame(width: 30, height: 30)
                        Image(systemName: resultMark == .correct ? "checkmark" : "xmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                } else {
                    // 无答案题已作答: gray key, no verdict mark.
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 30, height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(.systemGray4), lineWidth: 2)
                            )
                        Text(letter)
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Color(.systemGray))
                    }
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(background)
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 2))
                    Text(letter)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(borderColor)
                }
            }
        }
    }
}
