import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import AccountContext
import TelegramPresentationData
import SecutgCore

/// SECUTG: the illustrated encryption guide (PLAN.md 3.15). Four fixed chapters, each a run of steps, each step one
/// whole phone screen drawn by `SecutgPhoneScreenView` from the shared layout arithmetic. The content is the
/// generated `SecutgGuideData`, parsed once on first use; every interface string goes through `SecutgL10n`, so the
/// guide follows the Telegram in-app language like the rest of the plugin.
public final class SecutgGuideController: ViewController {
    /// Parsed on the first open and kept for the rest of the process (PLAN.md 3.15 rule 2).
    static let guide: SecutgGuide? = try? SecutgGuide.parse(json: SecutgGuideData.json)

    private let presentationData: PresentationData
    private let initialChapterId: String?

    private var chapterIndex: Int = -1
    private var stepIndex: Int = 0

    private let scroll = UIScrollView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let ledeLabel = UILabel()
    private var chapterRows: [SecutgGuideChapterRow] = []

    private let crumbLabel = UILabel()
    private let phoneView = SecutgPhoneScreenView()
    private let stepTitleLabel = UILabel()
    private let stepBodyLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)

    public init(context: AccountContext, initialChapterId: String? = nil) {
        SecutgChatMenu.syncLanguage(context: context)
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.initialChapterId = initialChapterId
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
        if let id = initialChapterId, let index = SecutgGuideController.guide?.chapters.firstIndex(where: { $0.id == id }) {
            self.chapterIndex = index
        }
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var theme: PresentationTheme { return presentationData.theme }
    private var lang: String { return SecutgL10n.currentLang.rawValue }

    public override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = theme.list.blocksBackgroundColor
        self.displayNodeDidLoad()
        let view = self.displayNode.view

        titleLabel.text = SecutgL10n.string("SecutgGuideTitle")
        titleLabel.font = UIFont.boldSystemFont(ofSize: 20.0)
        titleLabel.textColor = theme.list.itemPrimaryTextColor
        closeButton.setTitle(SecutgL10n.string("SecutgClose"), for: .normal)
        closeButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(scroll)

        ledeLabel.text = SecutgL10n.string("SecutgGuideChapters")
        ledeLabel.font = UIFont.systemFont(ofSize: 14.0)
        ledeLabel.textColor = theme.list.itemSecondaryTextColor
        ledeLabel.numberOfLines = 0
        scroll.addSubview(ledeLabel)

        for (index, chapter) in (SecutgGuideController.guide?.chapters ?? []).enumerated() {
            let row = SecutgGuideChapterRow(
                icon: chapter.icon,
                title: SecutgPhoneLayout.pick(chapter.title, lang),
                summary: SecutgPhoneLayout.pick(chapter.summary, lang),
                theme: theme
            )
            row.tag = index
            row.addTarget(self, action: #selector(chapterTapped(_:)), for: .touchUpInside)
            chapterRows.append(row)
            scroll.addSubview(row)
        }

        crumbLabel.font = UIFont.systemFont(ofSize: 13.0)
        crumbLabel.textColor = theme.list.itemSecondaryTextColor
        crumbLabel.numberOfLines = 0
        stepTitleLabel.font = UIFont.boldSystemFont(ofSize: 17.0)
        stepTitleLabel.textColor = theme.list.itemPrimaryTextColor
        stepTitleLabel.numberOfLines = 0
        stepBodyLabel.font = UIFont.systemFont(ofSize: 15.0)
        stepBodyLabel.textColor = theme.list.itemPrimaryTextColor
        stepBodyLabel.numberOfLines = 0
        for label in [crumbLabel, stepTitleLabel, stepBodyLabel] { scroll.addSubview(label) }
        scroll.addSubview(phoneView)

        for (button, action) in [(backButton, #selector(backTapped)), (nextButton, #selector(nextTapped))] {
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.setTitleColor(theme.list.itemAccentColor, for: .normal)
            button.addTarget(self, action: action, for: .touchUpInside)
            scroll.addSubview(button)
        }

        applyState()
    }

    // MARK: state

    private var chapter: SecutgGuideChapter? {
        guard let chapters = SecutgGuideController.guide?.chapters, chapterIndex >= 0, chapterIndex < chapters.count else { return nil }
        return chapters[chapterIndex]
    }

    private var step: SecutgGuideStep? {
        guard let chapter = chapter, stepIndex >= 0, stepIndex < chapter.steps.count else { return nil }
        return chapter.steps[stepIndex]
    }

    private var isLastStep: Bool {
        guard let chapter = chapter, let chapters = SecutgGuideController.guide?.chapters else { return true }
        return stepIndex + 1 == chapter.steps.count && chapterIndex + 1 == chapters.count
    }

    private func applyState() {
        guard isNodeLoaded else { return }
        let showingStep = step != nil
        ledeLabel.isHidden = showingStep
        for row in chapterRows { row.isHidden = showingStep }
        for view in [crumbLabel, phoneView, stepTitleLabel, stepBodyLabel, backButton, nextButton] as [UIView] {
            view.isHidden = !showingStep
        }
        if let chapter = chapter, let step = step {
            crumbLabel.text = SecutgPhoneLayout.pick(chapter.title, lang)
                + " · "
                + SecutgL10n.string("SecutgGuideStepOf", ["index": "\(stepIndex + 1)", "total": "\(chapter.steps.count)"])
            stepTitleLabel.text = SecutgPhoneLayout.pick(step.title, lang)
            stepBodyLabel.text = SecutgPhoneLayout.pick(step.body, lang)
            phoneView.update(scene: step.scene, lang: lang, inputPlaceholder: SecutgL10n.string("SecutgGuideInputHint"), theme: theme)
            backButton.setTitle(SecutgL10n.string("SecutgGuideBack"), for: .normal)
            nextButton.setTitle(SecutgL10n.string(isLastStep ? "SecutgGuideDone" : "SecutgGuideNext"), for: .normal)
        }
        if let layout = currentLayout {
            containerLayoutUpdated(layout, transition: .immediate)
        }
    }

    private var currentLayout: ContainerViewLayout?

    @objc private func chapterTapped(_ sender: UIControl) {
        chapterIndex = sender.tag
        stepIndex = 0
        scroll.setContentOffset(.zero, animated: false)
        applyState()
    }

    @objc private func backTapped() {
        if stepIndex > 0 {
            stepIndex -= 1
        } else {
            chapterIndex = -1
        }
        scroll.setContentOffset(.zero, animated: false)
        applyState()
    }

    @objc private func nextTapped() {
        guard let chapter = chapter, let chapters = SecutgGuideController.guide?.chapters else { return }
        if stepIndex + 1 < chapter.steps.count {
            stepIndex += 1
        } else if chapterIndex + 1 < chapters.count {
            chapterIndex += 1
            stepIndex = 0
        } else {
            dismiss()
            return
        }
        scroll.setContentOffset(.zero, animated: false)
        applyState()
    }

    @objc private func closeTapped() {
        dismiss()
    }

    // MARK: layout

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.currentLayout = layout
        let inset: CGFloat = 20.0
        let width = layout.size.width - inset * 2.0
        let top = layout.safeInsets.top + 20.0
        closeButton.frame = CGRect(x: layout.size.width - inset - 80.0, y: top, width: 80.0, height: 32.0)
        titleLabel.frame = CGRect(x: inset, y: top, width: width - 88.0, height: 32.0)
        let scrollTop = top + 44.0
        let availableHeight = max(0.0, layout.size.height - scrollTop - layout.intrinsicInsets.bottom)
        scroll.frame = CGRect(x: 0.0, y: scrollTop, width: layout.size.width, height: max(0.0, layout.size.height - scrollTop))

        var y: CGFloat = 8.0
        func place(_ view: UIView, height: CGFloat? = nil, gap: CGFloat = 14.0) {
            let fitted = height ?? view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            view.frame = CGRect(x: inset, y: y, width: width, height: fitted)
            y += fitted + gap
        }

        if let step = step {
            // PLAN.md 3.15 #4: this step must fit `availableHeight` with no scrolling. `SecutgGuideFit` (in
            // SecutgCore) decides how much compression that needs; this view only measures its own labels
            // with real fonts and applies whatever the decision comes back with.
            let fit = SecutgGuideController.stepFit(
                basePhoneHeight: SecutgGuideController.basePhoneHeight(layout: layout, width: width),
                availableHeight: availableHeight,
                bodyHeight: { fontScale, lineHeightScale in
                    self.stepBodyLabel.attributedText = SecutgGuideController.attributedBody(
                        SecutgPhoneLayout.pick(step.body, self.lang), fontScale: fontScale,
                        lineHeightScale: lineHeightScale, color: self.theme.list.itemPrimaryTextColor)
                    return self.stepBodyLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
                },
                crumbHeight: crumbLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height,
                titleHeight: stepTitleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            )
            // The measuring closure above already left `stepBodyLabel.attributedText` at the last probed
            // scale; set it once more at the chosen scale so what is measured is exactly what is drawn.
            stepBodyLabel.attributedText = SecutgGuideController.attributedBody(
                SecutgPhoneLayout.pick(step.body, lang), fontScale: fit.bodyFontScale,
                lineHeightScale: fit.lineHeightScale, color: theme.list.itemPrimaryTextColor)

            place(crumbLabel, gap: 10.0 * fit.gapScale)
            place(phoneView, height: fit.phoneHeight, gap: 16.0 * fit.gapScale)
            place(stepTitleLabel, gap: 8.0 * fit.gapScale)
            place(stepBodyLabel, gap: 20.0 * fit.gapScale)
            let buttonWidth = (width - 12.0) / 2.0
            backButton.frame = CGRect(x: inset, y: y, width: buttonWidth, height: 46.0)
            nextButton.frame = CGRect(x: inset + buttonWidth + 12.0, y: y, width: buttonWidth, height: 46.0)
            y += 46.0
        } else {
            place(ledeLabel, gap: 12.0)
            for row in chapterRows {
                place(row, height: row.height(forWidth: width), gap: 10.0)
            }
        }
        scroll.contentSize = CGSize(width: layout.size.width, height: y + layout.intrinsicInsets.bottom + 28.0)
    }

    // MARK: PLAN.md 3.15 #4 — fitting a step onto one screen

    /// The phone illustration's height before any compression: the same cap the guide has always used, now
    /// also the ceiling `SecutgGuideFit` compresses down from.
    private static func basePhoneHeight(layout: ContainerViewLayout, width: CGFloat) -> CGFloat {
        return min(layout.size.height * 0.52, width * (SecutgPhoneScreenView.designSize.height / SecutgPhoneScreenView.designSize.width))
    }

    private static func attributedBody(_ text: String, fontScale: CGFloat, lineHeightScale: CGFloat, color: UIColor) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = lineHeightScale
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 15.0 * fontScale),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ])
    }

    private struct StepFit {
        let gapScale: CGFloat
        let lineHeightScale: CGFloat
        let phoneHeight: CGFloat
        let bodyFontScale: CGFloat
    }

    /// Ties the real, per-instance UIKit measurements to `SecutgGuideFit`'s pure decision. `bodyHeight`
    /// measures `stepBodyLabel` at a given (fontScale, lineHeightScale) — the only two knobs that change the
    /// body's height — and is called at most a handful of times, never on a hot path (this only runs on
    /// layout, not on every frame).
    private static func stepFit(
        basePhoneHeight: CGFloat, availableHeight: CGFloat,
        bodyHeight: (_ fontScale: CGFloat, _ lineHeightScale: CGFloat) -> CGFloat,
        crumbHeight: CGFloat, titleHeight: CGFloat
    ) -> StepFit {
        let gaps: CGFloat = 8.0 + 10.0 + 16.0 + 8.0 + 20.0 // initial + crumb + phone + title + body gaps
        let fixed = crumbHeight + titleHeight + 46.0 // labels that never shrink, plus the fixed button row
        let tight = SecutgGuideFit.style(for: .tightSpacing)

        let bodyAtNormal = bodyHeight(1.0, 1.0)
        let bodyAtTight = bodyHeight(1.0, CGFloat(tight.lineHeightScale))
        let bodyAtSmallest = bodyHeight(CGFloat(SecutgGuideFit.minimumBodyFontScale), CGFloat(tight.lineHeightScale))
        let minPhoneHeight = basePhoneHeight * CGFloat(SecutgGuideFit.minimumPhoneScale)

        func total(gapScale: Double, phoneHeight: CGFloat, bodyHeight: CGFloat) -> Double {
            return Double(fixed + gaps * CGFloat(gapScale) + phoneHeight + bodyHeight)
        }

        let level = SecutgGuideFit.level(availableHeight: Double(availableHeight)) { level in
            switch level {
            case .normal:
                return total(gapScale: 1.0, phoneHeight: basePhoneHeight, bodyHeight: bodyAtNormal)
            case .tightSpacing:
                return total(gapScale: tight.gapScale, phoneHeight: basePhoneHeight, bodyHeight: bodyAtTight)
            case .scaledPhone:
                return total(gapScale: tight.gapScale, phoneHeight: minPhoneHeight, bodyHeight: bodyAtTight)
            case .smallerBody:
                return total(gapScale: tight.gapScale, phoneHeight: minPhoneHeight, bodyHeight: bodyAtSmallest)
            }
        }

        let style = SecutgGuideFit.style(for: level)
        let gapScale = CGFloat(style.gapScale)
        let lineHeightScale = CGFloat(style.lineHeightScale)

        switch level {
        case .normal, .tightSpacing:
            return StepFit(gapScale: gapScale, lineHeightScale: lineHeightScale, phoneHeight: basePhoneHeight, bodyFontScale: 1.0)
        case .scaledPhone:
            let roomForPhone = availableHeight - fixed - gaps * gapScale - bodyAtTight
            let scale = SecutgGuideFit.fitScale(available: Double(roomForPhone), minimumScale: SecutgGuideFit.minimumPhoneScale) { s in
                Double(basePhoneHeight) * s
            }
            return StepFit(gapScale: gapScale, lineHeightScale: lineHeightScale, phoneHeight: basePhoneHeight * CGFloat(scale), bodyFontScale: 1.0)
        case .smallerBody:
            let roomForBody = availableHeight - fixed - gaps * gapScale - minPhoneHeight
            let scale = SecutgGuideFit.fitScale(available: Double(roomForBody), minimumScale: SecutgGuideFit.minimumBodyFontScale) { s in
                Double(bodyHeight(CGFloat(s), lineHeightScale))
            }
            return StepFit(gapScale: gapScale, lineHeightScale: lineHeightScale, phoneHeight: minPhoneHeight, bodyFontScale: CGFloat(scale))
        }
    }
}

