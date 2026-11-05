import Combine
import SwiftUI

struct UISBWARootView: View {

    @AppStorage("isEnabled", store: UISBWAUserDefaults.standard)
    var isEnabled = false

    @AppStorage("isFiveColumnsEnabled", store: UISBWAUserDefaults.standard)
    var isFiveColumnsEnabled = false

    // iOS 17 兼容性诊断：由 tweak 侧写入（SpringBoard），这里只负责显示
    @AppStorage("omiStatus", store: UISBWAUserDefaults.standard)
    var omiStatus = "等待 SpringBoard 写入诊断信息（请 respring 后重新打开本页）"

    @AppStorage("omiMissing", store: UISBWAUserDefaults.standard)
    var omiMissing = ""

    @AppStorage("compactLeadingInset", store: UISBWAUserDefaults.standard)
    var compactLeadingInset: Double = 0
    let minimumCompactLeadingInset: Double = 0
    let maximumCompactLeadingInset: Double = 100
    let compactLeadingInsetStep: Double = 0.1

    @AppStorage("compactTrailingInset", store: UISBWAUserDefaults.standard)
    var compactTrailingInset: Double = 0
    let minimumCompactTrailingInset: Double = 0
    let maximumCompactTrailingInset: Double = 100
    let compactTrailingInsetStep: Double = 0.1

    @AppStorage("expandedLeadingInset", store: UISBWAUserDefaults.standard)
    var expandedLeadingInset: Double = 0
    let minimumExpandedLeadingInset: Double = 0
    let maximumExpandedLeadingInset: Double = 100
    let expandedLeadingInsetStep: Double = 0.1

    @AppStorage("expandedTrailingInset", store: UISBWAUserDefaults.standard)
    var expandedTrailingInset: Double = 0
    let minimumExpandedTrailingInset: Double = 0
    let maximumExpandedTrailingInset: Double = 100
    let expandedTrailingInsetStep: Double = 0.1

    @State var isFadingOut = false
    @State var isPresentingResetPrompt = false

    private let scrollViewSubject: CurrentValueSubject<UIScrollView?, Never>
    private let feedbackGenerator: UINotificationFeedbackGenerator = UINotificationFeedbackGenerator()

    init(scrollViewSubject: CurrentValueSubject<UIScrollView?, Never>) {
        self.scrollViewSubject = scrollViewSubject
    }

    var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Oh My Insets", bundle: Bundle.uisbwa_support, comment: ""))
                    .font(.system(size: 42))
                    .fontWeight(.bold)
                    .foregroundColor(UISBWA_COLOR)

