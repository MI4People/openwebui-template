#!/usr/bin/env bash
#
# Automatische Sicherheitsupdates für das Betriebssystem einrichten
#
# Wird von setup.sh aufgerufen und kann auf bestehenden Servern einfach
# nachträglich ausgeführt werden. Mehrfaches Ausführen ist unschädlich.
#
# Ergebnis:
#   - Nur Sicherheitsupdates von Ubuntu bzw. Debian werden automatisch installiert.
#   - Docker-Pakete werden nie automatisch aktualisiert (das macht openwebui-update).
#   - Installation täglich um 03:30, falls nötig Neustart um 04:00.
#     (Backup läuft um 01:00, Zertifikat-Erneuerung um 03:00.)
#

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Bitte als root ausführen." >&2
  exit 1
fi

echo "Installing unattended-upgrades..."
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades >/dev/null

# Zeitplan und Aktivierung. Höhere Nummer als 20auto-upgrades, damit diese Werte gelten.
cat > /etc/apt/apt.conf.d/21openwebui-auto-upgrades <<'EOF'
// Angelegt von openwebui/auto-updates.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Höhere Nummer als 50unattended-upgrades. "#clear" entfernt die Standardquellen,
# denn Debian würde sonst auch normale Punkt-Updates automatisch einspielen.
cat > /etc/apt/apt.conf.d/52openwebui-unattended-upgrades <<'EOF'
// Angelegt von openwebui/auto-updates.sh
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
  // Ubuntu
  "origin=Ubuntu,archive=${distro_codename}-security";
  // Debian ab 11
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
  // Debian bis 10
  "origin=Debian,codename=${distro_codename},label=Debian-Security";
};

// Docker nie automatisch aktualisieren: ein Docker-Upgrade startet alle Container neu.
Unattended-Upgrade::Package-Blacklist {
  "docker-ce";
  "docker-ce-cli";
  "docker-ce-rootless-extras";
  "docker-buildx-plugin";
  "docker-compose-plugin";
  "containerd.io";
};

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Neustart nur, wenn ein Update es verlangt (z. B. neuer Kernel).
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# Standardmäßig läuft die Installation um ca. 06:00 plus Zufallsverzögerung.
# Dann käme der Neustart erst am nächsten Tag um 04:00. Deshalb auf 03:30 vorziehen.
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/openwebui.conf <<'EOF'
# Angelegt von openwebui/auto-updates.sh
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:30
RandomizedDelaySec=0
EOF

systemctl daemon-reload
systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null
systemctl restart apt-daily-upgrade.timer

echo "Automatic security updates enabled (install 03:30, reboot if needed 04:00)."
