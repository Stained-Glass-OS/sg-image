# sg-image -- the bootable Stained Glass OS image.
#
#   make image      build build/sg-image.raw
#   make boot-test  boot it headless in QEMU and run the Phase 0 gate
#   make test       both, in that order
#
# 'make image' needs network and either root or working user namespaces.
# 'make boot-test' needs qemu + OVMF, and is much faster with /dev/kvm.

SHELL       := /bin/bash
BUILD       := build
IMAGE       := $(BUILD)/sg-image.raw
SSH_KEY     := $(BUILD)/ssh/id_ed25519
EXTRA_TREE  := $(BUILD)/extra-tree
SG_SESSION  ?= ../sg-session
SG_WINE     ?= ../wine-sg
SG_COMPOSITOR ?= ../sg-compositor
SG_SHELL    ?= ../sg-shell

.PHONY: fileaccess-test token-test procagent-test elevate-test policy-test privilege-test addons apps apps-test update-test repo repo-check publish lab-password compositor-deb shell-deb all image boot-test multiuser-test d3d-test test deps sshkey staged-debs session-deb wine-deb d3d clean distclean

all: image

# --- inputs ----------------------------------------------------------------

# A throwaway key for lab access. Generated, never committed: the image is a
# disposable test machine, but a checked-in private key is still a bad habit.
sshkey: $(SSH_KEY)
$(SSH_KEY):
	@mkdir -p $(dir $@)
	ssh-keygen -t ed25519 -N '' -C 'sg-image boot gate (test only)' -f $@
	@mkdir -p $(EXTRA_TREE)/root/.ssh
	@install -m 0600 $@.pub $(EXTRA_TREE)/root/.ssh/authorized_keys
	@echo "ssh key ready: $@"

