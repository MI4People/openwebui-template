# Nachrüstung bestehender Kundenserver

Für Server, die vor dem Update-Skript mit dem Template aufgesetzt wurden.
Pro Server einmal durchgehen, etwa 15 Minuten plus Update-Laufzeit.

Am Ende hat der Server:

- den Befehl `openwebui-update` (Systemupdates, Open-WebUI-Update, Rollback, bei Bedarf Neustart)
- automatische Sicherheitsupdates mit Neustart um 04:00, falls nötig
- eine nginx-Konfiguration, die nach Updates, Reboots oder Abstürzen kein 502 mehr liefert
- kein Update-Banner mehr in Open WebUI
- nginx auf fester Hauptversion statt `latest`

> **Wichtig:** Auf alten Servern stehen die Passwörter direkt in der `docker-compose.yml`.
> Diese Datei deshalb **nie durch die Template-Version ersetzen**, sondern nur gezielt ändern
> wie unten beschrieben. Sonst startet Open WebUI nicht mehr (fehlende `.env`).

Die Befehle in den Schritten 1 bis 7 laufen auf dem Server als `root`. Schritt 2 läuft lokal im Repo.

## 1. Struktur und Platz prüfen

```bash
ls /root/openwebui/openwebui-docker/docker-compose.yml /root/openwebui/openwebui_backup.sh
df -h /root
```

Beide Dateien müssen da sein. Nötig sind mindestens **8 GB frei**. Bei zu wenig Platz:

```bash
docker image prune -a -f
du -sh /root/openwebui/openwebui-docker/storage/openwebui/cache/embedding/models/* 2>/dev/null
```

Ungenutzte Embedding-Modelle dürfen gelöscht werden. Das aktive Modell steht in Open WebUI unter
Admin-Einstellungen → Dokumente (bisher `paraphrase-multilingual-MiniLM-L12-v2`).
Reicht der Platz dauerhaft nicht, in der Hetzner Console die Platte vergrößern (empfohlen: 80 GB).

## 2. Skripte kopieren (lokal, im Repo-Ordner)

```bash
scp openwebui/update.sh openwebui/auto-updates.sh root@IP:/root/openwebui/
```

## 3. Befehl `openwebui-update` anlegen

```bash
chmod +x /root/openwebui/update.sh /root/openwebui/auto-updates.sh
ln -sf /root/openwebui/update.sh /usr/local/bin/openwebui-update
```

## 4. nginx-Konfiguration umstellen

Fügt `resolver` und die Variable ein und stellt `proxy_pass` darauf um. Der Befehl kann gefahrlos
mehrfach laufen, eine Sicherheitskopie wird angelegt.

```bash
cd /root/openwebui/openwebui-docker
CONF=nginx/conf.d/openwebui.conf
cp -n "$CONF" /root/openwebui/openwebui.conf.vor-resolver
grep -q 'resolver 127.0.0.11' "$CONF" || perl -0pi -e 's|^([ \t]*)(ssl_certificate_key .*;\n)|$1$2\n$1resolver 127.0.0.11 valid=10s ipv6=off;\n$1set \$openwebui_upstream http://openwebui:8080;\n|m; s|proxy_pass http://openwebui:8080;|proxy_pass \$openwebui_upstream;|' "$CONF"
grep -nE 'resolver|openwebui_upstream' "$CONF"
docker compose exec nginx nginx -t && docker compose restart nginx
```

Erwartet: drei Treffer bei `grep` (resolver, set, proxy_pass) und `test is successful`.
Falls `nginx -t` fehlschlägt: `cp /root/openwebui/openwebui.conf.vor-resolver "$CONF"` und Ursache prüfen.
Die Sicherheitskopie liegt bewusst nicht in `conf.d`, weil nginx dort jede Datei lädt.

## 5. docker-compose.yml anpassen (nur gezielt)

