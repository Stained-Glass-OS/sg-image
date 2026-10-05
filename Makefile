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
SG_OFFICE   ?= ../sg-office

.PHONY: image-deps-test mono-config-test mono-fork-test wpf-flow-test mono-deb gecko-deb gecko-test gtk-deb gtk-theme-test splash boot-time-test print-test net-test fileaccess-test token-test procagent-test elevate-test elevated-test policy-test privilege-test addons speech apps apps-test update-test repo repo-check publish lab-password compositor-deb shell-deb office-deb all image boot-test multiuser-test d3d-test test deps sshkey staged-debs session-deb wine-deb d3d d3d-deb dcomp-test ctxstate-test clean distclean

all: image

# --- inputs ----------------------------------------------------------------

# A throwaway key for lab access. Generated, never committed, and never put in
# the image: the gates hand it to their VMs as a systemd credential (QEMU
# -smbios type=11, ssh.authorized_keys.root), so a released image or ISO
# accepts no key and runs no ssh server (mkosi.extra's ssh.service.d).
sshkey: $(SSH_KEY)
$(SSH_KEY):
	@mkdir -p $(dir $@)
	ssh-keygen -t ed25519 -N '' -C 'sg-image boot gate (test only)' -f $@
	@echo "ssh key ready: $@"