                Text(String(format: NSLocalizedString("v%@ - @Lessica", bundle: Bundle.uisbwa_support, comment: ""), Bundle.uisbwa_packageVersion))
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
        }
        .listRowBackground(Color.clear)
    }

    var generalSection: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                LabelWithImageIcon(NSLocalizedString("Enable Oh My Insets", bundle: Bundle.uisbwa_support, comment: ""), systemImage: "power")
                    .foregroundColor(UISBWA_COLOR)
            }
            .toggleStyle(SwitchToggleStyle(tint: UISBWA_COLOR))

            Toggle(isOn: $isFiveColumnsEnabled) {
                LabelWithImageIcon(NSLocalizedString("Enable Five Columns", bundle: Bundle.uisbwa_support, comment: ""), systemImage: "5.circle")
                    .foregroundColor(UISBWA_COLOR)
            }
            .toggleStyle(SwitchToggleStyle(tint: UISBWA_COLOR))
        } header: {
            Text(NSLocalizedString("General", bundle: Bundle.uisbwa_support, comment: ""))
        }
    }

    // 兼容性诊断：ok = 该组 hook 已安装；no = 当前系统的私有类/方法不存在，已自动跳过（不会进安全模式）
    var diagnosticSection: some View {
        Section {
            Text(omiStatus)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            if !omiMissing.isEmpty {
                Text(omiMissing)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("兼容性诊断 / iOS 17")
        } footer: {
            Text("ok 表示该功能组的 hook 已成功安装；no 表示当前系统缺少对应私有类或方法，已自动跳过以保护 SpringBoard。")
        }
    }

    var compactLeadingInsetSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    compactLeadingInset = max(minimumCompactLeadingInset, compactLeadingInset - compactLeadingInsetStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(UISBWA_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $compactLeadingInset, in: minimumCompactLeadingInset...maximumCompactLeadingInset, step: compactLeadingInsetStep)
                Button {
                    compactLeadingInset = min(maximumCompactLeadingInset, compactLeadingInset + compactLeadingInsetStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(UISBWA_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Compact Leading Inset", bundle: Bundle.uisbwa_support, comment: ""))
                Spacer()
                Text(String(format: "%.1f pt", compactLeadingInset))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var compactTrailingInsetSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    compactTrailingInset = max(minimumCompactTrailingInset, compactTrailingInset - compactTrailingInsetStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(UISBWA_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $compactTrailingInset, in: minimumCompactTrailingInset...maximumCompactTrailingInset, step: compactTrailingInsetStep)
                Button {
                    compactTrailingInset = min(maximumCompactTrailingInset, compactTrailingInset + compactTrailingInsetStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(UISBWA_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Compact Trailing Inset", bundle: Bundle.uisbwa_support, comment: ""))
                Spacer()
                Text(String(format: "%.1f pt", compactTrailingInset))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var expandedLeadingInsetSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    expandedLeadingInset = max(minimumExpandedLeadingInset, expandedLeadingInset - expandedLeadingInsetStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(UISBWA_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $expandedLeadingInset, in: minimumExpandedLeadingInset...maximumExpandedLeadingInset, step: expandedLeadingInsetStep)
                Button {
                    expandedLeadingInset = min(maximumExpandedLeadingInset, expandedLeadingInset + expandedLeadingInsetStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(UISBWA_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Expanded Leading Inset", bundle: Bundle.uisbwa_support, comment: ""))
                Spacer()
                Text(String(format: "%.1f pt", expandedLeadingInset))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var expandedTrailingInsetSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    expandedTrailingInset = max(minimumExpandedTrailingInset, expandedTrailingInset - expandedTrailingInsetStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(UISBWA_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $expandedTrailingInset, in: minimumExpandedTrailingInset...maximumExpandedTrailingInset, step: expandedTrailingInsetStep)
                Button {
                    expandedTrailingInset = min(maximumExpandedTrailingInset, expandedTrailingInset + expandedTrailingInsetStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(UISBWA_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Expanded Trailing Inset", bundle: Bundle.uisbwa_support, comment: ""))
                Spacer()
                Text(String(format: "%.1f pt", expandedTrailingInset))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var resetSection: some View {
        Section {
            Button {
                withAnimation(.linear(duration: 0.5)) {
                    isFadingOut = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    Bundle.uisbwa_respring(withSnapshot: true, restartRenderServer: true)
                }
            } label: {
                Label(NSLocalizedString("Respring", bundle: Bundle.uisbwa_support, comment: ""), systemImage: "timelapse")
                    .foregroundColor(UISBWA_COLOR)
            }
            Button(role: .destructive) {
                isPresentingResetPrompt = true
            } label: {
                Label(NSLocalizedString("Reset to Default", bundle: Bundle.uisbwa_support, comment: ""), systemImage: "arrow.counterclockwise")
                    .foregroundColor(UISBWA_COLOR)
            }
        }
    }

    var resetPrompt: Alert {
        Alert(
            title: Text(NSLocalizedString("Reset to Default", bundle: Bundle.uisbwa_support, comment: "")),
            message: Text(NSLocalizedString("Are you sure you want to reset all settings to their default values?", bundle: Bundle.uisbwa_support, comment: "")),
            primaryButton: .cancel(),
            secondaryButton: .destructive(Text(NSLocalizedString("Reset", bundle: Bundle.uisbwa_support, comment: ""))) {
                withAnimation {
                    UISBWAUserDefaults.standard.resetToDefaultValues()
                }
            }
        )
    }

    var supportSection: some View {
        Section {
            Button {
                Bundle.uisbwa_openSensitiveURL(URL(string: "https://havoc.app/search/82Flex")!)
            } label: {
                Text(NSLocalizedString("Made with ♥ by OwnGoal Studio", bundle: Bundle.uisbwa_support, comment: ""))
            }
        } footer: {
            Text(NSLocalizedString("Please support our paid works, thank you!", bundle: Bundle.uisbwa_support, comment: ""))
        }
    }

    var content: some View {
        Form {
            header
            generalSection
            diagnosticSection
            compactLeadingInsetSection
            compactTrailingInsetSection
            expandedLeadingInsetSection
            expandedTrailingInsetSection
            resetSection
            supportSection
        }
        .tint(UISBWA_COLOR)
        .transition(.opacity)
        .listStyle(.insetGrouped)
        .alert(isPresented: $isPresentingResetPrompt) { resetPrompt }
        .introspect(.list, on: .iOS(.v13, .v14, .v15)) {
            scrollViewSubject.send($0)
        }
        .introspect(.list, on: .iOS(.v16, .v17, .v18)) {
            scrollViewSubject.send($0)
        }
    }

    var body: some View {
        ZStack {
            content

            if isFadingOut {
                Color.clear
                    .background(.thinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
    }
}
