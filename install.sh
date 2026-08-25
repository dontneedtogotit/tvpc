# 17. Apply repo-local overrides (configs, desktop files, wallpapers, etc.)
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

# Enable custom services from overlays
if [[ -d "$REPO_ROOT/overlays/etc/systemd/system" ]]; then
  for service in "$REPO_ROOT/overlays/etc/systemd/system/"*.service; do
    [[ -e "$service" ]] || continue
    name=$(basename "$service")
    cp "$service" "/etc/systemd/system/$name"
    systemctl enable "$name" 2>/dev/null || true
  done
  echo "Enabled systemd services from overlays"
fi