# Everything ships as a .deb. Build them from the sibling checkouts and drop
# them where the image build will pick them up.
#
# staged-debs is what image depends on; it clears the staging directory once,
# then each package target adds to it.
staged-debs: $(SSH_KEY) lab-password
	@mkdir -p $(EXTRA_TREE)/opt/sg-packages
	@rm -f $(EXTRA_TREE)/opt/sg-packages/*.deb
	$(MAKE) wine-deb compositor-deb shell-deb session-deb office-deb
	@# The source each package was built from (repo/build-repo.sh publishes it
	@# beside the .deb): a rebuild of an unchanged, already-published version
	@# keeps the published build instead of being refused.
	@for p in wine-sg:$(SG_WINE) sg-compositor:$(SG_COMPOSITOR) sg-shell:$(SG_SHELL) sg-office:$(SG_SHELL) sg-session:$(SG_SESSION) sg-office-editors:$(SG_OFFICE); do \
	  d=$${p#*:}; [ -d "$$d" ] || continue; c=$$(git -C $$d rev-parse HEAD); \
	  git -C $$d diff --quiet HEAD -- . 2>/dev/null || c=$$c-dirty; \
	  echo "$${p%%:*} $$c"; done > $(EXTRA_TREE)/opt/sg-packages/SOURCES
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
	@# The newest version only. Copying every wine-sg_*.deb beside the checkout
	@# made dpkg unpack them all in glob order, and 10.0-9 sorts after 10.0-11:
	@# images shipped an old Wine, silently.
	@cp "$$(ls $(SG_WINE)/../wine-sg_*_amd64.deb | sort -V | tail -1)" $(EXTRA_TREE)/opt/sg-packages/

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
	@# SG Office (built from sg-shell's source): its programs, Get SG Office and
	@# its registrations -- no LibreOffice binary (users fetch that themselves)
	@cp "$$(ls -t $(SG_SHELL)/../sg-office_*_all.deb | head -1)" $(EXTRA_TREE)/opt/sg-packages/

# SG Office's editors (package sg-office-editors, based on ONLYOFFICE): built
# from source by the sg-office repository's debian/rules -- its engines in a
# rootless trixie build root, niced, -j3; a first build takes hours, later ones
# are incremental (its build trees live under /var/tmp/sgoffice) -- then its
# package gate: the .deb installed into a scratch root and the program's gate
# run as installed. sg-shell's sg-office depends on it.
# SG_NO_OFFICE=1 (CI: the editors take hours to build) leaves SG Office out.
# The editors deb of the checkout's version is reused when it is already
# built (every sg-office commit bumps its changelog): the build takes hours
# and nearly ran the host out of memory when a release re-ran it for nothing.
# SG_OFFICE_REBUILD=1 builds it anyway.
# no editors, and sg-shell's sg-office package, which needs them, unstaged.
office-deb:
	@if [ "$(SG_NO_OFFICE)" = 1 ]; then \
		rm -f $(EXTRA_TREE)/opt/sg-packages/sg-office_*.deb; \
		echo "SG_NO_OFFICE=1: SG Office left out of this image"; exit 0; fi; \
	test -d $(SG_OFFICE) || { \
		echo "sg-office checkout not found at $(SG_OFFICE)."; \
		echo "clone it beside this repo, or set SG_OFFICE=/path/to/sg-office"; \
		echo "(or SG_NO_OFFICE=1 for an image without SG Office)"; \
		exit 1; }; \
	ver=$$(dpkg-parsechangelog -l $(SG_OFFICE)/debian/changelog -SVersion) && \
	deb=$(SG_OFFICE)/../sg-office-editors_$${ver}_amd64.deb && \
	if [ -f "$$deb" ] && [ "$(SG_OFFICE_REBUILD)" != 1 ]; then \
		echo "sg-office-editors $$ver already built: reusing $$deb (SG_OFFICE_REBUILD=1 rebuilds)"; \
	else \
		$(MAKE) -C $(SG_OFFICE) deb && $(MAKE) -C $(SG_OFFICE) test-deb; \
	fi && test -f "$$deb" && \
	mkdir -p $(EXTRA_TREE)/opt/sg-packages && \
	rm -f $(EXTRA_TREE)/opt/sg-packages/sg-office-editors_*.deb && \
	cp "$$deb" $(EXTRA_TREE)/opt/sg-packages/

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
# DXVK's dxgi.dll and d3d11.dll are rebuilt from this commit of the tag with
# dxvk/patches (swap chains for composition: Qt Quick and Chromium windows
# were black under DXVK; context states Chromium's WebGPU asks for); the rest
# of DXVK is the release above.
DXVK_COMMIT   := b1a1c99ab52b687cf950d62c88bc2fa316b41663
# ICU for Windows programs (Windows 10 has it in System32: icuuc.dll, icuin.dll,
# icu.dll -- Qt 6's Windows builds and winget use it), built with mingw-w64 from
# Debian's ICU source (icu/build-icu.sh), in the same package.
ICU_VERSION   := 76.1
# our build's revision: raised when icu/build-icu.sh changes what is built (1:
# res_index without the locales .NET cannot use), so sg-d3d's version changes
ICU_SGREV     := 1
ICU_SHA256    := dfacb46bfe4747410472ce3e1144bf28a102feeaa4e3875bac9b4c6cf30f4f3e
ICU_URL       := https://deb.debian.org/debian/pool/main/i/icu/icu_$(ICU_VERSION).orig.tar.gz

# Staged here and packaged as sg-d3d (d3d-deb/build-deb.sh), installed in the
# image and published on the apt site: installed machines get a fixed DXVK
# with their updates, not only machines made from a new image.
D3D_DIR   := $(BUILD)/d3d-payload
D3D_CACHE := $(BUILD)/d3d-cache

d3d: $(D3D_DIR)/VERSION

$(D3D_DIR)/VERSION: Makefile dxvk/build-dxgi.sh $(wildcard dxvk/patches/*.patch) icu/build-icu.sh
	@rm -rf $(EXTRA_TREE)/opt/sg-d3d
	@mkdir -p $(D3D_CACHE) $(D3D_DIR)
	@rm -rf $(D3D_DIR)/dxvk $(D3D_DIR)/vkd3d-proton $(D3D_DIR)/icu
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
	@dxvk/build-dxgi.sh $(DXVK_VERSION) $(DXVK_COMMIT) $(abspath $(D3D_CACHE)) $(abspath $(D3D_DIR)/dxvk)
	@set -e; \
	i=$(D3D_CACHE)/icu_$(ICU_VERSION).orig.tar.gz; \
	[ -f $$i ] || curl -sSL --retry 3 -o $$i $(ICU_URL); \
	echo "$(ICU_SHA256)  $$i" | sha256sum -c - ; \
	c=$(D3D_CACHE)/icu-$(ICU_VERSION)-$$(sha256sum icu/build-icu.sh | cut -c1-8); \
	[ -f $$c/x86_64/icuuc.dll ] || { rm -rf $$c; icu/build-icu.sh $$i $$c x86_64; }; \
	mkdir -p $(D3D_DIR)/icu/x64; \
	cp $$c/x86_64/*.dll $(D3D_DIR)/icu/x64/; \
	cp licenses/icu.LICENSE $(D3D_DIR)/icu/LICENSE
	@echo "vkd3d-proton $(VKD3D_VERSION), dxvk $(DXVK_VERSION)+sg$$(cat dxvk/patches/*.patch | sha256sum | cut -c1-8), icu $(ICU_VERSION)+sg$(ICU_SGREV)" > $@
	@echo "staged D3D: $$(cat $@)"

# The package, beside the other staged debs (staged-debs clears them first).
d3d-deb: staged-debs d3d
	d3d-deb/build-deb.sh $(D3D_DIR) $(EXTRA_TREE)/opt/sg-packages
	@echo "sg-d3d $$( { cat d3d-deb/build-deb.sh $(D3D_DIR)/VERSION; } | sha256sum | cut -c1-40)" \
	  >> $(EXTRA_TREE)/opt/sg-packages/SOURCES

# A composition swap chain made through our DXVK shows in its window (host
# test; WINE= a current wine-sg: DirectComposition is wine-sg's).
dcomp-test: d3d
	@test/dcomp-test.sh

# Context states Chromium's WebGPU asks for (dxvk/patches/0002).
ctxstate-test: d3d
	@test/ctxstate-test.sh

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
# Packaged (sg-wine-mono, sg-wine-gecko), unpacked as Linux distributions
# ship them, not as MSIs: Wine finds
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
#
# Wine Mono is our build of it: upstream 9.4.0 with mono/patches (what the
# athenaNet Device Manager and SQL Server Compact need, WPF's flow layout for
# rich text; mono/patches/README),
# built by mono/build-wine-mono.sh and served from the project's server. The
# upstream tarball (dl.winehq.org, sha256 fd772219...bf13858) is what it
# replaces; test/mono-fork-test.sh tells them apart.
MONO_VERSION       := 9.4.0
MONO_BUILD         := sg5
MONO_URL           := https://freesoft.page/addons/wine-mono-$(MONO_VERSION)-$(MONO_BUILD)-x86.tar.xz
MONO_SHA256        := 4a24dbaf53cb811d63bd1fdbfa8d7af45b7cf1d09b7569bb9aea55f0ee3ea78c
GECKO_VERSION      := 2.47.4
GECKO_X86_SHA256   := 2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6
GECKO_X64_SHA256   := fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814

ADDONS_DIR   := $(EXTRA_TREE)/usr/share/wine
ADDONS_CACHE := $(BUILD)/addons-cache

# Both are packages now (sg-wine-mono, sg-wine-gecko), so updates carry them
# (David 2026-10-01: every update arrives through apt). An older build's loose
# copies must not stay in the extra tree beside them.
addons:
	@rm -rf $(ADDONS_DIR)/mono $(ADDONS_DIR)/gecko $(ADDONS_DIR)/.sg-addons

# Wine Gecko as the Debian package sg-wine-gecko (gecko/build-deb.sh):
# upstream's tarballs, both architectures, unmodified.
GECKO_X86_TARBALL := $(ADDONS_CACHE)/wine-gecko-$(GECKO_VERSION)-x86.tar.xz
GECKO_X64_TARBALL := $(ADDONS_CACHE)/wine-gecko-$(GECKO_VERSION)-x86_64.tar.xz
GECKO_ROOT        := $(BUILD)/gecko-deb-root

$(GECKO_X86_TARBALL):
	@mkdir -p $(ADDONS_CACHE)
	curl -sSL --retry 3 -o $@.part https://dl.winehq.org/wine/wine-gecko/$(GECKO_VERSION)/$(notdir $@)
	echo "$(GECKO_X86_SHA256)  $@.part" | sha256sum -c -
	mv $@.part $@

$(GECKO_X64_TARBALL):
	@mkdir -p $(ADDONS_CACHE)
	curl -sSL --retry 3 -o $@.part https://dl.winehq.org/wine/wine-gecko/$(GECKO_VERSION)/$(notdir $@)
	echo "$(GECKO_X64_SHA256)  $@.part" | sha256sum -c -
	mv $@.part $@

gecko-deb: staged-debs $(GECKO_X86_TARBALL) $(GECKO_X64_TARBALL)
	@echo "$(GECKO_X86_SHA256)  $(GECKO_X86_TARBALL)" | sha256sum -c - >/dev/null
	@echo "$(GECKO_X64_SHA256)  $(GECKO_X64_TARBALL)" | sha256sum -c - >/dev/null
	gecko/build-deb.sh $(GECKO_VERSION) $(GECKO_X86_TARBALL) $(GECKO_X64_TARBALL) $(EXTRA_TREE)/opt/sg-packages
	@echo "sg-wine-gecko $$( { echo $(GECKO_X86_SHA256) $(GECKO_X64_SHA256); cat gecko/build-deb.sh; } | sha256sum | cut -c1-40)" \
	  >> $(EXTRA_TREE)/opt/sg-packages/SOURCES

# The package's tree, for the gate below (no other package is built)
$(GECKO_ROOT)/.done: $(GECKO_X86_TARBALL) $(GECKO_X64_TARBALL) gecko/build-deb.sh
	@rm -rf $(GECKO_ROOT) $(BUILD)/gecko-deb
	gecko/build-deb.sh $(GECKO_VERSION) $(GECKO_X86_TARBALL) $(GECKO_X64_TARBALL) $(BUILD)/gecko-deb
	dpkg-deb -x $(BUILD)/gecko-deb/sg-wine-gecko_*_all.deb $(GECKO_ROOT)
	@touch $@

# mshtml renders HTML with the packaged engine, 32- and 64-bit.
gecko-test: $(GECKO_ROOT)/.done
	SG_GECKO_DIR=$(GECKO_ROOT)/usr/share/wine/gecko sh test/gecko-test.sh

# Wine Mono as the Debian package sg-wine-mono (mono/build-deb.sh): installed
# in the image and published on the apt site, so machines installed before a
# Mono fix get it with their updates (sg-session depends on it). Rebuilt every
# time (staged-debs clears the staging directory); the tarball is cached.
MONO_TARBALL := $(ADDONS_CACHE)/wine-mono-$(MONO_VERSION)-$(MONO_BUILD)-x86.tar.xz
MONO_ROOT    := $(BUILD)/mono-deb-root

$(MONO_TARBALL):
	@mkdir -p $(ADDONS_CACHE)
	curl -sSL --retry 3 -o $@.part $(MONO_URL)
	echo "$(MONO_SHA256)  $@.part" | sha256sum -c -
	mv $@.part $@

mono-deb: staged-debs $(MONO_TARBALL)
	@echo "$(MONO_SHA256)  $(MONO_TARBALL)" | sha256sum -c - >/dev/null
	mono/build-deb.sh $(MONO_TARBALL) $(EXTRA_TREE)/opt/sg-packages
	@# Its source: the tarball, the fixes and the packaging script.
	@echo "sg-wine-mono $$( { echo $(MONO_SHA256); cat mono/mono-fixes.sh mono/build-deb.sh; } | sha256sum | cut -c1-40)" \
	  >> $(EXTRA_TREE)/opt/sg-packages/SOURCES

# The package's tree, for the gates below (no other package is built)
$(MONO_ROOT)/.done: $(MONO_TARBALL) mono/build-deb.sh mono/mono-fixes.sh
	@rm -rf $(MONO_ROOT) $(BUILD)/mono-deb
	mono/build-deb.sh $(MONO_TARBALL) $(BUILD)/mono-deb
	dpkg-deb -x $(BUILD)/mono-deb/sg-wine-mono_*_all.deb $(MONO_ROOT)
	@touch $@

# Wine Mono with the image's fixes runs a WinForms program's .config
# (Greenshot's DpiAwareness section); test/mono-config-test.sh.
mono-config-test: $(MONO_ROOT)/.done
	SG_MONO_DIR=$(MONO_ROOT)/usr/share/wine/mono sh test/mono-config-test.sh

# Our Wine Mono's fixes (mono/patches): event log types, the certificate
# store, <startup> twice, UserInteractive in a service, NDP v4 InstallPath.
mono-fork-test: $(MONO_ROOT)/.done
	SG_MONO_DIR=$(MONO_ROOT)/usr/share/wine/mono sh test/mono-fork-test.sh

# WPF's flow layout (rich text: FlowDocument, RichTextBox) in our Mono (wpf-*.patch)
wpf-flow-test: $(MONO_ROOT)/.done
	SG_MONO_DIR=$(MONO_ROOT)/usr/share/wine/mono sh test/wpf-flow-test.sh

# --- Linux programs' look ------------------------------------------------------

# sg-gtk-theme (gtk-theme/build-deb.sh, sg-gtk3.css, sg-gtk4.css): Orchis in
# Stained Glass purple, light and dark, made to look like the Windows side
# (controls, menus, scroll bars, window buttons, Inter 9 pt), the system's GTK
# theme -- Linux programs looked plain beside the Windows side (David
# 2026-10-01). Built from Debian's orchis-gtk-theme at a
# pinned version (cached); installed in the image and published, and
# sg-session depends on it, so updates carry it.
GTK_THEME_CACHE := $(BUILD)/gtk-theme-cache

gtk-deb: staged-debs
	gtk-theme/build-deb.sh $(GTK_THEME_CACHE) $(EXTRA_TREE)/opt/sg-packages
	@echo "sg-gtk-theme $$(cat gtk-theme/build-deb.sh gtk-theme/sg-gtk3.css gtk-theme/sg-gtk4.css | sha256sum | cut -c1-40)" >> $(EXTRA_TREE)/opt/sg-packages/SOURCES

gtk-theme-test:
	sh test/gtk-theme-test.sh

image-deps-test:
	sh test/image-deps-test.sh $(EXTRA_TREE)/opt/sg-packages

# --- voice typing's speech model ---------------------------------------------

# Parakeet TDT 0.6B v3 (int8 ONNX, CC BY 4.0) and Silero VAD (MIT), 642 MB, as
# the Debian package sg-speech-model-parakeet (speech-model/build-deb.sh):
# installed in the image so Win+H works out of the box and offline, and
# published on the apt site like any package. A machine without it still gets
# the model from sg-speechd on first use.
#
# The file list, pinned revisions and SHA-256s are sg-session's sgspeech.FILES,
# fetched by sg-dictate's own fetch_model into a cache: one definition of "the
# model is complete", shared with sg-speechd.
SPEECH_CACHE := $(BUILD)/speech-cache

# Rebuilt every time (staged-debs clears the staging directory); the download
# is cached, so that is a minute of packaging, not a download.
speech: staged-debs
	@rm -rf $(EXTRA_TREE)/var/lib/stained-glass-speech
	speech-model/build-deb.sh $(SG_SESSION) $(SPEECH_CACHE) $(EXTRA_TREE)/opt/sg-packages
	@# Its source is the pinned file list (names, sizes, SHA-256s) and the
	@# packaging script -- not the rest of sgspeech.py, which changes with code.
	@echo "sg-speech-model-parakeet $$( { cat speech-model/build-deb.sh; SG_SPEECH_LIB=$(SG_SESSION)/speech python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import sgspeech; print(sgspeech.MODEL_NAME, sgspeech.FILES)' $(SG_SESSION)/speech; } | sha256sum | cut -c1-40)" \
	  >> $(EXTRA_TREE)/opt/sg-packages/SOURCES

# --- package repository --------------------------------------------------------

# The signed apt repository, https://freesoft.page/apt (stained-glass
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

publish: staged-debs speech d3d-deb mono-deb gecko-deb gtk-deb
	repo/publish.sh $(REPO_DEBS)

# --- the boot splash ---------------------------------------------------------

# The Plymouth theme is sg-session's (its splash/: the script, and pictures it
# draws at build time), so installed machines get it with their updates. The
# image's boot entries carry it in an initrd of their own (mkosi.postoutput),
# which reads it from the extra tree: taken here from the staged package.
SPLASH_DIR := $(EXTRA_TREE)/usr/share/plymouth/themes/stained-glass

splash: staged-debs
	@deb=$$(ls -t $(EXTRA_TREE)/opt/sg-packages/sg-session_*_amd64.deb | head -1); \
	  test -n "$$deb" || { echo "splash: no staged sg-session package"; exit 1; }; \
	  rm -rf $(SPLASH_DIR); mkdir -p $(EXTRA_TREE); \
	  dpkg-deb --fsys-tarfile "$$deb" | tar -x -C $(EXTRA_TREE) ./usr/share/plymouth/themes/stained-glass \
	  && test -f $(SPLASH_DIR)/stained-glass.script && test -f $(SPLASH_DIR)/diamond.png \
	  || { echo "splash: $$deb has no Stained Glass theme"; exit 1; }
	@# and inside the source tree, for mkosi.postoutput's initrd: build/ is a
	@# symlink in the release worktrees, which mkosi's sandbox cannot follow
	@rm -rf .splash && mkdir -p .splash/usr/share/plymouth/themes && \
	  cp -r $(SPLASH_DIR) .splash/usr/share/plymouth/themes/

# --- image -----------------------------------------------------------------

image: staged-debs d3d-deb apps addons mono-deb gecko-deb gtk-deb speech splash
	@# Our packages go in with dpkg: their dependencies must be in mkosi.conf
	@# (or come with what is), else the build fails at its very end.
	sh test/image-deps-test.sh $(EXTRA_TREE)/opt/sg-packages || [ $$? = 77 ]
	@# Older builds put the gate key in the extra tree: it must never ship.
	rm -f $(EXTRA_TREE)/root/.ssh/authorized_keys
	mkosi --force --image-version=$$(date -u +%Y%m%d)-$$(git rev-parse --short HEAD)$$(git diff --quiet HEAD -- . 2>/dev/null || echo -dirty)
	@ls -lh $(IMAGE)

# --- gate ------------------------------------------------------------------

boot-test:
	test/boot-test.sh

# The live ISO's boot, timed and watched: the splash on the screen, no text
# console, and firmware-to-Setup within SG_BOOT_BUDGET seconds (QA B2, B4).
boot-time-test:
	ISO=$(ISO) test/boot-time.sh

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

# Printing: a Windows program prints to the Print to PDF printer (CUPS,
# cups-pdf, sg-session's sg-print-setup) and the PDF lands in Documents.
print-test:
	SG_GUEST_CHECK=print test/boot-test.sh

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

# Elevated programs get a display of their own (ADR 0012, bug B56): a real GUI
# installer that demands administrator rights runs through the consent prompt
# and shows its window, usable with the real keyboard and out of the session's
# reach. Signs in (no SG_SKIP_LOGIN) and drives the prompt and installer with
# QMP; needs makensis and the mingw cross compiler on the host to build the
# fixtures. Installs to Program Files with a Start menu shortcut for the user;
# also "Add someone else to this PC".
elevated-test:
	SG_GUEST_CHECK=elevated test/boot-test.sh

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
	SG_INSTALL_SCENARIO=blank test/install-test.sh
	SG_INSTALL_SCENARIO=dualboot test/install-test.sh

# One scenario of it: the hybrid path onto a blank disk, or beside Windows.
.PHONY: install-blank-test install-dualboot-test
install-blank-test:
	SG_INSTALL_SCENARIO=blank test/install-test.sh
install-dualboot-test:
	SG_INSTALL_SCENARIO=dualboot test/install-test.sh

# The ISO: the finished image as a hybrid UEFI ISO (DVD, a VM's CD drive, or a
# USB stick) that boots the live system -- try it, or install from it. Built
# from build/sg-image.raw; needs sudo to read its root file system.
ISO := $(BUILD)/sg-live.iso
.PHONY: iso iso-test
iso:
	iso/build-iso.sh $(IMAGE) $(ISO)

# Install from the ISO as a USB stick (blank disk), then from a CD drive
# (beside Windows): the same gate as install-test, from the other medium; and
# booted from a Ventoy-style multiboot stick (the .iso as a file on exFAT).
iso-test:
	SG_LIVE_ISO=$(ISO) SG_LIVE_ISO_AS=disk SG_INSTALL_SCENARIO=blank test/install-test.sh
	SG_LIVE_ISO=$(ISO) SG_LIVE_ISO_AS=cdrom SG_INSTALL_SCENARIO=dualboot test/install-test.sh
	ISO=$(ISO) test/ventoy-test.sh

# Put the ISO on https://freesoft.page/iso/ as sg-live-DATE-TIME-REV.iso (UTC;
# a rebuild of the same sg-image revision with newer packages gets its own name), with its
# SHA-256 in SHA256SUMS and sg-live-latest.iso pointing at it. release.sh does
# this only after the ISO install gates pass. Only the newest ISO is kept (the
# server's disk is small): the others go once the new one is verified.
ISO_HOST ?= root@freesoft.page
ISO_DIR  ?= /srv/www/iso
.PHONY: upload-iso
upload-iso:
	@test -f $(ISO) || { echo "no $(ISO) -- run 'make iso'"; exit 2; }
	@set -e; name=sg-live-$$(date -u +%Y%m%d-%H%M)-$$(git rev-parse --short HEAD).iso; \
	ssh="ssh -i $$HOME/.ssh/sg -o BatchMode=yes"; \
	sum=$$(sha256sum < $(ISO) | cut -d' ' -f1); \
	rsync -a --partial --info=progress2 -e "$$ssh" $(ISO) $(ISO_HOST):$(ISO_DIR)/$$name.part; \
	$$ssh $(ISO_HOST) "cd $(ISO_DIR) && echo '$$sum  $$name.part' | sha256sum -c --quiet - && mv $$name.part $$name \
	  && echo '$$sum  $$name' > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS \
	  && ln -sfn $$name sg-live-latest.iso \
	  && find . -maxdepth 1 -name 'sg-live-*.iso*' ! -name $$name ! -name sg-live-latest.iso -delete \
	  && sg-iso-index"; \
	echo "uploaded https://freesoft.page/iso/$$name (sha256 $$sum)"

# Chrome in a signed-in session, started from Run as a person does, with its
# memory sampled: GPU-process deaths, OOM kills, crash dumps. Chrome is the
# user's to supply (CHROME_DIR, the enterprise MSI unpacked); SG_GPU=virgl
# gives the guest this machine's GPU. An investigation, not a release gate.
.PHONY: chrome-gpu-test
chrome-gpu-test:
	test/chrome-gpu-test.sh

# Remote Desktop (E1): sign in to the image over RDP from this machine with a
# real FreeRDP client; a remote session, its own lock screen, reconnect.
.PHONY: rdp-test
rdp-test:
	test/rdp-test.sh

# The domain controller role (D2): provision SGTEST.LAN in the image and use it
# as a member would -- DNS SRV records, Kerberos, the directory, SMB, a reboot.
.PHONY: dc-test
dc-test:
	test/dc-test.sh

# A domain member (D1) of the image's own DC role: two VMs on a private
# segment, a join, a domain user signed in at the console, single sign-on from
# a Windows program, Domain Admins as administrators.
.PHONY: domain-test
domain-test:
	test/domain-test.sh

# Connectivity (NetworkManager, sg-netd): wired DHCP, static addresses by
# administrators only, and Wi-Fi joined by a standard user, over a simulated
# radio pair with an access point of the test's own.
net-test:
	test/net-test.sh

test: image boot-test

deps:
	sudo apt-get install -y mkosi systemd-repart qemu-system-x86 qemu-utils \
	                        systemd-boot-efi systemd-boot-tools \
	                        ovmf debian-archive-keyring openssh-client \
	                        dosfstools e2fsprogs mtools unzip python3-numpy \
	                        xorriso erofs-utils espeak-ng \
	                        meson ninja-build glslang-tools g++-mingw-w64-x86-64-posix g++-mingw-w64-i686-posix

clean:
	rm -rf $(BUILD)/run-disk.raw $(BUILD)/run-vars.fd $(BUILD)/artifacts $(BUILD)/qmp.sock
	rm -rf $(EXTRA_TREE)/opt/sg-packages

distclean: clean
	mkosi clean || true
	rm -rf $(BUILD)
