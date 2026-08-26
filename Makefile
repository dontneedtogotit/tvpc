.PHONY: help install customize postboot check-updates clean

help:
	@echo "tvpc — Android-like HTPC Linux (Intel NUC7i5BNH + 2013 Samsung TV)"
	@echo ""
	@echo "  make install          Run the full installer (sudo, online)"
	@echo "  make customize        Apply idempotent UI/theme tweaks"
	@echo "  make postboot         Post-boot: SSH + Wi-Fi + polish"
	@echo "  make check-updates    Check Flatpak/OS updates"
	@echo "  make offline-usb      Create offline USB installer"
	@echo "  make clean            Remove downloaded logs"

install:
	sudo ./install.sh

customize:
	sudo ./scripts/customize.sh

postboot:
	sudo ./tvpc-postboot.sh

check-updates:
	flatpak update
	sudo apt update && sudo apt list --upgradable

offline-usb:
	sudo ./scripts/make-offline-usb.sh /dev/sdX

clean:
	rm -f /var/log/tvpc-install.log