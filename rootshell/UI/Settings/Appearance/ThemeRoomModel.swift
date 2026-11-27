//
//  ThemeRoomModel.swift
//  rootshell
//
//  Picks the furnishings for a theme's room from words in its name, and
//  fills the rest from a stable per-name mix so every theme gets a room.
//

import Foundation

nonisolated enum RoomView: Int, CaseIterable, Sendable {
    case sky, city, snow, forest, ocean, desert, space, rain
}

nonisolated enum RoomArt: Int, CaseIterable, Sendable {
    case abstract, neon, wave, code, moon, flower, chalkboard, rainbow, hashNeon, prompt, binaryClock
}

nonisolated enum RoomCorner: Int, CaseIterable, Sendable {
    case lamp, plant, bonsai, bookshelf, arcade, server
}

nonisolated enum RoomCenter: Int, CaseIterable, Sendable {
    case sofa, desk, retroDesk
}

nonisolated enum RoomCompanion: Int, CaseIterable, Sendable {
    case none, cat, owl, fishbowl, dog, fox
}

nonisolated enum RoomTableItem: Int, CaseIterable, Sendable {
    case succulent, mug, candle, duck, teapot, fruit, books, keycap, floppy, alarmClock
}

nonisolated struct ThemeRoom: Equatable, Sendable {
    var view: RoomView
    var art: RoomArt
    var corner: RoomCorner
    var center: RoomCenter
    var companion: RoomCompanion
    var table: RoomTableItem
    /// The rootshell hash mark, stitched into the rug and printed on the mug.
    var hashMark: Bool

    /// Words in the name win; anything left is a stable mix seeded by the name.
    init(name: String, isLight: Bool) {
        let words = name.lowercased()
        func match<T>(_ table: [(T, [String])]) -> T? {
            table.first { entry in entry.1.contains { words.contains($0) } }?.0
        }
        var seed = Self.seed(words)
        func pick<T>(_ options: [T]) -> T {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return options[Int((seed >> 33) % UInt64(options.count))]
        }

        view = match(Self.views) ?? pick(isLight ? [.sky, .sky, .forest, .desert] : [.sky, .sky, .city, .space, .rain])
        art = match(Self.arts) ?? pick([.abstract, .abstract, .code, .flower, .rainbow, .prompt, .hashNeon, .binaryClock])
        corner = match(Self.corners) ?? pick([.lamp, .lamp, .plant, .bookshelf])
        center = match(Self.centers) ?? pick([.sofa, .sofa, .sofa, .desk])
        companion = match(Self.companions) ?? pick([.none, .none, .cat, .dog, .fishbowl])
        table = match(Self.tables) ?? pick([.succulent, .books, .mug, .keycap, .floppy, .duck, .alarmClock])
        hashMark = Self.hashWords.contains { words.contains($0) } || pick([true, false, false])
    }

    private static let hashWords = ["rootshell", "root", "hash", "shell", "hax0r", "hacker"]

    /// FNV-1a, so the mix is the same on every launch and device.
    private static func seed(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    private static let views: [(RoomView, [String])] = [
        (.snow, ["nord", "iceberg", "glacier", "winter", "frost", "polar", "novmbr", "peppermint"]),
        (.city, ["tokyo", "urban", "highway", "neon", "cyber", "synthwave", "laser", "encom", "osaka", "broadcast",
                 "traffic", "wilmersdorf", "seoul", "city"]),
        (.ocean, ["ocean", "sea", "deep", "dolphin", "fish", "mariana", "kanagawa", "nord wave", "tide", "havn", "aqua"]),
        (.forest, ["forest", "forrest", "ever", "pine", "treehouse", "grass", "farmhouse", "firewatch", "earthsong",
                   "spring", "flora", "paradise", "hollow", "green", "moss"]),
        (.desert, ["desert", "sands", "planet", "sundried", "solarized", "ayu", "sun", "afterglow", "dawn", "dayfox",
                   "firefly", "fahrenheit", "citrus", "mojave"]),
        (.space, ["galaxy", "andromeda", "space", "star", "nebula", "moon", "aurora", "cosmic", "horizon", "twilight",
                  "owl", "pandora", "alien", "night"]),
        (.rain, ["rain", "storm", "misterioso", "slumber", "detuned", "vague"]),
    ]

    private static let arts: [(RoomArt, [String])] = [
        (.hashNeon, ["rootshell", "root", "hash", "hax0r", "hacker"]),
        (.prompt, ["terminal", "console", "bash", "zsh", "shell", "tty", "kitty", "iterm", "konsolas", "wez", "powershell"]),
        (.neon, ["neon", "synthwave", "retro", "cyber", "laser", "bright lights", "eighties", "arcade", "hot dog", "toy chest"]),
        (.wave, ["kanagawa", "wave", "japanesque", "ocean", "sea"]),
        (.moon, ["dracula", "vampire", "black metal", "darkside", "bat", "gothic", "calamity", "hollow", "hacktober", "miasma"]),
        (.flower, ["rose", "sakura", "flora", "lavand", "fairyfloss", "blossom", "spring", "cherry", "sugarplum", "paradise"]),
        (.chalkboard, ["chalk", "novel", "man page", "pencil", "alabaster"]),
        (.rainbow, ["rainbow", "arcoiris", "niji", "unikitty", "crayon", "popping"]),
        (.code, ["github", "gitlab", "xcode", "atom", "vercel", "raycast", "material", "monokai", "jetbrains", "idea",
                 "nvim", "vim", "dark+", "dark modern", "cursor", "powershell", "ubuntu", "iterm", "builtin", "terminal",
                 "homebrew", "django", "framer", "firefox", "electron", "front end", "one "]),
        // Last, so "12-bit Rainbow" keeps its rainbow.
        (.binaryClock, ["binary", "bit", "byte", "hex", "0x", "clock", "time", "digital", "encom", "cyberdyne", "matrix"]),
    ]

    private static let corners: [(RoomCorner, [String])] = [
        (.server, ["matrix", "hax0r", "homebrew", "ibm", "irix", "borland", "cga", "c64", "powershell", "hardcore",
                   "alien", "cyberdyne", "soft server", "red alert", "encom"]),
        (.arcade, ["retro", "arcade", "synthwave", "12-bit", "toy chest", "popping", "n0tch", "cyber", "laser"]),
        (.bonsai, ["zen", "kanagawa", "japanesque", "seoul", "sakura", "ryuuko", "tokyo"]),
        (.plant, ["forest", "forrest", "ever", "pine", "grass", "green", "tree", "spring", "moss", "flora", "phala", "farmhouse"]),
        (.bookshelf, ["novel", "man page", "pencil", "alabaster", "elegant", "relaxed", "mellow", "tomorrow",
                      "solarized", "gruvbox", "flexoki", "melange", "nord"]),
    ]

    private static let centers: [(RoomCenter, [String])] = [
        (.retroDesk, ["ibm", "irix", "borland", "cga", "c64", "matrix", "hax0r", "homebrew", "retro legends", "man page"]),
        (.desk, ["github", "gitlab", "xcode", "atom", "vercel", "raycast", "jetbrains", "idea", "nvim", "vim", "dark+",
                 "dark modern", "cursor", "ubuntu", "iterm", "builtin", "framer", "django", "powershell", "brogrammer",
                 "front end", "electron", "terminal"]),
    ]

    private static let companions: [(RoomCompanion, [String])] = [
        (.cat, ["catppuccin", "cat", "kitty", "kurokula", "purr", "whimsy"]),
        (.owl, ["owl"]),
        (.fox, ["fox"]),
        (.dog, ["dog", "heeler", "kibble", "chester", "ollie"]),
        (.fishbowl, ["fish", "sea", "ocean", "dolphin", "mariana", "shells", "aqua"]),
    ]

    private static let tables: [(RoomTableItem, [String])] = [
        (.alarmClock, ["clock", "time", "alarm", "morning", "slumber", "later this evening", "dawn"]),
        (.keycap, ["vim", "nvim", "emacs", "keyboard", "hacker", "hax0r", "brogrammer"]),
        (.floppy, ["c64", "ibm", "cga", "borland", "irix", "amiga", "dos", "12-bit", "retro"]),
        (.duck, ["duck"]),
        (.mug, ["coffee", "mocha", "latte", "espresso", "macchiato", "frappe", "ristretto", "brew", "jackie brown"]),
        (.candle, ["dracula", "black metal", "darkside", "gothic", "hollow", "hacktober", "calamity", "vampire",
                   "embers", "firewatch"]),
        (.teapot, ["japanesque", "zen", "kanagawa", "earthsong", "seoul"]),
        (.fruit, ["banana", "berry", "cherry", "citrus", "grape", "sugarplum", "apple", "peppermint"]),
    ]
}
