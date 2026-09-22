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

.PHONY: all image boot-test multiuser-test test deps sshkey staged-debs session-deb wine-deb clean distclean

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
staged-debs: $(SSH_KEY)
	@mkdir -p $(EXTRA_TREE)/opt/sg-packages
	@rm -f $(EXTRA_TREE)/opt/sg-packages/*.deb
	$(MAKE) wine-deb session-deb
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
	@cp $(SG_SESSION)/../sg-session_*_all.deb $(EXTRA_TREE)/opt/sg-packages/

# --- image -----------------------------------------------------------------

image: staged-debs
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

test: image boot-test

deps:
	sudo apt-get install -y mkosi systemd-repart qemu-system-x86 qemu-utils \
	                        systemd-boot-efi systemd-boot-tools \
	                        ovmf debian-archive-keyring openssh-client \
	                        dosfstools e2fsprogs mtools

clean:
	rm -rf $(BUILD)/run-disk.raw $(BUILD)/run-vars.fd $(BUILD)/artifacts $(BUILD)/qmp.sock
	rm -rf $(EXTRA_TREE)/opt/sg-packages

distclean: clean
	mkosi clean || true
	rm -rf $(BUILD)
