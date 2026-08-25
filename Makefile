.PHONY: help install customize check-updates clean

help:
	@echo "tvpc — Android-like HTPC Linux"
	@echo ""
	@echo "  make install     Run the full installer (sudo)"
	@echo "  make customize   Apply idempotent tweaks"
	@echo "  make check-updates   Check for Flatpak/OS updates"
	@echo "  make clean       Remove downloaded logs"

install:
	sudo ./install.sh

customize:
	sudo ./scripts/customize.sh

check-updates:
	flatpak update
	sudo apt update && sudo apt list --upgradable

clean:
	rm -f /var/log/tvpc-install.log
