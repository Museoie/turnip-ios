import SwiftUI

/// Clip List's filters (`docs/UIUX.md` § "Clip List", `ClipFilter`), in a sheet over the grid, which
/// changes behind it as they do: a confidence slider, and the colour of the top the person in a
/// clip wears — read from clips picked here, or chosen in the colour picker. The count along the
/// bottom says how many clips are left. "Reset" clears both; "Done" closes the sheet.
///
/// While it is up, and only then, it reads the clips' shirt colours
/// (`ClipListViewModel.readTorsoColors()`). A reading can hide a clip, so none lands once the
/// sheet has gone: Name Clips, pushed from the grid, never has a clip vanish under it.
struct ClipFilterSheet: View {
    @ObservedObject var viewModel: ClipListViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    confidenceSection
                    shirtColorSection
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { shownCount }
            .navigationTitle("Filter Clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { withAnimation { viewModel.clearFilter() } }
                        .disabled(!viewModel.filter.isActive)
                        .accessibilityIdentifier("clip-filter-reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("clip-filter-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await viewModel.readTorsoColors() }
    }

    // MARK: - Confidence

    private var confidenceSection: some View {
        let setting = ClipListAccessibility.minimumConfidence(viewModel.filter.minimumConfidence)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Confidence")
                    .font(.headline)
                Spacer()
                Text(setting)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // The slider reads its name and setting itself.
            .accessibilityHidden(true)
            Slider(value: $viewModel.filter.minimumConfidence, in: 0...1) {
                Text("Confidence")
            } minimumValueLabel: {
                Text("Any")
            } maximumValueLabel: {
                Text("Surest")
            }
            .accessibilityValue(setting)
            .accessibilityIdentifier("clip-filter-confidence")
            Text("Hides the clips detection is least sure are tricks, like someone walking off.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shirt color

    private var shirtColorSection: some View {
        let total = viewModel.filterableClips.count
        let read = viewModel.readTorsoColorCount
        let shown = Set(viewModel.clipsToName.map(\.id))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shirt Color")
                    .font(.headline)
                Spacer()
                if viewModel.filter.shirtColor != nil {
                    Button("Any Color") { withAnimation { viewModel.clearShirtColor() } }
                        .font(.subheadline)
                        .accessibilityIdentifier("clip-filter-any-color")
                }
            }
            ColorPicker(selection: pickedColor, supportsOpacity: false) {
                viewModel.filter.shirtColor == nil ? Text("Choose a color") : Text("Color")
            }
            .accessibilityIdentifier("clip-filter-color")
            Text("Or tap clips of the person to keep: the color of their top is read from them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if read < total {
                ProgressView(value: Double(read), total: Double(total)) {
                    Text(ClipListAccessibility.readingShirtColors(read: read, total: total))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(viewModel.filterableClips) { item in
                    ShirtColorClipTile(item: item, viewModel: viewModel, isShown: shown.contains(item.id))
                }
            }
        }
    }

    /// The colour picker shows the shirt colour, or mid-grey before there is one; what it hands
    /// back is picked by hand.
    private var pickedColor: Binding<CGColor> {
        Binding(
            get: { viewModel.filter.shirtColor?.color.cgColor ?? Self.unpickedColor },
            set: { color in
                let shown = viewModel.filter.shirtColor?.color.cgColor ?? Self.unpickedColor
                withAnimation { viewModel.pickShirtColor(color, shown: shown) }
            })
    }

    private static let unpickedColor = CGColor(gray: 0.5, alpha: 1)

    // MARK: - Count

    private var shownCount: some View {
        Text(ClipListAccessibility.shownClips(shown: viewModel.clipsToName.count, total: viewModel.allClips.count))
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.bar)
            .accessibilityIdentifier("clip-filter-shown-count")
    }
}

/// One clip in the filter sheet's picker: its poster, with a swatch of its person's top once that
/// has been read. A tap picks it as one of the user's clips, or takes it back
/// (`ClipListViewModel.toggleShirtColorSource(_:)`), reading it first if it hasn't been. A clip the
/// filters hide is dimmed, so one of the user's own that the colour leaves out stands out to tap.
private struct ShirtColorClipTile: View {
    let item: ClipListItem
    @ObservedObject var viewModel: ClipListViewModel
    let isShown: Bool
    @State private var thumbnail: CGImage?
    /// From a tap until the pick lands. The pick runs in `.task(id:)`, so the sheet going away
    /// cancels it and no reading lands after it.
    @State private var isToggling = false

    private static let cornerRadius: CGFloat = 8

    var body: some View {
        let reading = viewModel.torsoColors[item.id]
        let isPicked = viewModel.isShirtColorSource(item.id)
        let isUnreadable = reading != nil && reading?.color == nil
        Button { isToggling = true } label: {
            Color.secondary.opacity(0.2)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: isPicked ? 3 : 0)
                }
                .overlay(alignment: .bottomLeading) {
                    swatch(reading)
                        .padding(5)
                }
                .overlay(alignment: .topTrailing) {
                    if isPicked {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.accentColor)
                            .padding(5)
                    }
                }
                .overlay {
                    if isToggling && reading == nil { ProgressView() }
                }
                .opacity(isShown ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isToggling || isUnreadable)
        .accessibilityLabel(ClipListAccessibility.shirtColorClipLabel(
            spokenDuration: ClipDurationFormatter.accessibilityString(
                from: item.window.endTime - item.window.startTime),
            isUnreadable: isUnreadable))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityHint("Keeps the clips of whoever wears this clip's top")
        .task(id: item.id) {
            thumbnail = viewModel.cachedThumbnail(for: item)
            if thumbnail == nil {
                thumbnail = await viewModel.thumbnail(for: item)
            }
        }
        .task(id: isToggling) {
            guard isToggling else { return }
            await viewModel.toggleShirtColorSource(item)
            isToggling = false
        }
    }

    @ViewBuilder
    private func swatch(_ reading: TorsoColorReading?) -> some View {
        if let color = reading?.color {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .frame(width: 18, height: 18)
                .overlay { Circle().strokeBorder(Color.white, lineWidth: 2) }
        } else if reading != nil {
            Image(systemName: "questionmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.black.opacity(0.5))
        }
    }
}
