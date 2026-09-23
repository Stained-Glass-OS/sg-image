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

.PHONY: addons apps apps-test lab-password compositor-deb shell-deb all image boot-test multiuser-test d3d-test test deps sshkey staged-debs session-deb wine-deb d3d clean distclean

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

$(D3D_DIR)/VERSION:
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

$(APPS_DIR)/VERSION:
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
# help, sign-in pages -- shows nothing; with them missing, Wine would also try
# to prompt for a download during the unattended prefix build. Wine looks for
# them in /usr/share/wine/{mono,gecko} before prompting, and installs from
# there silently.
#
# The hashes are the ones pinned in Wine 10.0's own dlls/appwiz.cpl/addons.c;
# Wine rejects a file that does not match them, and so does this build. Both
# architectures of Gecko: 32-bit programs use the 32-bit engine. Mono is one
# MSI for both. Licences: Wine Mono is MIT with some components under their
# own free licences; Wine Gecko is MPL-2.0.
MONO_VERSION       := 9.4.0
MONO_SHA256        := cf6173ae94b79e9de13d9a74cdb2560a886fc3d271f9489acb1cfdbd961cacb2
GECKO_VERSION      := 2.47.4
GECKO_X86_SHA256   := 26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6
GECKO_X64_SHA256   := e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f

ADDONS_DIR   := $(EXTRA_TREE)/usr/share/wine
ADDONS_CACHE := $(BUILD)/addons-cache

addons: $(ADDONS_DIR)/.sg-addons

$(ADDONS_DIR)/.sg-addons:
	@mkdir -p $(ADDONS_CACHE) $(ADDONS_DIR)/mono $(ADDONS_DIR)/gecko
	@set -e; cd $(ADDONS_CACHE); \
	m=wine-mono-$(MONO_VERSION)-x86.msi; \
	g32=wine-gecko-$(GECKO_VERSION)-x86.msi; \
	g64=wine-gecko-$(GECKO_VERSION)-x86_64.msi; \
	[ -f $$m ]   || curl -sSL --retry 3 -o $$m   https://dl.winehq.org/wine/wine-mono/$(MONO_VERSION)/$$m; \
	[ -f $$g32 ] || curl -sSL --retry 3 -o $$g32 https://dl.winehq.org/wine/wine-gecko/$(GECKO_VERSION)/$$g32; \
	[ -f $$g64 ] || curl -sSL --retry 3 -o $$g64 https://dl.winehq.org/wine/wine-gecko/$(GECKO_VERSION)/$$g64; \
	echo "$(MONO_SHA256)  $$m" | sha256sum -c - ; \
	echo "$(GECKO_X86_SHA256)  $$g32" | sha256sum -c - ; \
	echo "$(GECKO_X64_SHA256)  $$g64" | sha256sum -c - ; \
	cp $$m $(CURDIR)/$(ADDONS_DIR)/mono/; cp $$g32 $$g64 $(CURDIR)/$(ADDONS_DIR)/gecko/
	@echo "wine-mono $(MONO_VERSION), wine-gecko $(GECKO_VERSION)" > $@
	@echo "staged addons: $$(cat $@)"

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