/// One chapter in the list: the icon the content file carries, the chapter title and its one-line summary.
final class SecutgGuideChapterRow: UIControl {
    private let iconLabel = UILabel()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()

    init(icon: String, title: String, summary: String, theme: PresentationTheme) {
        super.init(frame: .zero)
        backgroundColor = theme.list.itemBlocksBackgroundColor
        layer.cornerRadius = 10.0
        layer.masksToBounds = true
        iconLabel.text = icon
        iconLabel.font = UIFont.systemFont(ofSize: 22.0)
        iconLabel.textAlignment = .center
        titleLabel.text = title
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16.0)
        titleLabel.textColor = theme.list.itemPrimaryTextColor
        titleLabel.numberOfLines = 0
        summaryLabel.text = summary
        summaryLabel.font = UIFont.systemFont(ofSize: 13.0)
        summaryLabel.textColor = theme.list.itemSecondaryTextColor
        summaryLabel.numberOfLines = 0
        for label in [iconLabel, titleLabel, summaryLabel] {
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static let iconWidth: CGFloat = 40.0
    private static let padding: CGFloat = 12.0

    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = width - SecutgGuideChapterRow.iconWidth - SecutgGuideChapterRow.padding * 2.0
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let summaryHeight = summaryLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        return max(56.0, titleHeight + summaryHeight + 6.0 + SecutgGuideChapterRow.padding * 2.0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let padding = SecutgGuideChapterRow.padding
        let textX = SecutgGuideChapterRow.iconWidth + padding
        let textWidth = bounds.width - textX - padding
        iconLabel.frame = CGRect(x: padding * 0.5, y: padding, width: SecutgGuideChapterRow.iconWidth - padding * 0.5, height: 28.0)
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        titleLabel.frame = CGRect(x: textX, y: padding, width: textWidth, height: titleHeight)
        let summaryHeight = summaryLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        summaryLabel.frame = CGRect(x: textX, y: titleLabel.frame.maxY + 6.0, width: textWidth, height: summaryHeight)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1.0 }
    }
}
