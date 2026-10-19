import Foundation

/// Which of the server's images a card, a hero or a row shows: the item's own, or its
/// series' when it has none. Shared by both apps.
enum Artwork {
    static func primary(_ item: BaseItem, _ client: JellyfinClient, width: Int) -> URL? {
        if let tag = item.imageTags?["Primary"] {
            return client.imageURL(itemId: item.id, tag: tag, maxWidth: width)
        }
        if let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return client.imageURL(itemId: seriesId, tag: tag, maxWidth: width)
        }
        return nil
    }

    /// 2:3, beside a detail page's title: an episode shows its show's poster.
    static func poster(_ item: BaseItem, _ client: JellyfinClient, width: Int) -> URL? {
        if item.type == .episode, let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return client.imageURL(itemId: seriesId, tag: tag, maxWidth: width)
        }
        return primary(item, client, width: width)
    }

    /// 16:9: an episode's still, or a film's thumb or backdrop.
    static func landscape(_ item: BaseItem, _ client: JellyfinClient, width: Int) -> URL? {
        if item.type == .episode, let tag = item.imageTags?["Primary"] {
            return client.imageURL(itemId: item.id, tag: tag, maxWidth: width)
        }
        if let tag = item.imageTags?["Thumb"] {
            return client.imageURL(itemId: item.id, type: "Thumb", tag: tag, maxWidth: width)
        }
        if let id = item.parentThumbItemId, let tag = item.parentThumbImageTag {
            return client.imageURL(itemId: id, type: "Thumb", tag: tag, maxWidth: width)
        }
        return backdrop(item, client, width: width) ?? primary(item, client, width: width)
    }

    static func backdrop(_ item: BaseItem, _ client: JellyfinClient, width: Int) -> URL? {
        if let tag = item.backdropImageTags?.first {
            return client.imageURL(itemId: item.id, type: "Backdrop", tag: tag, maxWidth: width, index: 0)
        }
        if let id = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return client.imageURL(itemId: id, type: "Backdrop", tag: tag, maxWidth: width, index: 0)
        }
        return nil
    }

    static func logo(_ item: BaseItem, _ client: JellyfinClient, width: Int) -> URL? {
        if let tag = item.imageTags?["Logo"] {
            return client.imageURL(itemId: item.id, type: "Logo", tag: tag, maxWidth: width)
        }
        if let id = item.parentLogoItemId, let tag = item.parentLogoImageTag {
            return client.imageURL(itemId: id, type: "Logo", tag: tag, maxWidth: width)
        }
        return nil
    }
}
