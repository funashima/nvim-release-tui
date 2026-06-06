# nvim-release-tui

A small Haskell TUI for downloading official Neovim Linux x86_64 release archives from GitHub Releases.

`nvim-release-tui` lets you browse Neovim `stable` and `unstable` releases in a terminal UI, select a release, and download the corresponding:

```text
nvim-linux-x86_64.tar.gz
```

asset into:

```text
~/Downloads
```

The downloaded file is saved with the release tag in its filename, for example:

```text
~/Downloads/nvim-linux-x86_64-v0.11.5.tar.gz
~/Downloads/nvim-linux-x86_64-nightly.tar.gz
```

This avoids accidental overwrites between stable and unstable/nightly builds.

## Features

* Browse Neovim GitHub Releases from a terminal UI
* Switch between `stable` and `unstable` release tabs
* Select a release interactively
* Download the official Linux x86_64 tarball
* Save downloads to `~/Downloads`
* Avoid filename collisions by appending the release tag
* Refresh the release list from inside the TUI

## Release classification

The application uses the GitHub Releases API.

* `stable`: releases where `prerelease == false`
* `unstable`: releases where `prerelease == true`
* target asset: `nvim-linux-x86_64.tar.gz`

The release list is fetched from:

```text
https://api.github.com/repos/neovim/neovim/releases?per_page=100
```

The nightly release may also be fetched from:

```text
https://api.github.com/repos/neovim/neovim/releases/tags/nightly
```

## Requirements

* Linux x86_64
* GHC
* Cabal
* Network access to GitHub

Recommended compiler:

```text
GHC 9.12.4
```

GHC 9.14.x may currently cause dependency-resolution problems with some packages in the Brick dependency tree, especially around `containers` and `config-ini`.

## Build and run

Clone the repository and run:

```bash
cabal update
cabal run
```

If you are using GHCup, the recommended setup is:

```bash
ghcup install ghc 9.12.4
ghcup set ghc 9.12.4

cabal update
cabal run
```

Alternatively, you can pin the compiler only for this project:

```bash
ghcup install ghc 9.12.4

cat > cabal.project.local <<EOF
with-compiler: $HOME/.ghcup/ghc/9.12.4/bin/ghc
EOF

cabal update
cabal run
```

## Install as a local binary

To install the TUI as a normal command-line program:

```bash
cabal install exe:nvim-release-tui \
  --install-method=copy \
  --installdir="$HOME/.local/bin" \
  --overwrite-policy=always
```

Then run:

```bash
nvim-release-tui
```

Make sure `~/.local/bin` is in your `PATH`.

For Bash or Zsh:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Key bindings

| Key                   | Action                                  |
| --------------------- | --------------------------------------- |
| `Tab` / `h` / `l`     | Switch between stable and unstable tabs |
| `j` / `k`             | Move selection down/up                  |
| `Up` / `Down`         | Move selection down/up                  |
| `PageUp` / `PageDown` | Move by 10 entries                      |
| `Home` / `End`        | Jump to first/last entry                |
| `Enter`               | Download the selected release asset     |
| `r`                   | Refresh the release list                |
| `q` / `Esc`           | Quit                                    |

## Download behavior

The official Neovim asset name is always:

```text
nvim-linux-x86_64.tar.gz
```

However, this application saves the file as:

```text
nvim-linux-x86_64-<tag>.tar.gz
```

For example:

```text
nvim-linux-x86_64-v0.11.5.tar.gz
nvim-linux-x86_64-nightly.tar.gz
```

This makes it possible to keep multiple Neovim release archives in `~/Downloads` without overwriting previous downloads.

## Known issue: GHC 9.14.x

With GHC 9.14.x, Cabal may fail to resolve dependencies with an error involving:

```text
containers == 0.8
config-ini => containers < 0.8
```

This is not an application source-code error. It is caused by package-version bounds in the dependency tree.

Recommended solution:

```bash
ghcup install ghc 9.12.4
ghcup set ghc 9.12.4

cabal clean
cabal run
```

A temporary workaround may also work:

```bash
cabal run --allow-newer=config-ini:containers
```

Using GHC 9.12.4 is the safer option.

## Project structure

```text
.
├── app
│   └── Main.hs
├── nvim-release-tui.cabal
└── README.md
```

## License

BSD-3-Clause

## Disclaimer

This project is not affiliated with the Neovim project. It is a small helper tool for downloading official Neovim release assets from GitHub.
