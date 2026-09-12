.PHONY: help install update update-check repair check-boot logs session \
        customize postboot doctor cec-remote cec-poweron check-updates check \
        offline-usb clean cameras-menu cameras-gui status controller-status controller-pair \
        setup-gui update-gui test theme theme-set theme-install

help:
	@echo "tvpc — Android-like HTPC Linux (Intel NUC7i5BNH + 2013 Samsung TV)"
	@echo ""
	@echo "  Black screen at boot? Start here:"
	@echo "    make check-boot       Diagnose without changing anything"
	@echo "    make repair           Apply the fixes, then reboot"
	@echo "    make logs             Dump the logs that explain the failure"
	@echo ""
	@echo "  make install          Run the full installer (sudo, online)"
	@echo "  make update           Converge to the intended state + update packages"
	@echo "  make update-check     Report what is done and what is not"
	@echo "  make session S=plasma Session: auto|plasma|plasma-mobile|plasma-x11|kiosk"
	@echo "                        opt-in: bigscreen|bigscreen-x11|phosh"
	@echo "  make customize        Apply idempotent UI/theme tweaks"
	@echo "  make theme            List Bigscreen modern themes"
	@echo "  make theme-set T=...  Set Bigscreen theme (midnight|oled|cyberpunk|sunset|emerald)"
	@echo "  make tweaks           Install the TV Tweaks app (+ All Apps entry)"
	@echo "  make home             Apply the full home-screen preset (VacuumTube + Power + Setup + Update + All Apps)"
	@echo "  make home-vacuum      Curate the home to VacuumTube only + All Apps launcher"
	@echo "  make status           Open the visual status dashboard (tvpc-status)"
	@echo "  make controller-status Show paired gamepads / input devices"
	@echo "  make controller-pair  Pair a Bluetooth gamepad interactively"
	@echo "  make setup-gui        Open gamepad, CEC/Anynet+, and TV power-on setup"
	@echo "  make update-gui       Open the repo/package/Flatpak updater"
	@echo "  make cameras-menu     Open the security-camera kdialog menu (bash)"
	@echo "  make cameras-gui      Open the security-camera PySide6 GUI"
	@echo "  make tweaks-menu      Run the TV Tweaks app interactively"
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

update:
	sudo ./install.sh --update

update-check:
	./install.sh --check

repair:
	sudo ./scripts/tvpc.sh repair

check-boot:
	sudo ./scripts/tvpc.sh repair --check

logs:
	sudo ./scripts/tvpc.sh repair --logs

session:
	sudo ./scripts/tvpc.sh session $(or $(S),auto)

customize:
	sudo ./install.sh --customize

theme:
	./scripts/tvpc.sh theme list

theme-set:
	./scripts/tvpc.sh theme set $(or $(T),midnight)

theme-install:
	sudo ./scripts/tvpc.sh theme install

tweaks:
	sudo ./scripts/tvpc.sh tweaks install-launcher

home:
	sudo ./scripts/tvpc.sh tweaks home

home-vacuum:
	sudo ./scripts/tvpc.sh tweaks vacuum-only

tweaks-menu:
	./scripts/tvpc.sh tweaks

cameras-menu:
	./scripts/tvpc.sh cameras menu

cameras-gui:
	./scripts/tvpc.sh cameras gui

status:
	./scripts/tvpc.sh status

controller-status:
	sudo ./scripts/tvpc.sh controller status

controller-pair:
	sudo ./scripts/tvpc.sh controller pair-gamepad

setup-gui:
	./scripts/tvpc.sh gui setup

update-gui:
	./scripts/tvpc.sh gui update

doctor:
	bash ./scripts/tvpc.sh doctor

cec-remote:
	sudo ./scripts/tvpc.sh cec setup

cec-poweron:
	sudo ./scripts/tvpc.sh cec poweron

check-updates:
	flatpak update
	sudo apt update && sudo apt list --upgradable

offline-usb:
	sudo ./install.sh --make-usb $(USB)

test: check
	pytest tvpc_cameras_gui/tests

check:
	@bash -n install.sh scripts/tvpc.sh tests/test-tvpc.sh && echo "bash syntax OK"
	@bash tests/test-tvpc.sh
	@command -v shellcheck >/dev/null && shellcheck -x -S warning install.sh scripts/tvpc.sh tests/test-tvpc.sh || echo "shellcheck not installed (skipping)"

clean:
	rm -f /var/log/tvpc-install.log

