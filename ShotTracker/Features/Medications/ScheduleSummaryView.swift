import Atelier
import SwiftUI

/// "How this schedule works": one short paragraph per topic (`ScheduleSummary`).
struct ScheduleSummaryView: View {
    let summary: ScheduleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
            ForEach(summary.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(line.text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier(AccessibilityID.scheduleSummary)
    }
}

/// The confirmation step of saving a new or changed schedule: what the schedule will do,
/// then Save or Keep Editing.
struct ScheduleConfirmationView: View {
    let name: String
    let summary: ScheduleSummary
    let onSave: () -> Void
    let onKeepEditing: () -> Void

    var body: some View {
        List {
            Section {
                ScheduleSummaryView(summary: summary)
                    .padding(.vertical, Theme.Spacing.s1)
            } header: {
                Text(String(localized: "How this schedule works", comment: "Confirmation: the summary's heading"))
            } footer: {
                Text(String(localized: "You can change any of this later in Edit.", comment: "Confirmation footer"))
            }
        }
        .navigationTitle(name.isEmpty ? String(localized: "Review Schedule", comment: "Confirmation title") : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Keep Editing", comment: "Confirmation: back to the form"), action: onKeepEditing)
                    .accessibilityIdentifier(AccessibilityID.keepEditingButton)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save", comment: "Confirmation: save the schedule"), action: onSave)
                    .accessibilityIdentifier(AccessibilityID.confirmSaveMedicationButton)
            }
        }
    }
}
