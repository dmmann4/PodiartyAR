//
//  AppForm.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/14/26.
//


//
//  FormComponents.swift
//  The 3D Formula
//
//  A small design system of form building blocks that stay on-brand:
//  they use `appBackground` / `appSurface` for structure and the brand
//  teal/lime only as accents (focus states, toggles, primary actions),
//  so forms stay legible first and "branded" second.
//
//  Components:
//   - AppForm            container: background + scroll + section spacing
//   - AppFormSection     a card-style section with header/footer, like
//                        grouped UITableView but using our own palette
//   - AppFormRow         a single label+content row inside a section
//   - AppTextField       styled text input
//   - AppSecureField     styled secure input
//   - AppToggleRow       row with trailing brand-colored toggle
//   - AppPickerRow       row that navigates to a picker / detail
//   - AppFormButton      primary / secondary / destructive button styles
//
//
import SwiftUI

// MARK: - AppForm

/// Top-level scrollable container for a themed form. Applies the app
/// background and consistent spacing between sections.
struct AppForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.vertical, 20)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - AppFormSection

/// A grouped, card-style section with an optional header and footer.
/// Uses `appSurface` for the card and `appLabelSecondary` for the
/// header/footer so it stays legible in both light and dark mode.
struct AppFormSection<Content: View>: View {
    let header: String?
    let footer: String?
    let content: Content

    init(
        header: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header.uppercased())
                    .font(AppFont.caption)
                    .tracking(0.6)
                    .foregroundColor(.brandSecondary)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 0) {
                content
            }
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.appDivider, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
            .padding(.horizontal, 20)

            if let footer {
                Text(footer)
                    .font(AppFont.caption)
                    .foregroundColor(.brandSecondary)
                    .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - AppFormRow

/// A single row inside an `AppFormSection`: leading label, flexible
/// trailing content, and an automatically-inserted divider between rows
/// when used via the `.formRows { }` helper below.
struct AppFormRow<Trailing: View>: View {
    let label: String
    let icon: String?
    let trailing: Trailing

    init(
        _ label: String,
        icon: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.label = label
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.brandTeal)
                    .frame(width: 22)
            }

            Text(label)
                .font(AppFont.body)
                .foregroundColor(.brandTeal)

            Spacer(minLength: 12)

            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Helper that lays out multiple rows with a divider (using `appDivider`)
/// automatically inserted between them.
struct FormRowGroup<Data: RandomAccessCollection, RowContent: View>: View where Data.Element: Identifiable {
    let data: Data
    let rowContent: (Data.Element) -> RowContent

    init(_ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) {
        self.data = data
        self.rowContent = rowContent
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, element in
                rowContent(element)
                if index < data.count - 1 {
                    Divider()
                        .overlay(Color.appDivider)
                        .padding(.leading, 16)
                }
            }
        }
    }
}

// MARK: - AppTextField

/// A themed text field: legible placeholder color, a subtle border that
/// switches to brand teal on focus, and consistent internal padding.
struct AppTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var icon: String? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(AppFont.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundColor(isFocused ? .brandTeal : .brandTealLight)
                        .font(.system(size: 15))
                }

                TextField(placeholder, text: $text)
                    .font(AppFont.body)
                    .foregroundColor(.primary)
                    .keyboardType(keyboardType)
                    .focused($isFocused)
                    .tint(.brandTeal)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? Color.brandTeal : Color.appDivider, lineWidth: isFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

// MARK: - AppSecureField

struct AppSecureField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    @FocusState private var isFocused: Bool
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(AppFont.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundColor(isFocused ? .brandTeal : .brandTealLight)
                    .font(.system(size: 13))

                Group {
                    if isRevealed {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .font(AppFont.body)
                .foregroundColor(.brandTeal)
                .focused($isFocused)
                .tint(.brandTeal)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                        .foregroundColor(.brandSecondary)
                        .font(.system(size: 14))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.appBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? Color.brandTeal : Color.appDivider, lineWidth: isFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

// MARK: - AppToggleRow

struct AppToggleRow: View {
    let label: String
    let icon: String?
    @Binding var isOn: Bool

    init(_ label: String, icon: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.icon = icon
        self._isOn = isOn
    }

    var body: some View {
        AppFormRow(label, icon: icon) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.brandTeal)
        }
    }
}

// MARK: - AppPickerRow

/// A tappable row that shows a current value and a chevron — for
/// navigating to a picker, detail screen, etc.
struct AppPickerRow: View {
    let label: String
    let value: String
    let icon: String?
    let action: () -> Void

    init(_ label: String, value: String, icon: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.value = value
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            AppFormRow(label, icon: icon) {
                HStack(spacing: 6) {
                    Text(value)
                        .font(AppFont.body)
                        .foregroundColor(.brandSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.brandSecondary.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AppFormButton

enum AppFormButtonStyle {
    case primary        // filled, brand teal gradient
    case secondary       // outlined, brand teal
    case destructive     // filled, brandError

    var background: AnyShapeStyle {
        switch self {
        case .primary: return AnyShapeStyle(Color.brandTealGradient)
        case .secondary: return AnyShapeStyle(Color.clear)
        case .destructive: return AnyShapeStyle(Color.red)
        }
    }

    var foreground: Color {
        switch self {
        case .primary, .destructive: return .white
        case .secondary: return .brandTeal
        }
    }

    var borderColor: Color? {
        self == .secondary ? .brandTeal : nil
    }
}

extension AppFormButtonStyle: Equatable {}

struct AppFormButton: View {
    let title: String
    let style: AppFormButtonStyle
    let isLoading: Bool
    let action: () -> Void

    init(
        _ title: String,
        style: AppFormButtonStyle = .primary,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(style.foreground)
                } else {
                    Text(title)
                        .font(AppFont.button)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundColor(style.foreground)
            .background(style.background)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(style.borderColor ?? .clear, lineWidth: 1.5)
            )
        }
        .disabled(isLoading)
        .padding(.horizontal, 20)
    }
}

// MARK: - Preview / usage example

private struct FormComponentsPreview: View {
    struct Row: Identifiable { let id = UUID(); let label: String }

    @State private var patientName = ""
    @State private var password = ""
    @State private var notifyOnComplete = true
    @State private var urgentCase = false

    var body: some View {
        AppForm {
            AppFormSection(header: "Patient Details", footer: "Used to label the print job and patient record.") {
                VStack(spacing: 0) {
                    AppTextField(title: "Full Name", placeholder: "e.g. Jordan Lee", text: $patientName, icon: "person.fill")
                        .padding(16)
                    Divider().overlay(Color.appDivider).padding(.leading, 16)
                    AppSecureField(title: "Access Code", placeholder: "Required for sensitive scans", text: $password)
                        .padding(16)
                }
            }

            AppFormSection(header: "Print Settings") {
                FormRowGroup([Row(label: "1"), Row(label: "2")]) { row in
                    if row.label == "1" {
                        AppToggleRow("Notify when complete", icon: "bell.fill", isOn: $notifyOnComplete)
                    } else {
                        AppToggleRow("Mark as urgent", icon: "exclamationmark.triangle.fill", isOn: $urgentCase)
                    }
                }
            }

            AppFormSection(header: "Material") {
                AppPickerRow("Resin Type", value: "Surgical Guide Clear", icon: "cylinder.fill") {}
            }

            VStack(spacing: 12) {
                AppFormButton("Submit Print Job", style: .primary) {}
                AppFormButton("Save as Draft", style: .secondary) {}
                AppFormButton("Delete Job", style: .destructive) {}
            }
        }
    }
}

#Preview {
    FormComponentsPreview()
}
