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

/// What a BlurHash says before the image comes: its average colour.
enum BlurHash {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    /// The average colour's lightness, 0 (black) to 1 (white); nil for a hash that is not
    /// one. Characters 2 to 5 are the average as sRGB, base 83.
    static func lightness(_ hash: String) -> Double? {
        let characters = Array(hash)
        guard characters.count >= 6 else { return nil }
        var value = 0
        for character in characters[2 ..< 6] {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            value = value * 83 + digit
        }
        let red = Double((value >> 16) & 255), green = Double((value >> 8) & 255), blue = Double(value & 255)
        return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
    }
}

extension Artwork {
    /// The logo, unless it would vanish on the backdrop: a dark logo over the page's dark
    /// shade reads as nothing, and Plex shows the title then. With transparency the
    /// average is diluted toward black, so only a really dark one is left out.
    static func readableLogo(_ item: BaseItem, _ client: JellyfinClient, width: Int) -> URL? {
        guard let url = logo(item, client, width: width) else { return nil }
        let hashes = item.imageBlurHashes?["Logo"] ?? [:]
        let tag = item.imageTags?["Logo"] ?? item.parentLogoImageTag
        if let tag, let hash = hashes[tag], let lightness = BlurHash.lightness(hash), lightness < 0.12 {
            return nil
        }
        return url
    }
}
