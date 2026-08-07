# CDVR WinUtil

A one-line PowerShell installer for the Channels DVR ecosystem - Docker Desktop, WSL2/Debian,
and a curated set of community add-ons (HTPC front-ends, DVR desktop clients, OliVetin for
Channels, and more) - built as a fork of
[ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil).

## Quick Start

> Must be run as Administrator - it self-elevates and prompts for UAC if needed.

Open PowerShell or Terminal, then run:

```powershell
irm https://raw.githubusercontent.com/bnhf/cdvr-winutil/main/winutil.ps1 | iex
```

This opens the Install tab: pick packages, hit **Install/Upgrade Applications**. Packages that
depend on something else (e.g. OliVetin for Channels needs WSL2, Debian, and Docker Desktop)
will offer to install the missing pieces first.

## What's different from upstream winutil

- **Install tab only** - the Tweaks/Config/Updates/Win11 Creator tabs from upstream are removed;
  this fork does one thing (install the Channels DVR ecosystem).
- **Curated catalog** (`config/applications.json`) - a small, hand-picked set of apps instead of
  winutil's full ~200+ app list, under two categories: **Foundational** and **Channels DVR**.
- **New install mechanisms**, beyond winget/choco, for packages that aren't on either:
  - `direct` - download a URL and run the installer
  - `github` - download and run the newest matching asset from a GitHub repo's releases
  - `npm` - install a global npm package (used for tools distributed via npm, e.g. Prismcast)
  - `wslFeature` / `wslDistro` - enable WSL2 / install a WSL distro
  - `wslCommand` - run a command inside a WSL distro, with user-prompted values (e.g. a
    password) substituted in before it runs
- **Prerequisite checking** - packages can declare `requires: [...]`; if a dependency isn't
  installed, you're asked whether to install it too before the dependent package runs.

## Development

Same structure and build process as upstream winutil:

```powershell
.\Compile.ps1        # bundles functions/, config/, xaml/, scripts/ into winutil.ps1
.\windev.ps1          # compile + run, for local testing
```

Commit the regenerated `winutil.ps1` alongside source changes - it's what the `irm | iex`
one-liner actually fetches.

## License

MIT, same as upstream. See [LICENSE](LICENSE).
