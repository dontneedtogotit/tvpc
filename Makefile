.PHONY: help install customize install-extras cec-poweron check-updates clean

help:
	@echo "tvpc — Android-like HTPC Linux (Intel NUC7i5BNH + 2013 Samsung TV)"
	@echo ""
	@echo "  make install          Run the full installer (sudo)"
	@echo "  make customize        Apply idempotent post-install tweaks"
	@echo "  make install-extras   Run HW verification + NUC tuneables"
	@echo "  make cec-poweron      Power on Samsung TV via CEC"
	@echo "  make check-updates    Check Flatpak/OS updates"
	@echo "  make clean            Remove downloaded logs"

install:
	sudo ./install.sh

customize:
	sudo ./scripts/customize.sh

install-extras:
	sudo ./scripts/install-extras.sh

cec-poweron:
	sudo ./scripts/cec-tv-poweron.sh

check-updates:
	flatpak update
	sudo apt update && sudo apt list --upgradable

clean:
	rm -f /var/log/tvpc-install.log