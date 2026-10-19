import CGtk
import Foundation

/// A card's right-click menu, as Plex has it: play, more info, watched, go to the show.
@MainActor
enum ItemMenu {
    static func make(_ item: BaseItem, shell: Shell) -> Menu? {
        guard item.type != .person else { return nil }
        let state = shell.state
        var play: [Menu.Item] = []
        if item.type?.isVideo == true {
            if item.resumeSeconds > 0 {
                play.append(.action("Resume") { shell.window.play(item) })
                play.append(.action("Play from Beginning") { shell.window.play(item, from: 0) })
            } else {
                play.append(.action("Play") { shell.window.play(item) })
            }
        }
        play.append(.action("More Info") { shell.open(item) })

        var mark: [Menu.Item] = []
        if item.type != .boxSet {
            mark.append(.action(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched") {
                Task { await state.setPlayed(item, !item.isPlayed) }
            })
        }
        if item.resumeSeconds > 0 {
            mark.append(.action("Remove from Continue Watching") {
                Task { await state.removeFromContinueWatching(item) }
            })
        }

        var go: [Menu.Item] = []
        if item.type == .episode, let seriesId = item.seriesId {
            go.append(.action("Go to Show") {
                var show = BaseItem(id: seriesId)
                show.type = .series
                show.name = item.seriesName
                shell.open(show)
            })
            if let seasonId = item.seasonId {
                go.append(.action("Go to Season") {
                    var season = BaseItem(id: seasonId)
                    season.type = .season
                    season.name = item.seasonName
                    season.seriesId = seriesId
                    season.seriesName = item.seriesName
                    shell.open(season)
                })
            }
        }
        return Menu([play, mark, go].filter { !$0.isEmpty })
    }
}
