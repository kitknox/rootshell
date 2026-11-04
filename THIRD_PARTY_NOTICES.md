# Third-Party Notices

rootshell is built with and distributes software, fonts, data, and other
materials from third parties. We are grateful to their authors and
contributors.

## What the rootshell MIT license covers

The repository's [`LICENSE`](LICENSE) applies to the original rootshell source
code and documentation authored by Rootshell LLC and Kit Knox, except where a
file or directory says otherwise.

That MIT license does **not** relicense:

- third-party source code, binary frameworks, packages, or command-line tools;
- bundled fonts, editor runtimes, sounds, data sets, or other assets; or
- code derived from a third-party project where the upstream license continues
  to apply.

Those materials remain subject to their respective copyright notices and
license terms. Our changes to a third-party project are licensed as stated in
that project's source repository and license files. No trademark rights are
granted by the rootshell MIT license.

This document consolidates the acknowledgements shown in the app. Some items
are included only in particular platform, region, or distribution builds.
Swift Package Manager dependencies may also have transitive dependencies; the
license files shipped in or referenced by those packages remain controlling.
If this summary differs from an upstream license, the upstream license controls.

## Core components and bundled tools

| Project | Copyright or acknowledgement | License |
| --- | --- | --- |
| [Ghostty / libghostty](https://github.com/ghostty-org/ghostty) | Copyright (c) 2024 Mitchell Hashimoto and Ghostty contributors | MIT |
| [ios_system](https://github.com/holzschu/ios_system) | Copyright (c) 2018 Nicolas Holzschuch | BSD 3-Clause |
| [jq](https://github.com/jqlang/jq) | Copyright (c) 2012 Stephen Dolan | MIT |
| [Vim](https://github.com/vim/vim) | Copyright (c) 1991-2024 Bram Moolenaar and the Vim contributors | Vim License |
| [curl](https://github.com/curl/curl) | Copyright (c) 1996-2026 Daniel Stenberg and many contributors | curl License |
| [Helix Editor](https://github.com/helix-editor/helix) | Copyright (c) 2020 Blaž Hrastnik and Helix contributors | MPL 2.0 |
| [bat](https://github.com/sharkdp/bat) | Copyright (c) 2018-2023 bat-developers | MIT or Apache 2.0 |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | Copyright (c) 2015 Andrew Gallant | Unlicense or MIT |
| [libgit2](https://github.com/libgit2/libgit2) | Copyright (c) the libgit2 contributors | GPL 2.0 with linking exception |
| [libarchive](https://github.com/libarchive/libarchive) | Copyright (c) 2003-2024 Tim Kientzle and contributors | BSD 2-Clause and per-file terms |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Copyright (c) 2006-2013 Andy Matuschak and Sparkle contributors | MIT; Standalone Catalyst builds only |

The app uses maintained rootshell forks or binary-package wrappers for some of
these projects. A wrapper does not change the license of the software it
contains. See the corresponding package repository for the exact source,
modification notices, and complete license text used by a build.

Joe's Own Editor is an optional, debug-only component licensed under the GNU
GPL. Its package and the support files under `Resources/joe` are stripped from
distribution builds and are not covered by the rootshell MIT license. See the
[rootshell JOE fork](https://github.com/kitknox/joe-rootshell) for its source
and complete licensing information.

## Fonts

| Font project | Copyright or acknowledgement | License |
| --- | --- | --- |
| [0xProto](https://github.com/0xType/0xProto) | Copyright (c) 2024 0xType Project Authors | SIL Open Font License 1.1 |
| [Fira Code](https://github.com/tonsky/FiraCode) | Copyright (c) 2014 The Fira Code Project Authors | SIL Open Font License 1.1 |
| [Geist Mono](https://github.com/vercel/geist-font) | Copyright (c) 2023 Vercel | SIL Open Font License 1.1 |
| [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) | Copyright (c) 2014 Ryan L McIntyre | MIT; individual fonts and glyph sources retain their own licenses, including SIL OFL 1.1 |

The rootshell MIT license does not apply to the font files under
`Resources/fonts`.

## SSH, networking, and remote access

| Project or data source | Copyright or acknowledgement | License |
| --- | --- | --- |
| [Citadel](https://github.com/orlandos-nl/Citadel) | Copyright (c) 2022 Orlandos | MIT |
| [trzsz-ssh (tssh)](https://github.com/trzsz/trzsz-ssh) | Copyright (c) 2023-2026 The Trzsz SSH Authors | MIT |
| [YubiKit](https://github.com/kitknox/yubikit-swift-rootshell) | Copyright (c) Yubico AB | Apache 2.0 |
| [IPinfo data](https://ipinfo.io) | IP address data powered by IPinfo | CC BY-SA 4.0 |
| [croc](https://github.com/schollz/croc) | Copyright (c) 2017-2025 Zack Scholl | MIT |

## Cloud and Kubernetes

| Project | Copyright or acknowledgement | License |
| --- | --- | --- |
| [SwiftkubeClient](https://github.com/swiftkube/client) | Copyright (c) 2020 Iskandar Abudiab | Apache 2.0 |
| [Yams](https://github.com/kitknox/Yams-rootshell) | Copyright (c) 2016 JP Simard | MIT |
| [SwiftOpenAI](https://github.com/kitknox/SwiftOpenAI-rootshell) | Copyright (c) 2023 James Rochabrun | MIT; excluded from China builds |

## Cloud storage

| Project | Copyright or acknowledgement | License |
| --- | --- | --- |
| [Soto for AWS](https://github.com/soto-project/soto) | Copyright (c) 2017-2026 the Soto project authors | Apache 2.0 |
| [Soto Core](https://github.com/soto-project/soto-core) | Copyright (c) 2017-2026 the Soto project authors | Apache 2.0 |
| [Perfect-INIParser](https://github.com/PerfectlySoft/Perfect-INIParser) (in Soto Core) | Copyright (c) 2017 - 2018 PerfectlySoft Inc. and the Perfect project authors | Apache 2.0 |
| [Expat](https://github.com/libexpat/libexpat) (in Soto Core) | Copyright (c) 1998-2000 Thai Open Source Software Center Ltd and Clark Cooper; Copyright (c) 2001-2019 Expat maintainers | MIT |
| [swift-extras-base64](https://github.com/swift-extras/swift-extras-base64) (in Soto Core) | Copyright (c) the swift-extras-base64 project authors | Apache 2.0 |
| [fastbase64](https://github.com/lemire/fastbase64) (in Soto Core) | Copyright (c) 2015-2016, Wojciech Muła, Alfred Klomp, Daniel Lemire | BSD 2-Clause |
| [stringencoders](https://github.com/client9/stringencoders) (in Soto Core) | Copyright (c) 2016 Nick Galbreath | MIT |
| [JMESPath for Swift](https://github.com/jmespath/jmespath.swift) | Copyright (c) Adam Fowler | Apache 2.0 |
| [AsyncHTTPClient](https://github.com/swift-server/async-http-client) | Copyright (c) Apple Inc. and the AsyncHTTPClient project authors | Apache 2.0 |

Soto's NOTICE file states:

> This product uses HummingbirdMustache to generate its source files
> ([license](https://github.com/hummingbird-project/hummingbird-mustache/blob/main/LICENSE),
> [homepage](https://github.com/hummingbird-project/hummingbird-mustache)).

Soto Core's NOTICE file states:

> This product contains a copy of INIParser from PerfectlySoft
> ([license](https://github.com/PerfectlySoft/Perfect-INIParser/blob/master/LICENSE),
> [homepage](https://github.com/PerfectlySoft/Perfect-INIParser)).
>
> This product contains a copy of libexpat
> ([license](https://github.com/libexpat/libexpat/blob/master/expat/COPYING),
> [homepage](https://libexpat.github.io/)).
>
> This product contains a copy of base64.swift from swift-extras-base64
> ([license](https://github.com/swift-extras/swift-extras-base64/blob/main/LICENSE),
> [homepage](https://github.com/swift-extras/swift-extras-base64)).

## Apple open-source projects

| Project | Copyright or acknowledgement | License |
| --- | --- | --- |
| [Swift NIO](https://github.com/apple/swift-nio) | Copyright (c) Apple Inc. and the SwiftNIO project authors | Apache 2.0 |
| [Swift NIO SSH](https://github.com/apple/swift-nio-ssh) | Copyright (c) Apple Inc. and the SwiftNIO SSH project authors | Apache 2.0 |
| [Swift Crypto](https://github.com/apple/swift-crypto) | Copyright (c) Apple Inc. and the Swift Crypto project authors | Apache 2.0 |

## Logo artwork

Shell and program logos shown in tabs and the sidebar. The rootshell MIT
license does not apply to them; each keeps its own license.

| Artwork | Copyright or acknowledgement | License |
| --- | --- | --- |
| [Bash logo](https://github.com/odb/official-bash-logo) | Copyright (c) 2016 Free Software Foundation | Free Art License 1.3 |
| [Zsh logo](https://github.com/Zsh-art/logo) | Justin Dorfman and Zsh-art contributors; official monochrome logomark, strokes converted to outlines | CC BY-SA 4.0 |
| [Nushell logo](https://github.com/nushell/nushell) | The Nushell project developers, via [Simple Icons](https://simpleicons.org) | MIT |
| [Elvish logo](https://github.com/elves/elvish) | The Elvish authors; λ outlined from [Vollkorn](https://github.com/google/fonts/tree/main/ofl/vollkorn) (SIL OFL 1.1) | BSD 2-Clause |
| [xonsh logo](https://github.com/xonsh/xonsh) | The xonsh developers; filters flattened to solid fills | BSD 2-Clause |

| [Neovim logo](https://github.com/neovim/neovim.github.io) | Jason Long | CC BY 3.0 |
| [btop logo](https://github.com/aristocratos/btop) | Aristocratos | Apache 2.0 |
| [tmux logo](https://github.com/tmux/tmux/tree/master/logo) | Jason Long | ISC |
| [Ruby logo](https://www.ruby-lang.org/en/about/logo/) | Copyright (c) 2006 Yukihiro Matsumoto; style classes converted to fill attributes | CC BY-SA 2.5 |
| [Python logo](https://www.python.org/psf/trademarks/) | "Python" and the Python logos are trademarks or registered trademarks of the Python Software Foundation | Used under the PSF trademark policy |
| [Homebrew logo](https://github.com/Homebrew/brew.sh) | Homebrew contributors | BSD 2-Clause |
| [Deno logo](https://deno.com/brand) | Deno Land Inc. | MIT |
| [Node.js logo](https://github.com/nodejs/nodejs.org) | Node.js Website WG contributors. Node.js is a trademark of the OpenJS Foundation | MIT |

The fish, htop, Emacs, Cargo, tail and git marks are original rootshell artwork.

## Sound Effects

rootshell includes original synthesized waveforms and sounds sourced from
[Freesound](https://freesound.org) under the CC0 1.0 Universal public-domain
dedication. The rootshell MIT license does not apply to third-party sound files.

## Complete license terms

Complete license terms and copyright notices are available in each linked
project and in the source or binary package resolved for a build. In
particular:

- [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)
- [BSD 2-Clause License](https://opensource.org/license/bsd-2-clause)
- [BSD 3-Clause License](https://opensource.org/license/bsd-3-clause)
- [Creative Commons Attribution-ShareAlike 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode)
- [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/legalcode)
- [Creative Commons Attribution-ShareAlike 2.5](https://creativecommons.org/licenses/by-sa/2.5/legalcode)
- [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/legalcode)
- [Free Art License 1.3](https://artlibre.org/licence/lal/en/)
- [GNU GPL 2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
- [ISC License](https://opensource.org/license/isc-license-txt)
- [MIT License](https://opensource.org/license/mit)
- [Mozilla Public License 2.0](https://www.mozilla.org/MPL/2.0/)
- [SIL Open Font License 1.1](https://openfontlicense.org/open-font-license-official-text/)
- [The Unlicense](https://unlicense.org)

The Vim, curl, and libgit2 linking-exception terms are
project-specific; use the license file in the linked project rather than a
generic license summary.
