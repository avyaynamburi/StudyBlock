import Foundation

/// A named set of sites that switches on and off as a unit — "types of
/// blocks", so a session can shut out short-form video without also shutting
/// out news.
///
/// What actually gets enforced is the union of every *enabled* group's
/// domains, which is why groups may overlap freely: a site listed in two
/// groups is blocked once, and stays blocked until both are switched off.
struct BlockGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var domains: [String] = []
    /// Off leaves this group's sites out of the blocklist entirely; the group
    /// itself is kept, so switching it back on is one click.
    var isEnabled = true
}

extension BlockGroup {
    /// Seeded on the first launch of a build that has groups. Everything here
    /// is a site people reach for *instead* of working — social, video,
    /// sports, browser games, aggregators, adult and gambling — which is why
    /// it's one list rather than several: it's the list you switch off with a
    /// single toggle when you sit down to study.
    static let distractionsPreset = [
        "247roulette.org", "9to5mac.com", "agar.io", "amongus-online.net",
        "arstechnica.com", "basketrandom.com", "bilibili.com", "bleacherreport.com",
        "boingboing.net", "break.com", "businessinsider.com", "buzzfeed.com",
        "cbssports.com", "chess.com", "collegehumor.com", "cracked.com",
        "crazygames.com", "deviantart.com", "diep.io", "digg.com",
        "discord.com", "engadget.com", "espn.com", "facebook.com",
        "fark.com", "foxsports.com", "funnyordie.com", "gizmodo.com",
        "gx.games", "hulu.com", "imgur.com", "instagram.com",
        "itemfix.com", "kick.com", "krunker.io", "lichess.com",
        "lichess.org", "lifehacker.com", "macrumors.com", "mashable.com",
        "metafilter.com", "miniclip.com", "mlb.com", "monkeytype.com",
        "myspace.com", "nba.com", "netflix.com", "network.pokernow.club",
        "news.ycombinator.com", "nfl.com", "nhl.com", "pinterest.com",
        "play.typeracer.com", "pornhub.com", "powerline.io", "producthunt.com",
        "qzone.qq.com", "readwrite.com", "recode.net", "reddit.com",
        "roblox.com", "rumble.com", "scratch.mit.edu", "slashdot.org",
        "snapchat.com", "soap2dayto.info", "stake.com", "tagged.com",
        "techcrunch.com", "techmeme.com", "ted.com", "thenextweb.com",
        "theoatmeal.com", "theonion.com", "theverge.com", "tieba.baidu.com",
        "tiktok.com", "tmz.com", "tomshardware.com", "tumblr.com",
        "twitch.tv", "twitter.com", "twoplayergames.org", "typeracer.com",
        "venturebeat.com", "vimeo.com", "vk.com", "weibo.com",
        "wired.com", "ww18.soap2day.day", "ww8.soap2dayhd.co", "xhamster.com",
        "xkcd.com", "xnxx.com", "xvideos.com", "yandex.com",
        "youtube.com", "yy.com", "zdnet.com",
    ]
}
