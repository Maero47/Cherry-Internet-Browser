//
//  SetupExtensionsStep.swift
//  Cherry Browser
//
//  The wizard's fifth step: the three extensions that were actually watched
//  doing their job inside Cherry's own WebKit runtime, offered to a user who
//  has not browsed once yet.
//
//  The list is `ExtensionShortlist.entries` and nothing else. Not a subset,
//  not a curated re-ordering, not a copy with nicer names — the shortlist is a
//  record of what passed live verification, and a wizard holding its own list
//  beside it is a second source of truth that goes stale the first time an
//  entry is pulled. `SetupExtensionStepTests` fails if this step ever renders
//  a row the shortlist does not have, or misses one it does.
//
//  CAVEATS ARE THE POINT OF THIS SCREEN, not a footnote on it. Every entry
//  that declares one shows it in its own row, before the tick, in the same
//  words the shortlist uses — and again beside the result after it installs.
//  uBO Lite is why: it needs about ninety seconds to warm up, during which
//  ads still come through. A first-run user who ticks an ad blocker, presses
//  Start Browsing and immediately sees ads has been handed a broken browser
//  unless somebody told them first. This screen is where they are told.
//

import SwiftUI

struct SetupExtensionsStep: View {
    @State private var installer: SetupExtensionInstaller

    /// `nil` means the real one — the shortlist, a real download and the
    /// app's `ExtensionManager`. The parameter exists so a test can hand in an
    /// installer that has already been driven (mid-install, finished with
    /// outcomes) and read what this step then puts on screen, without a
    /// network round trip. (`nil` rather than a default-constructed default
    /// argument: default arguments are evaluated outside the main actor, and
    /// the installer is main-actor state.)
    init(installer: SetupExtensionInstaller? = nil) {
        _installer = State(initialValue: installer ?? SetupExtensionInstaller())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupStepHeader(
                step: .extensions,
                title: "Add what you need",
                subtitle: "A short list, each one loaded into Cherry and watched doing its job. Nothing is added unless you tick it."
            )

            SettingsCard(
                icon: "puzzlepiece.extension",
                title: "Recommended Extensions",
                subtitle: "Cherry downloads the exact version it verified, straight from the publisher."
            ) {
                ForEach(rows) { row in row }
            }

            installControls

            if !installer.outcomes.isEmpty {
                SetupExtensionOutcomeList(outcomes: installer.outcomes)
            }
        }
    }

    /// The offered rows, MATERIALIZED as values rather than produced inside a
    /// `ForEach` builder closure.
    ///
    /// This is what makes "the step offers exactly the verified shortlist"
    /// checkable without rendering pixels: a closure is opaque to `Mirror`, an
    /// array of row values is not. `SetupExtensionStepTests` reads this list
    /// straight out of the built body and compares it to
    /// `ExtensionShortlist.entries`.
    private var rows: [SetupExtensionRow] {
        installer.entries.map { entry in
            SetupExtensionRow(
                entry: entry,
                isSelected: installer.isSelected(entry),
                isEnabled: !installer.isInstalling,
                toggle: { installer.toggle(entry) }
            )
        }
    }

    @ViewBuilder
    private var installControls: some View {
        HStack(spacing: 10) {
            switch installer.phase {
            case .choosing:
                Text(installer.hasSelection
                     ? "Cherry will download and install what you ticked."
                     : "Nothing ticked — Continue skips this step. You can add these any time from Settings ▸ Extensions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case let .installing(name):
                ProgressView()
                    .controlSize(.small)
                Text("Installing \(name)…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

            case .finished:
                Text("Done. Change any of this later in Settings ▸ Extensions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(installer.outcomes.isEmpty ? "Install Selected" : "Install Again") {
                Task { await installer.installSelected() }
            }
            .disabled(!installer.hasSelection || installer.isInstalling)
        }
    }
}

// MARK: - One offered extension

/// One shortlist row. A named, identifiable view value, so a test can walk the
/// step's value tree and read back exactly which entries were offered — the
/// list this step shows is a claim worth pinning, and `Text` produced inside a
/// `ForEach` closure is not readable.
struct SetupExtensionRow: View, Identifiable {
    let entry: ExtensionShortlistEntry
    let isSelected: Bool
    let isEnabled: Bool
    let toggle: () -> Void

    var id: String { entry.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in toggle() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isEnabled)
            .accessibilityLabel("Install \(entry.displayName)")

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry.verifiedVersion)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text(entry.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let caveat = entry.caveat {
                    SetupExtensionCaveat(text: caveat)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { toggle() } }
    }
}

/// The warning line under an entry, in the shortlist's own words.
///
/// Deliberately plain and always open — no disclosure triangle, no "learn
/// more". The whole reason this text exists is that the user will otherwise
/// misread the extension's first ninety seconds as it being broken, and a
/// warning behind a click is a warning nobody read.
struct SetupExtensionCaveat: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        // Just the sentence, with the warning glyph named. The same view is
        // used before the tick and again beside the result, so any framing
        // ("before you install…") would be wrong in one of the two places.
        .accessibilityLabel("Worth knowing: \(text)")
    }
}

// MARK: - What happened

/// The result of pressing Install: one line per chosen extension, and — for
/// anything that declared a caveat — that same caveat repeated, now as "what
/// to expect". The repetition is intentional: the sentence is most useful in
/// the seconds AFTER the install, which is when the user goes looking at a
/// page and sees the thing they just installed apparently not working.
struct SetupExtensionOutcomeList: View {
    let outcomes: [SetupExtensionInstaller.Outcome]

    /// Materialized for the same reason the offered rows are — so what the
    /// user is told after installing is readable from the value tree.
    private var rows: [SetupExtensionOutcomeRow] {
        outcomes.map(SetupExtensionOutcomeRow.init(outcome:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in row }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }
}

struct SetupExtensionOutcomeRow: View, Identifiable {
    let outcome: SetupExtensionInstaller.Outcome

    var id: String { outcome.entryID }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(outcome.succeeded ? Color.green : Color.red)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.succeeded
                     ? "\(outcome.displayName) installed"
                     : "\(outcome.displayName) couldn't be installed")
                    .font(.system(size: 12, weight: .medium))

                if let failure = outcome.failure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The same sentence the row showed before the tick, now as
                // "what to expect" — see the type comment above.
                if let caveat = outcome.caveat {
                    SetupExtensionCaveat(text: caveat)
                }
            }
        }
    }
}
