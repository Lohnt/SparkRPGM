import SwiftUI
import UIKit

private enum LibraryRoute: Identifiable {
    case rename(Game)
    case lineColor(Game)
    case customizeLauncher

    var id: String {
        switch self {
        case .rename(let game): return "rename-\(game.folderName)"
        case .lineColor(let game): return "line-color-\(game.folderName)"
        case .customizeLauncher: return "customize-launcher"
        }
    }
}

private struct LibraryAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct LibraryView: View {

    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var coordinator: ImportCoordinator
    @EnvironmentObject private var launcher: LauncherSettingsStore

    @State private var searchText = ""
    @State private var engineFilter: GameEngine?
    @State private var route: LibraryRoute?
    @State private var selectedGame: Game?

    @State private var coverTarget: Game?
    @State private var showCoverSourceDialog = false

    @State private var deleteTarget: Game?
    @State private var showDeleteDialog = false

    @State private var alert: LibraryAlert?

    private var accent: Color { launcher.settings.accentColor }

    var body: some View {
        NavigationView {
            ZStack {
                LauncherBackground(launcher: launcher, coverURL: ambientCoverURL)

                RefreshableScrollView(onRefresh: { store.scan() }) {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        searchField
                        filterRow
                        libraryContent
                        footerHint
                    }
                    .padding(.bottom, 110)
                }
                .background(Color.clear)

                importBanner
            }
            .background(Color.clear)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 18) {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                launcher.settings.viewStyle = launcher.settings.viewStyle.toggled
                            }
                        } label: {
                            Image(systemName: launcher.settings.viewStyle.toggled.symbolName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(SparkTheme.textPrimary)
                        }
                        .accessibilityLabel("Switch to \(launcher.settings.viewStyle.toggled.title)")

                        Button {
                            route = .customizeLauncher
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(SparkTheme.textPrimary)
                        }
                        .accessibilityLabel("Customize launcher")

                        Button {
                            presentArchivePicker()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(SparkTheme.textPrimary)
                        }
                        .accessibilityLabel("Import game")
                    }
                }
            }
            .sheet(item: $route) { route in
                sheetView(for: route)
            }
            .confirmationDialog(
                "Set a custom cover",
                isPresented: $showCoverSourceDialog,
                titleVisibility: .visible
            ) {
                Button("Choose from Photos") { presentPhotoCover() }
                Button("Choose from Files") { presentFileCover() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pick an image to represent this game in your library.")
            }
            .confirmationDialog(
                deleteTarget.map { "Delete \($0.title)?" } ?? "Delete game?",
                isPresented: $showDeleteDialog,
                titleVisibility: .visible
            ) {
                Button("Delete Game and Saves", role: .destructive) {
                    if let target = deleteTarget {
                        do {
                            try store.delete(target)
                        } catch {
                            presentError(error.localizedDescription)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The game folder and Documents/save/\(deleteTarget?.folderName ?? "") are removed. Zips in backups/ are kept.")
            }
            .fullScreenCover(item: $selectedGame) { game in
                GamePlayerView(game: game)
            }
            .alert(item: $alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .onChange(of: coordinator.failureMessage) { message in
                guard let message = message else { return }
                presentError(message, title: "Import failed")
                coordinator.clearFailure()
            }
            .onChange(of: store.errorMessage) { message in
                guard let message = message else { return }
                presentError(message)
                store.errorMessage = nil
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear(perform: configureNavigationBar)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LIBRARY")
                .sparkSectionLabel()

            Text(launcher.settings.headerTitle)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(SparkTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(SparkTheme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private var subtitle: String {
        let visibleCount = filteredGames.count
        let totalCount = store.games.count
        let gamesText: String
        if !store.hiddenFolderNames.isEmpty {
            gamesText = "\(visibleCount) game\(visibleCount == 1 ? "" : "s") (\(store.hiddenFolderNames.count) hidden)"
        } else {
            gamesText = "\(totalCount) game\(totalCount == 1 ? "" : "s")"
        }
        if let free = DiskSpace.formattedAvailable(at: AppPaths.documents) {
            return "\(gamesText) · \(free) free"
        }
        return gamesText
    }

    private var ambientCoverURL: URL? {
        let visible = store.games.filter { !store.isGameHidden($0) && $0.coverURL != nil }
        let sorted = visible.sorted {
            ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
        }
        return sorted.first?.coverURL
    }

    private func hideGame(_ game: Game) {
        withAnimation(.easeOut(duration: 0.2)) {
            if selectedGame?.folderName == game.folderName {
                selectedGame = nil
            }
            store.hideGame(game)
        }
    }

    // MARK: - Search and filters

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SparkTheme.textTertiary)

            TextField("Search", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 14))
                .foregroundColor(SparkTheme.textPrimary)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(SparkTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .sparkPanel(cornerRadius: 10, fill: SparkTheme.panel)
        .padding(.horizontal, 20)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isSelected: engineFilter == nil) {
                    engineFilter = nil
                }
                ForEach(presentEngines, id: \.rawValue) { engine in
                    chip(title: engine.rawValue, isSelected: engineFilter == engine) {
                        engineFilter = (engineFilter == engine) ? nil : engine
                    }
                }

                sortMenu
            }
            .padding(.horizontal, 20)
        }
    }

    private var presentEngines: [GameEngine] {
        let engines = Set(store.games.map { $0.engine })
        return GameEngine.allCases.filter { engines.contains($0) }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? SparkTheme.textPrimary : SparkTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isSelected ? Color.white.opacity(0.16) : SparkTheme.hairline,
                            lineWidth: SparkTheme.hairlineWidth
                        )
                )
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases) { sort in
                Button {
                    launcher.settings.sort = sort
                } label: {
                    if launcher.settings.sort == sort {
                        Label(sort.title, systemImage: "checkmark")
                    } else {
                        Text(sort.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(launcher.settings.sort.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(SparkTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
            )
        }
    }

    // MARK: - Library

    @ViewBuilder
    private var libraryContent: some View {
        if store.games.isEmpty {
            emptyState
        } else if filteredGames.isEmpty {
            noResultsState
        } else {
            switch launcher.settings.viewStyle {
            case .sparkLines:
                sparkLines
            case .prismIcons:
                prismGrid
            }
        }
    }

    private var prismGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(
                        minimum: launcher.settings.cardSize.minimumWidth,
                        maximum: launcher.settings.cardSize.minimumWidth * 1.8
                    ),
                    spacing: 14,
                    alignment: .top
                )
            ],
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(filteredGames) { game in
                GameCardView(
                    game: game,
                    cardSize: launcher.settings.cardSize,
                    lineColor: launcher.settings.lineColor(for: game),
                    onOpen: { openGame(game) },
                    onRename: { route = .rename(game) },
                    onSetCover: {
                        coverTarget = game
                        showCoverSourceDialog = true
                    },
                    onRemoveCover: { store.removeCustomCover(for: game) },
                    onChangeLineColor: { route = .lineColor(game) },
                    onBackup: { backup(game) },
                    onHide: { hideGame(game) },
                    onDelete: {
                        deleteTarget = game
                        showDeleteDialog = true
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sparkLines: some View {
        LazyVStack(spacing: 8) {
            ForEach(filteredGames) { game in
                SparkLineRowView(
                    game: game,
                    lineColor: launcher.settings.lineColor(for: game),
                    onOpen: { openGame(game) },
                    onRename: { route = .rename(game) },
                    onSetCover: {
                        coverTarget = game
                        showCoverSourceDialog = true
                    },
                    onRemoveCover: { store.removeCustomCover(for: game) },
                    onChangeLineColor: { route = .lineColor(game) },
                    onBackup: { backup(game) },
                    onHide: { hideGame(game) },
                    onDelete: {
                        deleteTarget = game
                        showDeleteDialog = true
                    }
                )
            }
        }
        .padding(.horizontal, 20)
    }

    private func openGame(_ game: Game) {
        store.markPlayed(game)
        selectedGame = game
    }

    private func backup(_ game: Game) {
        do {
            _ = try store.backupSaves(for: game)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(SparkTheme.textTertiary)

            Text("No games yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(SparkTheme.textPrimary)

            Text("Import a .zip, .7z, .rar or .apk, or copy a game folder into On My iPad / SparkRPGM / games and pull to refresh.")
                .font(.system(size: 12))
                .foregroundColor(SparkTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                presentArchivePicker()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Import a game")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .foregroundColor(launcher.settings.highlightPrimaryButtons ? Color.white : SparkTheme.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(launcher.settings.highlightPrimaryButtons ? accent : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            launcher.settings.highlightPrimaryButtons ? Color.clear : SparkTheme.hairline,
                            lineWidth: SparkTheme.hairlineWidth
                        )
                )
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .sparkPanel(cornerRadius: 14)
        .padding(.horizontal, 20)
    }

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(SparkTheme.textTertiary)
            Text("No games match this filter")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SparkTheme.textSecondary)
            Button("Clear filters") {
                searchText = ""
                engineFilter = nil
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var footerHint: some View {
        Text("Pull down to rescan · Long-press a game for options")
            .font(.system(size: 11))
            .foregroundColor(SparkTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var importBanner: some View {
        if coordinator.isShowingProgress, let job = coordinator.activeJob {
            GeometryReader { geo in
                ZStack(alignment: .center) {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()

                    ImportProgressCard(
                        job: job,
                        activeCount: coordinator.activeCount,
                        accent: accent
                    ) {
                        coordinator.cancel(jobID: job.id)
                    }
                    .frame(maxWidth: min(geo.size.width - 32, 480))
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.22), value: coordinator.isShowingProgress)
            .transition(.opacity)
            .zIndex(60)
        }
    }

    private func presentError(_ message: String, title: String = "Something went wrong") {
        alert = LibraryAlert(title: title, message: message)
    }

    // MARK: - Data

    private var filteredGames: [Game] {
        var result = store.games.filter { !store.isGameHidden($0) }

        if let engine = engineFilter {
            result = result.filter { $0.engine == engine }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.folderName.localizedCaseInsensitiveContains(query)
                    || $0.engine.displayName.localizedCaseInsensitiveContains(query)
            }
        }

        switch launcher.settings.sort {
        case .title:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recent:
            result.sort { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .mostPlayed:
            result.sort {
                if $0.playSeconds == $1.playSeconds {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.playSeconds > $1.playSeconds
            }
        case .size:
            result.sort { $0.byteSize > $1.byteSize }
        }

        return result
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetView(for route: LibraryRoute) -> some View {
        switch route {
        case .rename(let game):
            RenameSheet(game: game) { newTitle in
                do {
                    try store.rename(game, to: newTitle)
                } catch {
                    presentError(error.localizedDescription)
                }
            }

        case .lineColor(let game):
            LineColorPickerView(game: game)

        case .customizeLauncher:
            LauncherCustomizationView()
                .environmentObject(store)
                .environmentObject(launcher)
        }
    }

    // MARK: - Pickers

    private func presentArchivePicker() {
        DocumentPickerPresenter.shared.present(
            contentTypes: DocumentPickerTypes.archives,
            allowsMultipleSelection: true,
            onPicked: { documents in
                guard !documents.isEmpty else { return }
                coordinator.enqueue(documents: documents)
            },
            onFailure: { message in
                presentError(message, title: "Import failed")
            }
        )
    }

    private func presentPhotoCover() {
        guard let target = coverTarget else { return }
        PhotoPickerPresenter.shared.present { image in
            guard let image = image else { return }
            do {
                try store.setCustomCover(image, for: target)
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    private func presentFileCover() {
        guard let target = coverTarget else { return }
        DocumentPickerPresenter.shared.present(
            contentTypes: DocumentPickerTypes.images,
            allowsMultipleSelection: false,
            onPicked: { documents in
                guard let document = documents.first,
                      let data = try? Data(contentsOf: document.url),
                      let image = UIImage(data: data) else {
                    return
                }
                do {
                    try store.setCustomCover(image, for: target)
                } catch {
                    presentError(error.localizedDescription)
                }
            },
            onFailure: { message in
                presentError(message, title: "Cover")
            }
        )
    }

    // MARK: - Chrome

    private func configureNavigationBar() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.compactAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.tintColor = .white
    }
}
