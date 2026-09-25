# sg-image — the bootable image

mkosi config that builds a Debian trixie disk image which boots straight into
Wine's `explorer` as the shell, plus the Phase 0 boot gate.

Project brief: [`stained-glass/docs/BRIEF.md`](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/BRIEF.md).

## Build and gate

```sh
make deps        # host packages (mkosi, qemu, ovmf, ...)
make image       # build build/sg-image.raw
make boot-test   # boot it headless in QEMU and run the gate
make install-test  # install it from its live entry onto a blank disk, then boot that
make rdp-test    # Remote Desktop into it from this machine (E1)
make dc-test     # make it the SGTEST.LAN domain controller and use it (D2)
make net-test    # NetworkManager: DHCP, static addresses (admins only), Wi-Fi over hwsim
make test        # both
```

### The ISO

`make iso` turns `build/sg-image.raw` into `build/sg-live.iso` (about 1.9 GB,
sudo needed to read the image's root): a hybrid UEFI ISO -- DVD, a VM's CD
drive, or a USB stick -- that boots the live system (try it, or run Setup).
`make iso-test` installs from it as a USB stick (blank disk) and from a CD
drive (beside Windows), then boots each installed disk.

How it boots (`iso/`): the ISO (volume label `SGLIVE`) carries `boot/efi.img`
(the ESP: El Torito image and appended GPT partition) and `live/root.erofs`
(the root, lzma EROFS, label `SGLIVEROOT`). The ESP's only entry is the live
one (`sg.live=iso root=LABEL=SGLIVEROOT systemd.volatile=overlay`) with a
third initrd, `loader/sg-live.initrd`: `iso/sg-live-iso` finds the medium by
probing each block device (blkid's cached search skips optical drives),
attaches the root image to a loop device and mounts efi.img at /run/sg-esp.
The plain entry the installer copies lives in `loader/install/`, out of the
boot menu. sg-install's ISO path keys on `sg.live=iso` (sg-session 0.1.0-17).
The compressed root is cached as `build/sg-live-root.erofs` while the image
is unchanged.

Expects **`wine-sg` and `sg-session`** checked out beside this repo; override
with `SG_WINE=` and `SG_SESSION=`. `make image` builds both repos' `.deb`s,
stages them into `build/extra-tree/opt/sg-packages/`, and
`mkosi.postinst.chroot` installs them with `dpkg` in one invocation so it can
order them itself.

The first `wine-sg` build takes about 12 minutes; later ones are incremental,
because `wine-sg` keeps its object tree.

That is deliberately *not* mkosi's `PackageDirectories` mechanism, which only
regenerates its local apt repository when the repository directory's mtime
changes. On repeat builds the `.deb` is copied over an existing file, the
directory mtime does not move, `reprepro` never runs, and apt fails with
`Unable to locate package sg-session` — intermittently, depending on what the
previous build left behind. Extra trees are copied unconditionally, so the
`dpkg` route is deterministic.

## The gate

`test/boot-test.sh` boots the image in QEMU with no display, waits for ssh,
and runs `sg-session-check` in the guest as `sguser`. It **always** captures a
screenshot over QMP, pass or fail, plus the serial log and the guest journal,
into `build/artifacts/`.

It uses KVM when `/dev/kvm` is usable and falls back to TCG with a 6x longer
budget, so it works in CI runners without nested virt.

Knobs: `SG_BOOT_TIMEOUT`, `SG_CHECK_TIMEOUT`, `SG_SSH_PORT`, `SG_VM_MEM`, `SG_SKIP_LOGIN`,
`SG_KEEP_VM` (leave the guest up to inspect a failure over ssh -- the gate
prints the command),
`SG_VM_CPUS`, `SG_IMAGE`, `SG_GUEST_CHECK`.

## Signing in: the real login screen

There is no autologin. greetd shows the Windows-style greeter (ADR 0008) and
**the boot gate signs in by typing**: `test/qmp.py type` and `key` send key
events through QEMU's keyboard, so the user name and password travel the
kernel, libinput, sg-compositor, Wine and PAM — the path a person's typing
takes. Then the usual session checks run.

- **The lab password is generated per build** into `build/lab-password`
  (gitignored, like the ssh key) and never committed. Only its SHA-512 crypt
  hash enters the image, and `mkosi.postinst.chroot` deletes it after applying
  it to `sguser`. Lower-case letters and digits only, so it types as plain keys.
- `qmp.py` refuses characters it has no key for rather than typing something
  else — a wrong character would turn "cannot type" into "wrong password",
  which is a much worse thing to debug.
- `SG_SKIP_LOGIN=1` skips the sign-in step, for checks that do not need a
  session.
- The gate also checks the **session user cannot read `/dev/input`**. Raw input
  access would let any program in the session read keystrokes from the kernel,
  including a password typed at the lock screen, going round the compositor.

## The S2 gate

`make multiuser-test` boots the image and runs `sg-multiuser-check` in the
guest, reusing the same QEMU, ssh and QMP machinery (`SG_GUEST_CHECK=multiuser`).

**It is expected to fail — 0 of 5 clauses today — and that is its job.** It is
deliberately excluded from `make test` and from CI, because a known-red gate
sitting in CI would mask real regressions. Run it on purpose.

See [`stained-glass/docs/s2-wineserver-analysis.md`](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/s2-wineserver-analysis.md).

## The live entry and the install gate

Every image is also its own installation media. `mkosi.postoutput` gives each
boot entry a `-live` twin with `systemd.volatile=overlay`: booted that way the
stick is never written, and its login screen is Setup (sg-session's
`sg-setup`, `sg-installd` and `sg-install`), which also offers **"Try
Stained Glass OS"** -- a live desktop (`sg-live.service`, live boots only)
with "Install Stained Glass OS" on it. It is post-output, editing the
finished image's ESP with mtools, because **mkosi writes the boot entries
after its finalize scripts run** -- a finalize script finds no entries.

On a live boot `var-lib-stained\x2dglass.mount` puts the Wine prefix on a
tmpfs of its own: the live overlay is a fixed fraction of memory, and the
prefix built at boot (~650 MB) filled it.

The installer copies the live root's files into a partition or unallocated
space of the target (see sg-session's CLAUDE.md), so the image carries
`fdisk` (sfdisk), `dosfstools`, `e2fsprogs` and `efibootmgr`.

**Third-party drivers.** The apt sources (`mkosi.extra/etc/apt`) and the
build's `Repositories=` include Debian **non-free** as well as
non-free-firmware, and the image carries `nvidia-detect` (non-free: Debian's
own list of which NVIDIA driver runs which card), `pciutils` and `mokutil`
for sg-session's `sg-drivers`. Setup's "Install third-party drivers" makes
`sg-drivers.service` install what the PC needs at its first boot.

**`make install-test`** is the F5 gate, in two scenarios (each alone:
`make install-blank-test`, `make install-dualboot-test`). Both copy the image,
point the copy's boot menu at the live entry (mtools, no root), boot it with a
second disk, check sg-install's refusals over ssh (the disk it runs from, no
`--yes`), the socket's owner and mode, the live account and the Install
shortcuts, then drive Setup through QEMU's keyboard:

- **blank** (24 GB): the hybrid path -- Try, the live desktop's own session
  gate, Setup opened from the desktop shortcut (windowed), New on the blank
  disk (system partition + the new one), install onto the new partition.
- **dualboot** (32 GB): the disk is built on the host with Windows' layout --
  a 100 MB ESP holding `EFI/Microsoft/Boot/bootmgfw.efi` (random bytes), a
  16 MB MSR, a 4 GB data partition -- and 27 GB unallocated. Setup, full
  screen, installs into the unallocated space. Afterwards the boot manager,
  the MSR and data partitions' bytes and their table entries must be
  identical, a boot partition and a root partition of ours must exist, and
  `loader.conf` must show the menu.

"Restart now" ends the VM; then the installed disk boots **alone** and the
whole boot gate runs as the new owner, plus checks of what the installer did
(host name, machine id, root size, root pinned by PARTUUID and that being the
mounted root, `/etc/kernel/cmdline`, no live entry, no lab or live account, no
installer socket, owner an administrator, host keys, the Debian and Stained
Glass OS package sources with the key, the packages; dualboot: `/boot` is
our XBOOTLDR and the Windows boot manager is still in the ESP), and the
drivers: Debian non-free in the sources, the first-boot service settled (the
VM needs nothing), the real nvidia-detect choosing per device id from fake
PCI listings (a GTX 1050 Ti: nvidia-driver; a Kepler card: nothing, nouveau
stays; no NVIDIA card: nothing), and `apt-get -s` of the NVIDIA set resolving
against the archive when the VM can reach it. On the live system it also
forces Secure Boot on for `sg-drivers --secure-boot-enroll` into a scratch
root: a root-only key, DKMS pointed at it, the enrollment request held by
the firmware (then withdrawn). It uses ssh
port 2223, so it can run beside `make boot-test`, not beside another
install-test. Screenshots of every Setup page are in
`build/artifacts-install-<scenario>/`.

## The network

**NetworkManager** runs the network (systemd-networkd is disabled, in
`mkosi.postinst.chroot` and the preset); every wired adapter gets a DHCP
profile by default, and DNS goes to systemd-resolved
(`mkosi.extra/etc/NetworkManager/conf.d/50-stained-glass.conf`, `dns=systemd-resolved`,
`rc-manager=unmanaged`), which the DC and member roles configure. Wi-Fi:
wpasupplicant, the regulatory database, and the common Wi-Fi firmware from
non-free-firmware (Intel, Realtek, Atheros, Broadcom, MediaTek, misc), about
300 MB, so a laptop's Wi-Fi works at first boot. polkitd enforces sg-session's
rules. Who may change what is sg-session's sg-netd (see its CLAUDE.md).

**`make net-test`** boots the image with two user-mode NICs (each with its
own DHCP) and runs as a standard user (`sgwine`, not `sg-admins`), an
administrator (`sguser`) and an account with no Windows session: DHCP leases
with no configuration; a standard user refused a static address both through
sg-netd and through nmcli; an administrator's static address, gateway
(`proto static`) and DNS, surviving a NetworkManager restart, and DHCP back.
Then Wi-Fi with no hardware: `mac80211_hwsim radios=2`, one radio moved into a
network namespace as an access point (wpa_supplicant AP mode, WPA2-PSK; SSID
with a space and a non-ASCII character, key generated per run and never
written anywhere but a root-only file in the guest's /run) with dnsmasq for
DHCP and a web server; the standard user scans, is refused with a wrong key
(and the network is not remembered), joins, gets a lease, fetches a page
across the air, disconnects, rejoins with the saved key, forgets it, turns
the radio off and on. The key must appear in no log or artifact. Port 2227.
The domain gate sets its private-segment addresses with `sg-netctl` too.

## Things that will bite you

- **`mkosi.postinst.chroot`'s extension is load bearing.** Without `.chroot`
  the script runs in mkosi's sandbox, where `/usr` is the *host's* — `systemctl`
  then reports that `greetd.service` does not exist, and every absolute path
  refers to the wrong system.
- **`systemd.firstboot=off` is not optional.** Without it, the first boot of a
  fresh image stops dead at `Please configure your system! -- Press any key to
  proceed`, forever, on a machine with nobody at the keyboard. The gate's
  screenshot is how this was found; the serial log just stopped.
- **The Wine prefix is built on first boot, not baked into the image.** The
  image build's `/var` is not the image's `/var`, so a prefix written there at
  build time is liable to be discarded — and a "baked" prefix that silently
  is not there is worse than no bake. `sg-prefix-init.service` does it at boot,
  ordered before greetd, and the gate's timeouts account for it.
- **`adduser` cannot chown in an unprivileged user namespace.** That is where
  image builders run, so `sg-session` creates its user with `--no-create-home`
  and leaves the directories to `tmpfiles.d`.

## Deliberate choices

- **Pure amd64, no i386 multiarch — and 32-bit Windows applications still
  run**, because the image ships `wine-sg` built with
  `--enable-archs=i386,x86_64` rather than a distribution Wine. See ADR 0005.
  The gate proves it by launching `syswow64\notepad.exe` into the shell.
- **`wine-sg`, not Debian's Wine.** This also made the image *smaller*: 454 MB
  for both architectures against Debian's 717 MB + 601 MB. See `docs/packages.md`.
- **cage + XWayland + winex11**, not winewayland. See ADR 0003.
- **No backports yet**, despite the brief asking for a backports kernel and
  Mesa. QEMU's virtio-gpu is served fine by trixie's Mesa, and adding a second
  suite adds risk to the gate for no Phase 0 benefit. Revisit when real hardware
  needs it — that is what backports are actually for here.
- **DXVK and VKD3D-Proton come from upstream, not Debian.** Debian's DXVK ships
  `.dll.so` ELF builtins, whose 32-bit half would need the i386 multiarch we
  removed; upstream ships PE DLLs, the right shape for new WoW64. VKD3D-Proton
  was never packaged. `make d3d` fetches both with pinned hashes into
  `/opt/sg-d3d`; `make d3d-test` proves a D3D11 and D3D12 device can actually
  be created in the guest, on both architectures. See `docs/packages.md`.
- **PowerShell 7 and Python come from upstream too**: `make apps` stages the
  pinned Windows builds in `/opt/sg-apps`, sg-session installs them into the
  prefix, and `make apps-test` proves both run from the user's PATH. See
  `docs/packages.md`.
- **Wine Mono and Gecko are staged too** (`make addons`), unpacked into
  `/usr/share/wine` where Wine runs them in place, so .NET Framework programs
  and HTML-based UI work and the prefix build never prompts for a download.
- **The image carries Debian's apt sources** (`mkosi.extra/etc/apt`). mkosi's
  own build-time apt configuration is not left in the image, so before this an
  installed machine had no package sources at all.
- **The package repository is published from here**: `make publish` builds
  `https://freesoft.page/apt` from the staged `.deb`s, signs it with
  the key in `~/.sgkeys` (never in a repository), checks it with apt (and that a
  tampered index is rejected), and replaces the live site with one orphan
  commit. The image trusts only that key, pinned to that source. **apt upgrades
  only to a higher version**: publishing refuses a changed package whose version
  did not change -- bump the package's `debian/changelog`.
- **Staged updates are gated by `make update-test`**: it reboots the guest
  twice (no `-no-reboot`), so never run it alongside another boot test -- they
  share the ssh port.
- **No `debian/` in this repo.** The artifact here is a disk image, not a
  package. The brief's "packaging from day one" rule is about code repos.

## Secrets

`make image` generates a throwaway ed25519 key into `build/ssh/` for the gate to
log in with. **`build/` is gitignored and must stay that way.** No key, test or
otherwise, gets committed.

The image has no root password and `PasswordAuthentication no`. It is a
disposable lab machine, reachable only with that generated key.

## License

**AGPL-3.0-or-later.** See [ADR 0004](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/decisions/0004-licensing.md).
