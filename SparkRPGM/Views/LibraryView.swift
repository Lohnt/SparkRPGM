import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum LibraryRoute: Identifiable {
    case archives
    case coverPhoto(Game)
    case coverFile(Game)
    case rename(Game)
    case customizeLauncher
    case importProgress

    var id: String {
        switch self {
        case .archives: return "archives"
        case .coverPhoto(let game): return "cover-photo-\(game.folderName)"
        case .coverFile(let game): return "cover-file-\(game.folderName)"
        case .rename(let game): return "rename-\(game.folderName)"
        case .customizeLauncher: return "customize-launcher"
        case .importProgress: return "import-progress"
        }
    }
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

    private var accent: Color { launcher.settings.accentColor }

    var body: some View {
        NavigationView {
            ZStack {
                LauncherBackground(settings: launcher.settings)

                RefreshableScrollView(onRefresh: { store.scan() }) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        searchField
                        filterChips
                        libraryContent
                        footerHint
                    }
                    .padding(.bottom, 120)
                }

                toastOverlay
                errorOverlay
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(accent)
                        Text(launcher.settings.headerTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            route = .customizeLauncher
                        } label: {
                            Image(systemName: "paintbrush.pointed.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                        }

                        Button {
                            route = .archives
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(accent)
                        }
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
                Button("Choose from Photos") {
                    if let target = coverTarget { open(route: .coverPhoto(target), delay: 0.35) }
                }
                Button("Choose from Files") {
                    if let target = coverTarget { open(route: .coverFile(target), delay: 0.35) }
                }
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
                            store.errorMessage = error.localizedDescription
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
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear(perform: configureNavigationBar)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GAME LIBRARY")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.4)
                .foregroundColor(accent)

            Text(launcher.settings.headerTitle)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private var subtitle: String {
        let count = store.games.count
        let gamesText = "\(count) game\(count == 1 ? "" : "s")"
        if let free = DiskSpace.formattedAvailable(at: AppPaths.documents) {
            return "\(gamesText)  •  \(free) free  •  iOS 15+"
        }
        return "\(gamesText)  •  iOS 15+"
    }

    // MARK: - Search and filters

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))

            TextField("Search your library", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 14))
                .foregroundColor(.white)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .glassCard(cornerRadius: 13, opacity: 0.45)
        .padding(.horizontal, 20)
    }

    private var filterChips: some View {
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? accent.opacity(0.85) : Color.white.opacity(0.07))
                )
                .overlay(
                    Capsule().stroke(Color.white.opacity(isSelected ? 0.22 : 0.08), lineWidth: 1)
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
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: launcher.settings.cardSize.minimumWidth), spacing: 16)],
                spacing: 18
            ) {
                ForEach(filteredGames) { game in
                    GameCardView(
                        game: game,
                        cardSize: launcher.settings.cardSize,
                        glassOpacity: launcher.settings.glassOpacity,
                        accent: accent,
                        onOpen: {
                            store.markPlayed(game)
                            selectedGame = game
                        },
                        onRename: {
                            route = .rename(game)
                        },
                        onSetCover: {
                            coverTarget = game
                            showCoverSourceDialog = true
                        },
                        onRemoveCover: {
                            store.removeCustomCover(for: game)
                        },
                        onBackup: {
                            do {
                                _ = try store.backupSaves(for: game)
                            } catch {
                                store.errorMessage = error.localizedDescription
                            }
                        },
                        onDelete: {
                            deleteTarget = game
                            showDeleteDialog = true
                        }
                    )
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(accent)
            }

            Text("Your library is empty")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.white)

            Text("Import a .zip, .7z, .rar or .apk, or drop an extracted game into\nOn My iPad / SparkRPGM / games and pull to refresh.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                route = .archives
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("Import a game")
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(accent)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 46)
        .glassCard(cornerRadius: 22, opacity: 0.30)
        .padding(.horizontal, 20)
    }

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.white.opacity(0.35))
            Text("No games match this filter")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            Button("Clear filters") {
                searchText = ""
                engineFilter = nil
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footerHint: some View {
        VStack(spacing: 5) {
            Text("Pull down to rescan  •  Long-press a card for more")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
            Text("Files.app: On My iPad / SparkRPGM")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let message = store.toastMessage ?? coordinator.errorBanner {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: 14, opacity: 0.72)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onTapGesture {
                        coordinator.clearError()
                    }
            }
        }
        .animation(.easeOut(duration: 0.2))
    }

    @ViewBuilder
    private var errorOverlay: some View {
        if let error = store.errorMessage {
            VStack {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Color(red: 1, green: 0.72, blue: 0.35))
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        store.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(13)
                .glassCard(cornerRadius: 14, opacity: 0.82)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                Spacer()
            }
        }
    }

    // MARK: - Data

    private var filteredGames: [Game] {
        var result = store.games

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
        case .size:
            result.sort { $0.byteSize > $1.byteSize }
        }

        return result
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetView(for route: LibraryRoute) -> some View {
        switch route {
        case .archives:
            FilePicker(
                isPresented: routeBinding(),
                contentTypes: FilePickerTypes.archives,
                allowsMultipleSelection: true,
                onPicked: handleArchivePick
            )

        case .coverPhoto(let game):
            PhotoPicker(isPresented: routeBinding()) { image in
                try? store.setCustomCover(image, for: game)
            }

        case .coverFile(let game):
            FilePicker(
                isPresented: routeBinding(),
                contentTypes: FilePickerTypes.images,
                allowsMultipleSelection: false,
                onPicked: { urls in
                    guard let url = urls.first else { return }
                    let scope = SecurityScopedResource(url)
                    defer { _ = scope }
                    guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                        store.errorMessage = "That image could not be read."
                        return
                    }
                    do {
                        try store.setCustomCover(image, for: game)
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            )

        case .rename(let game):
            RenameSheet(game: game) { newTitle in
                do {
                    try store.rename(game, to: newTitle)
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }

        case .customizeLauncher:
            LauncherCustomizationView()

        case .importProgress:
            ImportProgressView(coordinator: coordinator)
        }
    }

    private func routeBinding() -> Binding<Bool> {
        Binding(
            get: { route != nil },
            set: { presented in
                if !presented { route = nil }
            }
        )
    }

    private func open(route newRoute: LibraryRoute, delay: TimeInterval) {
        route = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            route = newRoute
        }
    }

    private func handleArchivePick(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        coordinator.enqueue(urls: urls)
        open(route: .importProgress, delay: 0.45)
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
