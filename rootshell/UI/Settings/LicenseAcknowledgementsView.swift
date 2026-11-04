import SwiftUI

// MARK: - License Entry Model

struct LicenseEntry: Identifiable {
    let id = UUID()
    let name: String
    let licenseType: String
    let copyright: String
    let repositoryURL: String?
    let licenseText: String
}

// MARK: - License Row View

struct LicenseRow: View {
    let entry: LicenseEntry
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                // Copyright
                Text(entry.copyright)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Repository link
                if let urlString = entry.repositoryURL,
                   let url = URL(string: urlString) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            Text(urlString.replacingOccurrences(of: "https://", with: ""))
                        }
                        .font(.caption)
                    }
                }

                // License text
                Text(entry.licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(6)
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Text(entry.name)
                Spacer()
                Text(entry.licenseType)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Main View

struct LicenseAcknowledgementsView: View {
    var body: some View {
        List {
            Section("Core") {
                ForEach(coreLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("Fonts") {
                ForEach(fontLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("SSH & Networking") {
                ForEach(sshLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("Cloud & Kubernetes") {
                ForEach(cloudLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("Cloud Storage") {
                ForEach(storageLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            #if canImport(FluidAudio) && !CHINA_BUILD
            Section("Speech Recognition") {
                ForEach(speechLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section {
                ForEach(speechModelLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            } header: {
                Text("Speech Models")
            } footer: {
                Text("Downloaded on demand when you turn on dictation, not included in the app.")
            }
            #endif

            Section("Logo Artwork") {
                ForEach(logoLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("Sounds") {
                ForEach(soundLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("Apple Open Source") {
                ForEach(appleLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - License Data

    private var coreLicenses: [LicenseEntry] {
        var entries = [
            LicenseEntry(
                name: "Ghostty / libghostty",
                licenseType: "MIT",
                copyright: "Copyright (c) 2024 Mitchell Hashimoto and Ghostty contributors",
                repositoryURL: "https://github.com/ghostty-org/ghostty",
                licenseText: mitLicenseText
            ),
        ]
        #if !targetEnvironment(macCatalyst)
        entries += [
            LicenseEntry(
                name: "ios_system",
                licenseType: "BSD 3-Clause",
                copyright: "Copyright (c) 2018 Nicolas Holzschuch",
                repositoryURL: "https://github.com/holzschu/ios_system",
                licenseText: bsd3ClauseLicenseText
            ),
            LicenseEntry(
                name: "jq",
                licenseType: "MIT",
                copyright: "Copyright (c) 2012 Stephen Dolan",
                repositoryURL: "https://github.com/jqlang/jq",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "Vim",
                licenseType: "Vim License",
                copyright: "Copyright (c) 1991-2024 Bram Moolenaar and the Vim contributors",
                repositoryURL: "https://github.com/vim/vim",
                licenseText: vimLicenseText
            ),
            LicenseEntry(
                name: "curl",
                licenseType: "MIT",
                copyright: "Copyright (c) 1996-2026 Daniel Stenberg and many contributors",
                repositoryURL: "https://github.com/curl/curl",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "Helix Editor",
                licenseType: "MPL-2.0",
                copyright: "Copyright (c) 2020 Blaž Hrastnik and Helix contributors",
                repositoryURL: "https://github.com/helix-editor/helix",
                licenseText: mpl2LicenseText
            ),
            LicenseEntry(
                name: "bat",
                licenseType: "MIT / Apache 2.0",
                copyright: "Copyright (c) 2018-2023 bat-developers",
                repositoryURL: "https://github.com/sharkdp/bat",
                licenseText: mitApache2LicenseText
            ),
            LicenseEntry(
                name: "ripgrep",
                licenseType: "Unlicense / MIT",
                copyright: "Copyright (c) 2015 Andrew Gallant",
                repositoryURL: "https://github.com/BurntSushi/ripgrep",
                licenseText: unlicenseMitLicenseText
            ),
            LicenseEntry(
                name: "libgit2",
                licenseType: "GPLv2 + Linking Exception",
                copyright: "Copyright (c) the libgit2 contributors",
                repositoryURL: "https://github.com/libgit2/libgit2",
                licenseText: gplv2LinkingExceptionText
            ),
            LicenseEntry(
                name: "libarchive",
                licenseType: "BSD-2-Clause",
                copyright: "Copyright (c) 2003-2024 Tim Kientzle and contributors",
                repositoryURL: "https://github.com/libarchive/libarchive",
                licenseText: bsd2ClauseLicenseText
            ),
        ]
        #endif
        #if STANDALONE
        entries.append(
            LicenseEntry(
                name: "Sparkle",
                licenseType: "MIT",
                copyright: "Copyright (c) 2006-2013 Andy Matuschak and Sparkle contributors",
                repositoryURL: "https://github.com/sparkle-project/Sparkle",
                licenseText: mitLicenseText
            )
        )
        #endif
        return entries
    }

    private var fontLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "0xProto",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright (c) 2024 0xType Project Authors",
                repositoryURL: "https://github.com/0xType/0xProto",
                licenseText: silOFLLicenseText
            ),
            LicenseEntry(
                name: "Fira Code",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright (c) 2014 The Fira Code Project Authors",
                repositoryURL: "https://github.com/tonsky/FiraCode",
                licenseText: silOFLLicenseText
            ),
            LicenseEntry(
                name: "Geist Mono",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright (c) 2023 Vercel",
                repositoryURL: "https://github.com/vercel/geist-font",
                licenseText: silOFLLicenseText
            ),
            LicenseEntry(
                name: "Nerd Fonts",
                licenseType: "MIT / SIL OFL 1.1",
                copyright: "Copyright (c) 2014 Ryan L McIntyre",
                repositoryURL: "https://github.com/ryanoasis/nerd-fonts",
                licenseText: mitLicenseText
            )
        ]
    }

    private var sshLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "Citadel",
                licenseType: "MIT",
                copyright: "Copyright (c) 2022 Orlandos",
                repositoryURL: "https://github.com/orlandos-nl/Citadel",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "trzsz-ssh (tssh)",
                licenseType: "MIT",
                copyright: "Copyright (c) 2023 Lonny Wong",
                repositoryURL: "https://github.com/trzsz/trzsz-ssh",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "Tailscale",
                licenseType: "BSD 3-Clause",
                copyright: "Copyright (c) 2020 Tailscale Inc & AUTHORS",
                repositoryURL: "https://github.com/tailscale/tailscale",
                licenseText: bsd3ClauseLicenseText
            ),
            LicenseEntry(
                name: "wireguard-go",
                licenseType: "MIT",
                copyright: "Copyright (C) 2017-2025 WireGuard LLC",
                repositoryURL: "https://github.com/tailscale/wireguard-go",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "YubiKit",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Yubico AB",
                repositoryURL: "https://github.com/kitknox/yubikit-swift-rootshell",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "IPinfo",
                licenseType: "CC BY-SA 4.0",
                copyright: "IP address data powered by IPinfo",
                repositoryURL: "https://ipinfo.io",
                licenseText: ccBySa4LicenseText
            ),
            LicenseEntry(
                name: "croc",
                licenseType: "MIT",
                copyright: "Copyright (c) 2017-2025 Zack Scholl",
                repositoryURL: "https://github.com/schollz/croc",
                licenseText: mitLicenseText
            )
        ]
    }

    private var cloudLicenses: [LicenseEntry] {
        var entries: [LicenseEntry] = [
            LicenseEntry(
                name: "SwiftkubeClient",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) 2020 Iskandar Abudiab",
                repositoryURL: "https://github.com/swiftkube/client",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "Yams",
                licenseType: "MIT",
                copyright: "Copyright (c) 2016 JP Simard",
                repositoryURL: "https://github.com/kitknox/Yams-rootshell",
                licenseText: mitLicenseText
            ),
        ]
        #if !CHINA_BUILD
        entries.append(LicenseEntry(
            name: "SwiftOpenAI",
            licenseType: "MIT",
            copyright: "Copyright (c) 2023 James Rochabrun",
            repositoryURL: "https://github.com/kitknox/SwiftOpenAI-rootshell",
            licenseText: mitLicenseText
        ))
        #endif
        return entries
    }

    /// The dictation-only FluidAudio fork and its native text-normalization dependency.
    /// TTS/G2P and diarization dependencies are excluded by the fork's package manifests.
    private var speechLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "FluidAudio",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) FluidInference",
                repositoryURL: "https://github.com/kitknox/fluidaudio-rootshell",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "text-processing-rs",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) FluidInference. Grammars derived from NVIDIA NeMo Text Processing, Copyright (c) NVIDIA CORPORATION & AFFILIATES.",
                repositoryURL: "https://github.com/FluidInference/text-processing-rs",
                licenseText: apache2LicenseText + "\n\n" + nemoTextProcessingNoticeText
            ),
            LicenseEntry(
                name: "NVIDIA NeMo Text Processing",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) NVIDIA CORPORATION & AFFILIATES.",
                repositoryURL: "https://github.com/NVIDIA/NeMo-text-processing",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "rustfst",
                licenseType: "MIT / Apache 2.0",
                copyright: "Copyright (c) Alexandre Caulier and the rustfst contributors",
                repositoryURL: "https://github.com/Garvys/rustfst",
                licenseText: mitApache2LicenseText
            ),
            LicenseEntry(
                name: "flate2",
                licenseType: "MIT / Apache 2.0",
                copyright: "Copyright (c) Alex Crichton and the flate2 contributors",
                repositoryURL: "https://github.com/rust-lang/flate2-rs",
                licenseText: mitApache2LicenseText
            ),
        ]
    }

    /// Models fetched from Hugging Face at runtime; attribution per their licenses.
    private var speechModelLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "NVIDIA Parakeet TDT 0.6B v3 and v2, Parakeet TDT-CTC 110M",
                licenseType: "CC BY 4.0",
                copyright: "Copyright (c) NVIDIA Corporation. Converted to Core ML by FluidInference.",
                repositoryURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
                licenseText: ccBy4LicenseText
            ),
            LicenseEntry(
                name: "Parakeet Ultra and Parakeet Redux",
                licenseType: "CC BY 4.0",
                copyright: "By moondream, derived from NVIDIA Parakeet TDT 0.6B v3. Converted to Core ML by FluidInference.",
                repositoryURL: "https://huggingface.co/moondream/parakeet-ultra",
                licenseText: ccBy4LicenseText
            ),
            LicenseEntry(
                name: "SenseVoiceSmall",
                licenseType: "FunASR Model License 1.1",
                copyright: "Copyright (C) 2023-2028 Alibaba Group. FunAudioLLM SenseVoiceSmall, converted to Core ML by FluidInference.",
                repositoryURL: "https://huggingface.co/FunAudioLLM/SenseVoiceSmall",
                licenseText: funASRModelLicenseText
            ),
            LicenseEntry(
                name: "Silero VAD",
                licenseType: "MIT",
                copyright: "Copyright (c) 2020-present Silero Team. Converted to Core ML by FluidInference.",
                repositoryURL: "https://github.com/snakers4/silero-vad",
                licenseText: mitLicenseText
            ),
        ]
    }

    private var logoLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "Bash logo",
                licenseType: "Free Art License 1.3",
                copyright: "Copyright (c) 2016 Free Software Foundation",
                repositoryURL: "https://github.com/odb/official-bash-logo",
                licenseText: freeArtLicenseText
            ),
            LicenseEntry(
                name: "Zsh logo",
                licenseType: "CC BY-SA 4.0",
                copyright: "Justin Dorfman and Zsh-art contributors. Official monochrome logomark, strokes converted to outlines.",
                repositoryURL: "https://github.com/Zsh-art/logo",
                licenseText: ccBySa4LicenseText
            ),
            LicenseEntry(
                name: "Nushell logo",
                licenseType: "MIT",
                copyright: "The Nushell project developers, via Simple Icons",
                repositoryURL: "https://github.com/nushell/nushell",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "Elvish logo",
                licenseType: "BSD 2-Clause",
                copyright: "The Elvish authors. λ outlined from Vollkorn (SIL OFL 1.1).",
                repositoryURL: "https://github.com/elves/elvish",
                licenseText: bsd2ClauseLicenseText
            ),
            LicenseEntry(
                name: "xonsh logo",
                licenseType: "BSD 2-Clause",
                copyright: "The xonsh developers. Filters flattened to solid fills.",
                repositoryURL: "https://github.com/xonsh/xonsh",
                licenseText: bsd2ClauseLicenseText
            ),
            LicenseEntry(
                name: "Neovim logo",
                licenseType: "CC BY 3.0",
                copyright: "Jason Long",
                repositoryURL: "https://github.com/neovim/neovim.github.io",
                licenseText: ccBy3LicenseText
            ),
            LicenseEntry(
                name: "btop logo",
                licenseType: "Apache 2.0",
                copyright: "Aristocratos",
                repositoryURL: "https://github.com/aristocratos/btop",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "tmux logo",
                licenseType: "ISC",
                copyright: "Copyright (c) Jason Long",
                repositoryURL: "https://github.com/tmux/tmux/tree/master/logo",
                licenseText: iscLicenseText
            ),
            LicenseEntry(
                name: "Ruby logo",
                licenseType: "CC BY-SA 2.5",
                copyright: "Copyright (c) 2006 Yukihiro Matsumoto. Style classes converted to fill attributes.",
                repositoryURL: "https://www.ruby-lang.org/en/about/logo/",
                licenseText: ccBySa25LicenseText
            ),
            LicenseEntry(
                name: "Python logo",
                licenseType: "PSF Trademark Policy",
                copyright: "\"Python\" and the Python logos are trademarks or registered trademarks of the Python Software Foundation.",
                repositoryURL: "https://www.python.org/psf/trademarks/",
                licenseText: "Used unaltered under the Python Software Foundation Trademark Usage Policy: https://www.python.org/psf/trademarks/"
            ),
            LicenseEntry(
                name: "Homebrew logo",
                licenseType: "BSD 2-Clause",
                copyright: "Homebrew contributors",
                repositoryURL: "https://github.com/Homebrew/brew.sh",
                licenseText: bsd2ClauseLicenseText
            ),
            LicenseEntry(
                name: "Deno logo",
                licenseType: "MIT",
                copyright: "Deno Land Inc.",
                repositoryURL: "https://deno.com/brand",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "Node.js logo",
                licenseType: "MIT",
                copyright: "Node.js Website WG contributors. Node.js is a trademark of the OpenJS Foundation.",
                repositoryURL: "https://github.com/nodejs/nodejs.org",
                licenseText: mitLicenseText
            ),
        ]
    }

    private var soundLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "Sound Effects",
                licenseType: "CC0 1.0",
                copyright: "Includes sounds from Freesound.org (CC0 1.0 Public Domain) and original synthesized waveforms",
                repositoryURL: "https://freesound.org",
                licenseText: cc0LicenseText
            )
        ]
    }

    private var appleLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "Swift NIO",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Apple Inc.",
                repositoryURL: "https://github.com/apple/swift-nio",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "Swift NIO SSH",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Apple Inc.",
                repositoryURL: "https://github.com/apple/swift-nio-ssh",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "Swift Crypto",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Apple Inc.",
                repositoryURL: "https://github.com/apple/swift-crypto",
                licenseText: apache2LicenseText
            )
        ]
    }

    // MARK: - License Texts

    private var mitLicenseText: String {
        """
        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """
    }

    private var bsd2ClauseLicenseText: String {
        """
        Redistribution and use in source and binary forms, with or without \
        modification, are permitted provided that the following conditions are met:

        1. Redistributions of source code must retain the above copyright notice, \
        this list of conditions and the following disclaimer.

        2. Redistributions in binary form must reproduce the above copyright notice, \
        this list of conditions and the following disclaimer in the documentation \
        and/or other materials provided with the distribution.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
        AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
        IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE \
        DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE \
        FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL \
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR \
        SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER \
        CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, \
        OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE \
        OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
    }

    private var bsd3ClauseLicenseText: String {
        """
        Redistribution and use in source and binary forms, with or without \
        modification, are permitted provided that the following conditions are met:

        1. Redistributions of source code must retain the above copyright notice, \
        this list of conditions and the following disclaimer.

        2. Redistributions in binary form must reproduce the above copyright notice, \
        this list of conditions and the following disclaimer in the documentation \
        and/or other materials provided with the distribution.

        3. Neither the name of the copyright holder nor the names of its contributors \
        may be used to endorse or promote products derived from this software without \
        specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
        AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
        IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE \
        DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE \
        FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL \
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR \
        SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER \
        CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, \
        OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE \
        OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
    }

    private var silOFLLicenseText: String {
        """
        This Font Software is licensed under the SIL Open Font License, Version 1.1.

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of the Font Software, to use, study, copy, merge, embed, modify, redistribute, \
        and sell modified and unmodified copies of the Font Software, subject to the \
        following conditions:

        1) Neither the Font Software nor any of its individual components, in Original \
        or Modified Versions, may be sold by itself.

        2) Original or Modified Versions of the Font Software may be bundled, \
        redistributed and/or sold with any software, provided that each copy contains \
        the above copyright notice and this license.

        3) No Modified Version of the Font Software may use the Reserved Font Name(s) \
        unless explicit written permission is granted by the corresponding Copyright Holder.

        4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font Software \
        shall not be used to promote, endorse or advertise any Modified Version, except \
        to acknowledge the contribution(s) of the Copyright Holder(s) and the Author(s) \
        or with their explicit written permission.

        5) The Font Software, modified or unmodified, in part or in whole, must be \
        distributed entirely under this license, and must not be distributed under any \
        other license.

        THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY, FITNESS \
        FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT, TRADEMARK, \
        OR OTHER RIGHT. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, \
        DAMAGES OR OTHER LIABILITY, INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, \
        OR CONSEQUENTIAL DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, \
        ARISING FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM OTHER \
        DEALINGS IN THE FONT SOFTWARE.
        """
    }

    private var vimLicenseText: String {
        """
        I)  There are no restrictions on distributing unmodified copies of Vim \
        except that they must include this license text. You can also distribute \
        unmodified parts of Vim, likewise unrestricted except that they must include \
        this license text. You are also allowed to include executables that you made \
        from the unmodified Vim sources, plus your own usage examples and Vim scripts.

        II) It is allowed to distribute a modified (or extended) version of Vim, \
        including executables and/or source code, when the following four conditions \
        are met:
        1) This license text must be included unmodified.
        2) The modified Vim must be distributed in one of the following five ways:
           a) If you make changes to Vim yourself, you must clearly describe in the \
        distribution how to contact you. When the maintainer asks you (in any way) \
        for a copy of the modified Vim you distributed, you must make your changes, \
        including source code, available to the maintainer without fee.
           b) If you have received a modified Vim that was distributed as mentioned \
        under a) you are allowed to further distribute it unmodified, as mentioned at I).
           c) Provide all the changes, including source code, with every copy of the \
        modified Vim you distribute. This may be done in the form of a context diff.
           d) When you have a modified Vim which includes changes as mentioned under c), \
        you can distribute it without the source code for the changes if the license \
        that applies to the changes permits you to distribute the changes to the Vim \
        maintainer without fee or restriction, and you keep the changes for at least \
        three years after last distributing the corresponding modified Vim.
           e) When the GNU General Public License (GPL) applies to the changes, you \
        can distribute the modified Vim under the GNU GPL version 2 or any later version.
        3) A message must be added, at least in the output of the ":version" command \
        and in the intro screen, such that the user of the modified Vim is able to see \
        that it was modified.
        4) The contact information as required under 2)a) and 2)d) must not be removed \
        or changed, except that the person himself can make corrections.

        III) If you distribute a modified version of Vim, you are encouraged to use the \
        Vim license for your changes and make them available to the maintainer, \
        including the source code. The e-mail address to be used is <maintainer@vim.org>

        IV) It is not allowed to remove this license from the distribution of the Vim \
        sources, parts of it or from a modified version. You may use this license for \
        previous Vim releases instead of the license that they came with, at your option.
        """
    }

    private var mpl2LicenseText: String {
        """
        This Source Code Form is subject to the terms of the Mozilla Public \
        License, v. 2.0. If a copy of the MPL was not distributed with this \
        file, You can obtain one at https://mozilla.org/MPL/2.0/.
        """
    }

    private var mitApache2LicenseText: String {
        """
        Licensed under either of:

        • Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
        • MIT License (http://opensource.org/licenses/MIT)

        at your option.

        ---

        \(mitLicenseText)
        """
    }

    private var unlicenseMitLicenseText: String {
        """
        Licensed under either of:

        \u{2022} The Unlicense (http://unlicense.org/)
        \u{2022} MIT License (http://opensource.org/licenses/MIT)

        at your option.

        ---

        \(mitLicenseText)
        """
    }

    private var funASRModelLicenseText: String {
        """
        FunASR Model Open Source License Agreement, Version 1.1

        Copyright (C) 2023-2028 Alibaba Group. All rights reserved.

        [FunASR Software] refers to FunASR open-source model weights and their \
        derivatives, including finetuned models.

        License: You are free to use, copy, modify, and share [FunASR Software] \
        under the terms of this agreement.

        Restrictions: When using, copying, modifying, and sharing [FunASR \
        Software], you must attribute the source and author information and \
        retain relevant model names in [FunASR Software].

        Responsibility and Risk: [FunASR Software] is provided for reference and \
        learning purposes only, and Alibaba Group assumes no responsibility for \
        any direct or indirect losses resulting from your use or modification of \
        [FunASR Software]. You should assume all risks associated with using and \
        modifying [FunASR Software].

        Full text: https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE
        """
    }

    private var cc0LicenseText: String {
        """
        CC0 1.0 Universal (CC0 1.0) Public Domain Dedication

        The person who associated a work with this deed has dedicated the work \
        to the public domain by waiving all of his or her rights to the work \
        worldwide under copyright law, including all related and neighboring \
        rights, to the extent allowed by law.

        You can copy, modify, distribute and perform the work, even for \
        commercial purposes, all without asking permission.
        """
    }

    private var apache2LicenseText: String {
        """
        Licensed under the Apache License, Version 2.0 (the "License"); \
        you may not use this file except in compliance with the License. \
        You may obtain a copy of the License at

            http://www.apache.org/licenses/LICENSE-2.0

        Unless required by applicable law or agreed to in writing, software \
        distributed under the License is distributed on an "AS IS" BASIS, \
        WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. \
        See the License for the specific language governing permissions and \
        limitations under the License.
        """
    }

    private var storageLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "Soto for AWS",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) 2017-2026 the Soto project authors",
                repositoryURL: "https://github.com/soto-project/soto",
                licenseText: apache2LicenseText + "\n\n" + sotoNoticeText
            ),
            LicenseEntry(
                name: "Soto Core",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) 2017-2026 the Soto project authors",
                repositoryURL: "https://github.com/soto-project/soto-core",
                licenseText: apache2LicenseText + "\n\n" + sotoCoreNoticeText
            ),
            LicenseEntry(
                name: "Perfect-INIParser",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) 2017 - 2018 PerfectlySoft Inc. and the Perfect project authors",
                repositoryURL: "https://github.com/PerfectlySoft/Perfect-INIParser",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "Expat",
                licenseType: "MIT",
                copyright: "Copyright (c) 1998-2000 Thai Open Source Software Center Ltd and Clark Cooper\nCopyright (c) 2001-2019 Expat maintainers",
                repositoryURL: "https://github.com/libexpat/libexpat",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "swift-extras-base64",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) the swift-extras-base64 project authors",
                repositoryURL: "https://github.com/swift-extras/swift-extras-base64",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "fastbase64",
                licenseType: "BSD 2-Clause",
                copyright: "Copyright (c) 2015-2016, Wojciech Muła, Alfred Klomp, Daniel Lemire",
                repositoryURL: "https://github.com/lemire/fastbase64",
                licenseText: bsd2ClauseLicenseText
            ),
            LicenseEntry(
                name: "stringencoders (modp_b64)",
                licenseType: "MIT",
                copyright: "Copyright (c) 2016 Nick Galbreath",
                repositoryURL: "https://github.com/client9/stringencoders",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "JMESPath for Swift",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Adam Fowler",
                repositoryURL: "https://github.com/jmespath/jmespath.swift",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "AsyncHTTPClient",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Apple Inc. and the AsyncHTTPClient project authors",
                repositoryURL: "https://github.com/swift-server/async-http-client",
                licenseText: apache2LicenseText
            ),
        ]
    }

    private var sotoNoticeText: String {
        """
        NOTICE

        This product uses HummingbirdMustache to generate its source files

          * LICENSE (Apache-2.0):
            * https://github.com/hummingbird-project/hummingbird-mustache/blob/main/LICENSE
          * HOMEPAGE:
            * https://github.com/hummingbird-project/hummingbird-mustache
        """
    }

    private var sotoCoreNoticeText: String {
        """
        NOTICE

        This product contains a copy of INIParser from PerfectlySoft

          * LICENSE (Apache License 2.0):
            * https://github.com/PerfectlySoft/Perfect-INIParser/blob/master/LICENSE
          * HOMEPAGE:
            * https://github.com/PerfectlySoft/Perfect-INIParser

        This product contains a copy of libexpat

          * LICENSE (MIT):
            * https://github.com/libexpat/libexpat/blob/master/expat/COPYING
          * HOMEPAGE:
            * https://libexpat.github.io/

        This product contains a copy of base64.swift from swift-extras-base64

          * LICENSE (Apache License 2.0):
            * https://github.com/swift-extras/swift-extras-base64/blob/main/LICENSE
          * HOMEPAGE:
            * https://github.com/swift-extras/swift-extras-base64
        """
    }

    private var gplv2LinkingExceptionText: String {
        """
        In addition to the permissions in the GNU General Public License, \
        the authors give you unlimited permission to link the compiled \
        version of this library into combinations with other programs, \
        and to distribute those combinations without any restriction \
        coming from the use of this file. (The General Public License \
        restrictions do apply in other respects; for example, they cover \
        modification of the file, and distribution when not linked into \
        a combined executable.)

        This library is free software; you can redistribute it and/or \
        modify it under the terms of the GNU General Public License as \
        published by the Free Software Foundation; version 2 of the License.

        This library is distributed in the hope that it will be useful, \
        but WITHOUT ANY WARRANTY; without even the implied warranty of \
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU \
        General Public License for more details.

        You should have received a copy of the GNU General Public License \
        along with this library; if not, see <https://www.gnu.org/licenses/>.
        """
    }

    private var ccBy4LicenseText: String {
        """
        This work is licensed under the Creative Commons Attribution 4.0 \
        International License. To view a copy of this license, visit \
        https://creativecommons.org/licenses/by/4.0/

        Changes: the original checkpoints were converted to Core ML and \
        quantized by FluidInference (https://huggingface.co/FluidInference). \
        Rootshell uses them unmodified.
        """
    }

    private var nemoTextProcessingNoticeText: String {
        """
        The NemoTextProcessing framework statically links rustfst and flate2 \
        (MIT OR Apache-2.0) and their permissively licensed dependencies, \
        including nom, miniz_oxide, bitflags and anyhow (MIT and/or Apache-2.0). \
        Compiled grammars are derived from NVIDIA NeMo Text Processing \
        (Apache-2.0, Copyright (c) NVIDIA CORPORATION & AFFILIATES).
        """
    }

    private var ccBy3LicenseText: String {
        """
        This work is licensed under the Creative Commons Attribution 3.0 \
        Unported License. To view a copy of this license, visit \
        https://creativecommons.org/licenses/by/3.0/
        """
    }

    private var ccBySa25LicenseText: String {
        """
        This work is licensed under the Creative Commons Attribution-ShareAlike \
        2.5 License. To view a copy of this license, visit \
        https://creativecommons.org/licenses/by-sa/2.5/
        """
    }

    private var iscLicenseText: String {
        """
        Permission to use, copy, modify, and distribute this software for any \
        purpose with or without fee is hereby granted, provided that the above \
        copyright notice and this permission notice appear in all copies.

        THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES \
        WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF \
        MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR \
        ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES \
        WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN \
        ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF \
        OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
        """
    }

    private var freeArtLicenseText: String {
        """
        This artwork is free: you can redistribute it and/or modify it according \
        to the terms of the Free Art License 1.3. A copy of this license is \
        available at https://artlibre.org/licence/lal/en/
        """
    }

    private var ccBySa4LicenseText: String {
        """
        This work is licensed under the Creative Commons Attribution-ShareAlike \
        4.0 International License. To view a copy of this license, visit \
        http://creativecommons.org/licenses/by-sa/4.0/ or send a letter to \
        Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.
        """
    }
}

#Preview {
    NavigationView {
        LicenseAcknowledgementsView()
    }
}
