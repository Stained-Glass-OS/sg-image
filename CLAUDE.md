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
make test        # both
```

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
`sg-setup`, `sg-installd` and `sg-install`). It is post-output, editing the
finished image's ESP with mtools, because **mkosi writes the boot entries
after its finalize scripts run** -- a finalize script finds no entries.

On a live boot `var-lib-stained\x2dglass.mount` puts the Wine prefix on a
tmpfs of its own: the live overlay is a fixed fraction of memory, and the
prefix built at boot (~650 MB) filled it.

**`make install-test`** is the F5 gate: it copies the image, points the copy's
boot menu at the live entry (mtools, no root), boots it with a blank 24 GB
disk, checks sg-install's refusals over ssh, drives Setup through QEMU's
keyboard onto the blank disk, lets "Restart now" end the VM, then boots the
installed disk **alone** and runs the whole boot gate there as the new owner,
plus checks of what the installer did (host name, machine id, root grown, no
live entry, no lab account, owner an administrator, host keys). It uses ssh
port 2223, so it can run beside `make boot-test`, not beside another
install-test.

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
  `https://stained-glass-os.github.io/apt` from the staged `.deb`s, signs it with
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
