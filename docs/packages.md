# What is in the image, and what is not

Notes on package choices that are not obvious from `mkosi.conf`, and on the
gaps between what the brief asked for and what Debian actually ships.

## Wine

**Not Debian's Wine.** The image installs
[`wine-sg`](https://github.com/Stained-Glass-OS/wine-sg) from its `.deb`, built
with `--enable-archs=i386,x86_64`, into `/opt/wine-sg`. That is what lets this
pure amd64 image run **32-bit** Windows applications with no multiarch — see
[ADR 0005](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/decisions/0005-building-wine-ourselves.md).
The boot gate proves it end to end by launching `syswow64\notepad.exe` and
requiring it to appear inside the shell.

The package list carries the ~25 libraries `wine-sg` links against **directly**;
apt resolves the rest. Keep that list in step with `wine-sg`'s own `Depends`,
because the image installs the `.deb` with `dpkg`, which does not resolve
anything itself.

### It also made the image smaller

Counter-intuitively, building our own Wine *reduced* the image:

| | installed size |
|---|---|
| Debian `wine` (amd64 tree) | 717 MB |
| Debian `wine` (i386 tree, needed for 32-bit) | 601 MB |
| **`wine-sg`, both architectures** | **454 MB** |

Debian does not strip its Wine; we do, with the matching mingw `strip` per
architecture. Unstripped, `wine-sg` is 1.5 GB — about 1.1 GB of that is DWARF.
The cost is symbolised `winedbg` backtraces; rebuild `wine-sg` with `STRIP=0`
when chasing a crash inside Wine.

## Direct3D translation layers

**DXVK and VKD3D-Proton are in the image, from upstream rather than Debian.**

| Component | Status |
|---|---|
| DXVK | Upstream PE build, 3.1.1. Debian's packages are **unusable with `wine-sg`** — see below. |
| VKD3D-Proton | Upstream PE build, 3.0.1. Not packaged in Debian at all. |

DXVK *was* installed while the image used Debian's Wine. Moving to `wine-sg`
made Debian's DXVK packages inapplicable, for a reason worth understanding
rather than working around:

`dxvk-wine64` ships **`.dll.so` files** — old-style Wine builtins, which are
ELF shared objects, laid out for Debian's Wine directory. Under new WoW64 the
32-bit side has no 32-bit ELF loader at all, so a 32-bit `d3d9.dll.so` could
only work by reintroducing i386 multiarch, which is precisely what we removed.

Upstream DXVK ships **PE** DLLs (`x32/` and `x64/`), which is the right shape
for new WoW64: they are copied into the prefix like any Windows DLL. So the fix
is to consume upstream DXVK rather than Debian's packaging, and to install it
into the system prefix at `sg-prefix-init` time.

The same applies to VKD3D-Proton, which was never packaged anyway. Note again
the name collision: Debian's `libvkd3d1` and `vkd3d-compiler` are **Wine's own
vkd3d**, a different project, and not a substitute.

**Both are now in the image**, as upstream PE DLLs.

`make d3d` fetches the upstream releases with pinned sha256 hashes and stages
them into `/opt/sg-d3d/{dxvk,vkd3d-proton}/{x64,x32,x86}`. `sg-install-d3d`
copies them into the prefix at `sg-prefix-init` time — 64-bit into `system32`
and 32-bit into `syswow64`, which is the Windows layout rather than the
intuitive one — and sets the DLL overrides.

Two things that were not obvious:

- **Wine reads `DllOverrides` from HKCU only.** In a shared system prefix HKCU
  is per user, so an administrator has nowhere to put a machine-wide override:
  the DLLs sit in `system32` looking installed while Wine loads its own
  builtins, with no error anywhere. `wine-sg` patch 0009 makes HKLM a
  machine-wide default, consulted after HKCU so a user can still override it.
- **File checks prove almost nothing here.** An installation that is doing
  nothing looks identical to one that works. `sg-d3d-check` therefore creates
  a real D3D11 and D3D12 device, on both architectures, using a probe built as
  a Windows PE (`sg-session`'s `test/d3d-probe.c`).

A Vulkan driver has to exist underneath: the image ships `mesa-vulkan-drivers`,
whose lavapipe is a software ICD, so Direct3D works — slowly — on a machine
with no GPU, including the QEMU guest. Run it with `make d3d-test`.

Licences are carried in `licenses/`: DXVK is zlib, VKD3D-Proton is LGPL-2.1.

Tracked as [#6](https://github.com/Stained-Glass-OS/stained-glass/issues/6).

## Bundled Windows applications: PowerShell 7 and Python

**Both are in the image as upstream's own Windows builds**, staged by `make
apps` into `/opt/sg-apps` with pinned versions and hashes, and installed into
the prefix at first boot by sg-session's `sg-install-apps` -- Program Files,
the machine PATH, PEP 514 registration for Python, Start-menu shortcuts.

| Component | Source | Licence |
|---|---|---|
| PowerShell | 7.6.6, `PowerShell-7.6.6-win-x64.zip` from GitHub releases | MIT (`LICENSE.txt`, `ThirdPartyNotices.txt` in the payload) |
| CPython | 3.14.7, python.org's NuGet package | PSF (`LICENSE.txt` in the payload) |

Python is the NuGet package rather than the installer. The installer is a WiX
bootstrapper that would have to run silently under Wine at first boot; the
NuGet package is the complete install layout -- stdlib, pip, venv -- published
for installer-free deployment. Verified on wine-sg: SSL and sqlite load, `pip`
and `venv` work, and a package installs from PyPI over HTTPS.

PowerShell 7 runs (version, filesystem, exit codes) with a console. **With no
console and its output redirected it fails**: its ConsoleHost throws a
NullReferenceException on Wine. Desktop use always has a console, so this is
not user-visible; unattended PowerShell (login scripts, RMM) needs it fixed.

The gate is `make apps-test`. About 300 MB is duplicated between the payload
and the prefix's copies; staging upstream's archives and extracting straight
into the prefix would remove that.

## Kernel and Mesa: no backports

The brief asks for a backports kernel and Mesa. The image uses trixie's.

`trixie-backports` exists and is current, so this is a choice rather than a
blocker. The reasoning: the Phase 0 gate runs against QEMU's virtio-gpu, which
trixie's Mesa drives perfectly well, so backports would add a second apt suite —
and a second source of churn in the one thing that has to stay reliable, the
gate — for no Phase 0 benefit.

Backports earn their place when the image meets real hardware with a GPU, NIC or
storage controller that trixie's kernel does not know about. That is the moment
to add them, and the reason will be concrete enough to write down.

## Domain packages, installed but unused

`winbind`, `libnss-winbind`, `libpam-winbind`, `samba-common-bin` and
`krb5-user` are in the image and nothing uses them. They are staged for Phase 2
so that the join work starts from an image that already has the client bits,
rather than discovering a missing dependency mid-spike.

Note that installing `winbind` enables `winbind.service` and edits
`/etc/nsswitch.conf` on its own. Neither matters with no domain configured, but
it does mean the image is not quite "as if they were not installed".

## Test access

`openssh-server`, with no root password and `PasswordAuthentication no`. The
only way in is the ed25519 key generated by `make image` into `build/ssh/`,
which is gitignored and never committed.

`procps` and `psmisc` are there for the gate's process checks, and `x11-utils`
for `xwininfo`, which is how the gate enumerates windows.
