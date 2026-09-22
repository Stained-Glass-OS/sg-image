# sg-image — the bootable image

mkosi config that builds a Debian trixie disk image which boots straight into
Wine's `explorer` as the shell, plus the Phase 0 boot gate.

Project brief: [`stained-glass/docs/BRIEF.md`](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/BRIEF.md).

## Build and gate

```sh
make deps        # host packages (mkosi, qemu, ovmf, ...)
make image       # build build/sg-image.raw
make boot-test   # boot it headless in QEMU and run the gate
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

Knobs: `SG_BOOT_TIMEOUT`, `SG_CHECK_TIMEOUT`, `SG_SSH_PORT`, `SG_VM_MEM`,
`SG_VM_CPUS`, `SG_IMAGE`, `SG_GUEST_CHECK`.

## The S2 gate

`make multiuser-test` boots the image and runs `sg-multiuser-check` in the
guest, reusing the same QEMU, ssh and QMP machinery (`SG_GUEST_CHECK=multiuser`).

**It is expected to fail — 0 of 5 clauses today — and that is its job.** It is
deliberately excluded from `make test` and from CI, because a known-red gate
sitting in CI would mask real regressions. Run it on purpose.

See [`stained-glass/docs/s2-wineserver-analysis.md`](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/s2-wineserver-analysis.md).

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
- **Neither DXVK nor VKD3D-Proton is in the image.** Debian's DXVK ships
  `.dll.so` ELF builtins, whose 32-bit half would need the i386 multiarch we
  just removed; upstream DXVK ships PE DLLs, which are the right shape for new
  WoW64. VKD3D-Proton was never packaged. See `docs/packages.md` and issue #6.
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
