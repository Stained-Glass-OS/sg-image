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

.PHONY: all image boot-test test deps sshkey session-deb clean distclean

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

# sg-session ships as a .deb, like everything else in this project. Build it
# from the sibling checkout and drop it where mkosi will find it.
session-deb: $(SSH_KEY)
	@test -d $(SG_SESSION) || { \
		echo "sg-session checkout not found at $(SG_SESSION)."; \
		echo "clone it beside this repo, or set SG_SESSION=/path/to/sg-session"; \
		exit 1; }
	$(MAKE) -C $(SG_SESSION) deb
	@mkdir -p $(EXTRA_TREE)/opt/sg-packages
	@rm -f $(EXTRA_TREE)/opt/sg-packages/*.deb
	@cp $(SG_SESSION)/../sg-session_*_all.deb $(EXTRA_TREE)/opt/sg-packages/
	@echo "sg-session packages staged:"; ls -1 $(EXTRA_TREE)/opt/sg-packages/

# --- image -----------------------------------------------------------------

image: session-deb
	mkosi --force
	@ls -lh $(IMAGE)

# --- gate ------------------------------------------------------------------

boot-test:
	test/boot-test.sh

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