```bash
cd /root/openwebui/openwebui-docker
cp -n docker-compose.yml docker-compose.yml.vor-nachruestung
sed -i 's|image: nginx:latest|image: nginx:1.30|' docker-compose.yml
grep -q ENABLE_VERSION_UPDATE_CHECK docker-compose.yml || \
  sed -i 's|^\([[:space:]]*\)- ENABLE_PERSISTENT_CONFIG=true$|&\n\1- ENABLE_VERSION_UPDATE_CHECK=false|' docker-compose.yml
grep -nE 'image: nginx|ENABLE_VERSION_UPDATE_CHECK' docker-compose.yml
docker compose config -q && echo "Compose-Datei gültig"
```

Wirksam wird das beim nächsten `docker compose up -d`, spätestens beim ersten Update in Schritt 7.

## 6. Automatische Sicherheitsupdates einrichten

```bash
bash /root/openwebui/auto-updates.sh
```

## 7. Erstes Update selbst ausführen

```bash
openwebui-update
```

Danach im Browser anmelden, einen Chat öffnen und eine Frage stellen. Das Update-Banner sollte nicht mehr erscheinen.

## 8. Übergabe an Kund:innen

- Für die Hetzner-Konsole braucht es ein root-Passwort. Server mit SSH-Schlüssel haben keins:
  Hetzner Console → Server → Rescue → Root-Passwort zurücksetzen. Das Passwort getrennt von der Mail übergeben.
- Hetzner Backups für den Server aktivieren, falls noch nicht geschehen (die Datenbank-Dumps liegen auf derselben Platte).

## Checkliste pro Server

| Schritt | Erledigt |
|---|---|
| 1. Struktur da, mind. 8 GB frei | |
| 2. `update.sh` und `auto-updates.sh` kopiert | |
| 3. `openwebui-update` angelegt | |
| 4. nginx umgestellt, `nginx -t` erfolgreich | |
| 5. nginx-Version und Update-Banner in Compose | |
| 6. Sicherheitsupdates eingerichtet | |
| 7. Erstes Update erfolgreich, im Browser geprüft | |
| 8. root-Passwort übergeben, Hetzner Backups an | |

---

# Rollback testen (nur auf einem Testserver)

Der Rollback ist bisher nie gelaufen. So wird er gezielt ausgelöst.

**Hinweis:** `openwebui-update --version v0.0.1` testet **nicht** den Rollback. Die Version gibt es nicht,
deshalb scheitert schon der Download, und das Skript lässt einfach die alte Version weiterlaufen.
Der Rollback greift erst, wenn eine neue Version zwar startet, aber nicht rechtzeitig gesund ist.

1. Testserver mit einer **älteren** Open-WebUI-Version aufsetzen: vor `setup.sh` in
   `openwebui-docker/.env` z. B. `OPENWEBUI_VERSION=v0.12.0` eintragen.
   (Nicht einen bestehenden Server per `--version` herunterstufen: Datenbank-Migrationen gehen nur vorwärts.)
2. Anmelden, ein paar Chats anlegen, damit Daten zum Vergleichen da sind.
3. Update mit absichtlich zu kurzer Wartezeit starten, sodass die Health-Prüfung scheitert:

   ```bash
   HEALTH_TIMEOUT=10 openwebui-update --skip-system
   ```

4. Erwartet in der Ausgabe bzw. in `/root/openwebui/update.log`:
   - „Neue Version läuft nicht. Stelle den vorherigen Zustand wieder her ...“
   - „OK: Datenbank zurückgespielt“
   - „Die vorherige Version läuft wieder.“
5. Prüfen:
   - `grep OPENWEBUI_VERSION /root/openwebui/openwebui-docker/.env` zeigt wieder die alte Version.
   - `docker exec openwebui curl -s localhost:8080/api/version` meldet die alte Version.
   - Anmeldung funktioniert, die Chats aus Schritt 2 sind da.
6. Danach ein normales `openwebui-update` ausführen. Es muss ganz normal auf die neue Version gehen.
