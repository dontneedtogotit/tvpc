.PHONY: help install customize postboot doctor cec-remote cec-poweron check-updates check offline-usb clean

help:
	@echo "tvpc — Android-like HTPC Linux (Intel NUC7i5BNH + 2013 Samsung TV)"
	@echo ""
	@echo "  make install          Run the full installer (sudo, online)"
	@echo "  make customize        Apply idempotent UI/theme tweaks"
	@echo "  make postboot         Post-boot: SSH + Wi-Fi + polish"
	@echo "  make doctor           Run full health check"
	@echo "  make cec-remote       Install Samsung remote button mapping"
	@echo "  make cec-poweron      Power on Samsung TV via CEC now"
	@echo "  make check-updates    Check Flatpak/OS updates"
	@echo "  make check            Lint all shell scripts"
	@echo "  make offline-usb USB=/dev/sdX  Create offline USB installer"
	@echo "  make clean            Remove downloaded logs"

install:
	sudo ./install.sh

customize:
	sudo ./scripts/customize.sh

postboot:
	sudo ./scripts/tvpc-postboot.sh

doctor:
	bash ./scripts/tvpc-doctor.sh

cec-remote:
	sudo ./scripts/enhance-cec.sh

cec-poweron:
	sudo ./scripts/cec-tv-poweron.sh

check-updates:
	flatpak update
	sudo apt update && sudo apt list --upgradable

offline-usb:
	sudo ./scripts/make-offline-usb.sh $(USB)

check:
	@bash -n install.sh scripts/*.sh && echo "bash syntax OK"
	@command -v shellcheck >/dev/null && shellcheck -x -S warning install.sh scripts/*.sh || echo "shellcheck not installed (skipping)"

clean:
	rm -f /var/log/tvpc-install.log