# Everything ships as a .deb. Build them from the sibling checkouts and drop
# them where the image build will pick them up.
#
# staged-debs is what image depends on; it clears the staging directory once,
# then each package target adds to it.
staged-debs: $(SSH_KEY) lab-password
	@mkdir -p $(EXTRA_TREE)/opt/sg-packages
	@rm -f $(EXTRA_TREE)/opt/sg-packages/*.deb
	$(MAKE) wine-deb compositor-deb shell-deb session-deb
	@echo "staged for the image:"; ls -1 $(EXTRA_TREE)/opt/sg-packages/

# wine-sg is the reason this image can run 32-bit Windows applications without
# i386 multiarch. The first build takes about 12 minutes; later ones are
# incremental, since wine-sg keeps its object tree.
wine-deb:
	@test -d $(SG_WINE) || { \
		echo "wine-sg checkout not found at $(SG_WINE)."; \
		echo "clone it beside this repo, or set SG_WINE=/path/to/wine-sg"; \
		exit 1; }
	$(MAKE) -C $(SG_WINE) deb
	@mkdir -p $(EXTRA_TREE)/opt/sg-packages
	@cp $(SG_WINE)/../wine-sg_*_amd64.deb $(EXTRA_TREE)/opt/sg-packages/

session-deb:
	@test -d $(SG_SESSION) || { \
		echo "sg-session checkout not found at $(SG_SESSION)."; \
		echo "clone it beside this repo, or set SG_SESSION=/path/to/sg-session"; \
		exit 1; }
	$(MAKE) -C $(SG_SESSION) deb
	@mkdir -p $(EXTRA_TREE)/opt/sg-packages
	@# The newest build, by name and architecture. sg-session became
	@# Architecture: any; a glob for the old _all package would silently ship a
	@# stale build left in the parent directory.
	@cp "$$(ls -t $(SG_SESSION)/../sg-session_*_amd64.deb | head -1)" $(EXTRA_TREE)/opt/sg-packages/

shell-deb:
	@test -d $(SG_SHELL) || { \
		echo "sg-shell checkout not found at $(SG_SHELL)."; \
		echo "clone it beside this repo, or set SG_SHELL=/path/to/sg-shell"; \
		exit 1; }
	$(MAKE) -C $(SG_SHELL) deb
	@mkdir -p $(EXTRA_TREE)/opt/sg-packages
	@cp "$$(ls -t $(SG_SHELL)/../sg-shell_*_all.deb | head -1)" $(EXTRA_TREE)/opt/sg-packages/

compositor-deb:
	@test -d $(SG_COMPOSITOR) || { \
		echo "sg-compositor checkout not found at $(SG_COMPOSITOR)."; \
		echo "clone it beside this repo, or set SG_COMPOSITOR=/path/to/sg-compositor"; \
		exit 1; }
	$(MAKE) -C $(SG_COMPOSITOR) deb
	@mkdir -p $(EXTRA_TREE)/opt/sg-packages
	@cp "$$(ls -t $(SG_COMPOSITOR)/../sg-compositor_*_amd64.deb | head -1)" $(EXTRA_TREE)/opt/sg-packages/

# The lab user's password. Generated per build into build/ (gitignored, like
# the ssh key) and never committed; only its SHA-512 crypt hash enters the
# image, and mkosi.postinst.chroot deletes that after applying it. The boot
# gate reads the password from here to log in through the real login screen.
# Lower-case letters and digits only, so the gate can type it as plain keys.
LAB_PASSWORD := $(BUILD)/lab-password
$(LAB_PASSWORD):
	@mkdir -p $(dir $@)
	@umask 077; head -c 64 /dev/urandom | tr -dc 'a-z0-9' | head -c 20 > $@
	@echo "lab password generated: $@"

lab-password: $(LAB_PASSWORD)
	@mkdir -p $(EXTRA_TREE)/root
	@umask 077; openssl passwd -6 -stdin < $(LAB_PASSWORD) > $(EXTRA_TREE)/root/.sg-lab-password-hash

# --- Direct3D --------------------------------------------------------------

# DXVK and VKD3D-Proton, as upstream PE DLLs.
#
# Not Debian's dxvk packages: those ship `.dll.so` ELF builtins laid out for an
# old-WoW64 Wine, which this image does not have. VKD3D-Proton was never
# packaged at all. Upstream ships exactly the right shape -- PE DLLs in x64 and
# x32/x86 -- so they are fetched and staged rather than built.
#
# Each staged payload's stamp depends on this Makefile, so changing a pinned
# version or hash re-stages it; without that, a version bump was silently
# ignored and the old payload shipped.
#
# Versions and hashes are pinned. A release that does not match its hash is a
# build failure, not a warning: this is third-party binary code going into an
# image people log into.
VKD3D_VERSION := 3.0.1
VKD3D_SHA256  := 3cf2315522af5e43605ef6d3c41dad91387040bf97199934f3f7ab76caaa2f0c
DXVK_VERSION  := 3.1.1
DXVK_SHA256   := 40565b4a724aadc4433fa4e010b4b23916d9b1f1baeee64e17186db94f54e608

D3D_DIR   := $(EXTRA_TREE)/opt/sg-d3d
D3D_CACHE := $(BUILD)/d3d-cache

d3d: $(D3D_DIR)/VERSION

$(D3D_DIR)/VERSION: Makefile
	@mkdir -p $(D3D_CACHE) $(D3D_DIR)
	@rm -rf $(D3D_DIR)/dxvk $(D3D_DIR)/vkd3d-proton
	@set -e; \
	v=$(D3D_CACHE)/vkd3d-proton-$(VKD3D_VERSION).tar.zst; \
	d=$(D3D_CACHE)/dxvk-$(DXVK_VERSION).tar.gz; \
	[ -f $$v ] || curl -sSL --retry 3 -o $$v \
	  https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v$(VKD3D_VERSION)/vkd3d-proton-$(VKD3D_VERSION).tar.zst; \
	[ -f $$d ] || curl -sSL --retry 3 -o $$d \
	  https://github.com/doitsujin/dxvk/releases/download/v$(DXVK_VERSION)/dxvk-$(DXVK_VERSION).tar.gz; \
	echo "$(VKD3D_SHA256)  $$v" | sha256sum -c - ; \
	echo "$(DXVK_SHA256)  $$d" | sha256sum -c - ; \
	tmp=$$(mktemp -d); \
	tar --zstd -C $$tmp -xf $$v; \
	tar -C $$tmp -xzf $$d; \
	mkdir -p $(D3D_DIR)/vkd3d-proton $(D3D_DIR)/dxvk; \
	cp -r $$tmp/vkd3d-proton-$(VKD3D_VERSION)/x64 $$tmp/vkd3d-proton-$(VKD3D_VERSION)/x86 $(D3D_DIR)/vkd3d-proton/; \
	cp -r $$tmp/dxvk-$(DXVK_VERSION)/x64 $$tmp/dxvk-$(DXVK_VERSION)/x32 $(D3D_DIR)/dxvk/; \
	rm -rf $$tmp
	@cp licenses/vkd3d-proton.LICENSE $(D3D_DIR)/vkd3d-proton/LICENSE
	@cp licenses/dxvk.LICENSE $(D3D_DIR)/dxvk/LICENSE
	@echo "vkd3d-proton $(VKD3D_VERSION), dxvk $(DXVK_VERSION)" > $@
	@echo "staged D3D: $$(cat $@)"

# --- bundled Windows applications -------------------------------------------

# PowerShell 7 and CPython, as upstream's own Windows builds. sg-session's
# sg-install-apps copies them into the prefix's Program Files, puts them on the
# machine PATH and in the Start menu; sg-apps-check is the gate.
#
# PowerShell is MIT and ships its LICENSE.txt and ThirdPartyNotices.txt; Python
# is the PSF licence and ships LICENSE.txt. Both stay with the payload.
#
# Python comes from python.org's NuGet package, not its installer: the
# installer is a WiX bootstrapper that would have to run silently under Wine at
# first boot, while the NuGet package is the complete install layout (stdlib,
# pip, venv) meant for exactly this kind of installer-free deployment.
#
# Versions and hashes are pinned, and a mismatch fails the build -- as for D3D.
PWSH_VERSION   := 7.6.6
PWSH_SHA256    := 02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860
PYTHON_VERSION := 3.14.7
PYTHON_SHA256  := 46a4da5529a92d18ff894911f6e6033a8253198d705b8161bf28c9123c87d46b

APPS_DIR   := $(EXTRA_TREE)/opt/sg-apps
APPS_CACHE := $(BUILD)/apps-cache

apps: $(APPS_DIR)/VERSION

$(APPS_DIR)/VERSION: Makefile
	@mkdir -p $(APPS_CACHE) $(APPS_DIR)
	@rm -rf $(APPS_DIR)/powershell $(APPS_DIR)/python
	@set -e; \
	p=$(APPS_CACHE)/PowerShell-$(PWSH_VERSION)-win-x64.zip; \
	y=$(APPS_CACHE)/python-$(PYTHON_VERSION).nupkg; \
	[ -f $$p ] || curl -sSL --retry 3 -o $$p \
	  https://github.com/PowerShell/PowerShell/releases/download/v$(PWSH_VERSION)/PowerShell-$(PWSH_VERSION)-win-x64.zip; \
	[ -f $$y ] || curl -sSL --retry 3 -o $$y \
	  https://www.nuget.org/api/v2/package/python/$(PYTHON_VERSION); \
	echo "$(PWSH_SHA256)  $$p" | sha256sum -c - ; \
	echo "$(PYTHON_SHA256)  $$y" | sha256sum -c - ; \
	tmp=$$(mktemp -d); \
	unzip -q $$p -d $(APPS_DIR)/powershell; \
	unzip -q $$y 'tools/*' -d $$tmp; \
	mv $$tmp/tools $(APPS_DIR)/python; \
	rm -rf $$tmp; \
	chmod -R u=rwX,go=rX $(APPS_DIR)/powershell $(APPS_DIR)/python
	@echo "$(PYTHON_VERSION)" > $(APPS_DIR)/python/SG_VERSION
	@echo "powershell $(PWSH_VERSION), python $(PYTHON_VERSION)" > $@
	@echo "staged apps: $$(cat $@)"

# --- Wine's .NET Framework and HTML engine ------------------------------------

# Wine Mono (a .NET Framework implementation) and Wine Gecko (the HTML engine
# behind mshtml), at exactly the versions wine-sg's Wine expects. Without them
# every .NET Framework program fails and anything that embeds HTML -- installers,
# help, sign-in pages -- shows nothing.
#
# Unpacked, as Linux distributions ship them, not as MSIs: Wine finds
# /usr/share/wine/mono/wine-mono-<ver> and /usr/share/wine/gecko/wine-gecko-<ver>-<arch>
# and runs them in place. Nothing is installed per prefix beyond Mono's small
# support files, one root-owned read-only copy serves every prefix and user --
# not even SYSTEM can modify it -- and nothing can be half-installed. (The MSI
# route was tried first: Gecko installs lazily, on first use of mshtml, so the
# image booted with Mono installed and Gecko not.)
#
# Both Gecko architectures: 32-bit programs use the 32-bit engine. Hashes are
# pinned; Wine's own addons.c pins only the MSIs, so these are the tarballs'
# measured on download from dl.winehq.org. Licences: Wine Mono is MIT, with some
# components under their own free licences; Wine Gecko is MPL-2.0.
MONO_VERSION       := 9.4.0
MONO_SHA256        := fd772219aacf46b825fa891a647af4a9ddf8439320101c231918b2037bf13858
GECKO_VERSION      := 2.47.4
GECKO_X86_SHA256   := 2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6
GECKO_X64_SHA256   := fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814

ADDONS_DIR   := $(EXTRA_TREE)/usr/share/wine
ADDONS_CACHE := $(BUILD)/addons-cache

addons: $(ADDONS_DIR)/.sg-addons

$(ADDONS_DIR)/.sg-addons: Makefile
	@rm -rf $(ADDONS_DIR)/mono $(ADDONS_DIR)/gecko
	@mkdir -p $(ADDONS_CACHE) $(ADDONS_DIR)/mono $(ADDONS_DIR)/gecko
	@set -e; c=$(CURDIR)/$(ADDONS_CACHE); d=$(CURDIR)/$(ADDONS_DIR); \
	m=wine-mono-$(MONO_VERSION)-x86.tar.xz; \
	g32=wine-gecko-$(GECKO_VERSION)-x86.tar.xz; \
	g64=wine-gecko-$(GECKO_VERSION)-x86_64.tar.xz; \
	[ -f $$c/$$m ]   || curl -sSL --retry 3 -o $$c/$$m   https://dl.winehq.org/wine/wine-mono/$(MONO_VERSION)/$$m; \
	[ -f $$c/$$g32 ] || curl -sSL --retry 3 -o $$c/$$g32 https://dl.winehq.org/wine/wine-gecko/$(GECKO_VERSION)/$$g32; \
	[ -f $$c/$$g64 ] || curl -sSL --retry 3 -o $$c/$$g64 https://dl.winehq.org/wine/wine-gecko/$(GECKO_VERSION)/$$g64; \
	echo "$(MONO_SHA256)  $$c/$$m" | sha256sum -c - ; \
	echo "$(GECKO_X86_SHA256)  $$c/$$g32" | sha256sum -c - ; \
	echo "$(GECKO_X64_SHA256)  $$c/$$g64" | sha256sum -c - ; \
	tar -C $$d/mono -xJf $$c/$$m; \
	tar -C $$d/gecko -xJf $$c/$$g32; \
	tar -C $$d/gecko -xJf $$c/$$g64; \
	chmod -R u=rwX,go=rX $$d/mono $$d/gecko
	@echo "wine-mono $(MONO_VERSION), wine-gecko $(GECKO_VERSION)" > $@
	@echo "staged addons: $$(cat $@)"

# --- package repository --------------------------------------------------------

# The signed apt repository, https://stained-glass-os.github.io/apt (stained-glass
# docs/package-repository.md). Signed here with the key in ~/.sgkeys; no CI
# system holds it.
#
#   make repo         build and sign it into build/apt
#   make repo-check   verify it with apt, as a machine would (and that a
#                     tampered index is rejected)
#   make publish      fetch what is live, rebuild, verify, replace the live site
REPO_DEBS = $(wildcard $(EXTRA_TREE)/opt/sg-packages/*.deb)

repo: staged-debs
	repo/build-repo.sh $(BUILD)/apt $(REPO_DEBS)

repo-check: repo
	repo/check-repo.sh $(BUILD)/apt

publish: staged-debs
	repo/publish.sh $(REPO_DEBS)

# --- image -----------------------------------------------------------------

image: staged-debs d3d apps addons
	mkosi --force
	@ls -lh $(IMAGE)

# --- gate ------------------------------------------------------------------

boot-test:
	test/boot-test.sh

# The S2 gate, driven against a real booted image. Expected to fail until S2
# lands -- see sg-session/bin/sg-multiuser-check. Deliberately not part of
# 'make test': a known-red gate wired into CI would mask real regressions.
multiuser-test:
	SG_GUEST_CHECK=multiuser test/boot-test.sh

# Direct3D through DXVK and VKD3D-Proton, in the guest. Separate from the Phase
# 0 gate because it needs a Vulkan driver, and because Phase 0 is about running
# Windows applications at all rather than about rendering.
d3d-test:
	SG_GUEST_CHECK=d3d test/boot-test.sh

# The bundled Windows applications (PowerShell 7, Python), in the guest.
apps-test:
	SG_GUEST_CHECK=apps test/boot-test.sh

# Users' file access against Unix's verdict (ADR 0013).
fileaccess-test:
	SG_GUEST_CHECK=fileaccess test/boot-test.sh

# Whether an ordinary user's program can obtain an administrator's token (D17).
token-test:
	SG_GUEST_CHECK=token test/boot-test.sh

# Cross-process memory/debug for a user's own processes (D16/D19, ADR 0014).
procagent-test:
	SG_SKIP_LOGIN=1 SG_GUEST_CHECK=procagent test/boot-test.sh

# "Run as administrator" runs as the SYSTEM account, only after consent (ADR 0012).
elevate-test:
	SG_SKIP_LOGIN=1 SG_GUEST_CHECK=elevate test/boot-test.sh

# Machine Group Policy: an admin's policy binds every user, a user cannot override.
policy-test:
	SG_SKIP_LOGIN=1 SG_GUEST_CHECK=policy test/boot-test.sh

# Both privilege-boundary gates in one boot.
privilege-test:
	SG_GUEST_CHECK=privilege test/boot-test.sh

# Staged updates: download while running, install on the next reboot (F3).
# Reboots the guest twice; uses the same ssh port, so never run it alongside
# another boot test.
update-test:
	test/update-test.sh

# F5: install from the live system onto a blank disk, then boot that disk
# alone and sign in as the owner it created (needs sudo for the boot menu).
install-test:
	test/install-test.sh

test: image boot-test

deps:
	sudo apt-get install -y mkosi systemd-repart qemu-system-x86 qemu-utils \
	                        systemd-boot-efi systemd-boot-tools \
	                        ovmf debian-archive-keyring openssh-client \
	                        dosfstools e2fsprogs mtools unzip

clean:
	rm -rf $(BUILD)/run-disk.raw $(BUILD)/run-vars.fd $(BUILD)/artifacts $(BUILD)/qmp.sock
	rm -rf $(EXTRA_TREE)/opt/sg-packages

distclean: clean
	mkosi clean || true
	rm -rf $(BUILD)
