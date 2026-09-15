# tpm-keyring-unlock

*[English](README.md) · **Deutsch***

[![test](https://github.com/dmitriitimoshenko/tpm-keyring-unlock/actions/workflows/test.yml/badge.svg)](https://github.com/dmitriitimoshenko/tpm-keyring-unlock/actions/workflows/test.yml)

Entsperrt den GNOME-Anmeldeschlüsselbund bei einer Anmeldung per Fingerabdruck
automatisch, ohne ihn zu schwächen – der Schlüsselbund bleibt passwortgeschützt;
das Passwort wird im TPM versiegelt, statt von Hand eingetippt zu werden.

## Installation

```bash
git clone https://github.com/dmitriitimoshenko/tpm-keyring-unlock.git
cd tpm-keyring-unlock
./install.sh
```

Zeigt vorab den vollständigen Plan – jedes zu installierende Paket, die Änderung
an der Gruppe `tss`, die genauen Änderungen an den PAM-Dateien (jede automatisch
gesichert) – und fragt genau einmal um Zustimmung, bevor irgendetwas davon
passiert. Die eine Ausnahme: Musst du erst zur Gruppe `tss` hinzugefügt werden
(für TPM-Zugriff ohne Passwort), braucht allein dieser Schritt mittendrin eine
neue Anmeldung; das Skript hält dann dort an und bittet dich, es danach erneut
zu starten. Dein Schlüsselbund-Passwort selbst tippst du beim Versiegeln
interaktiv ein – es landet nie unverschlüsselt auf der Festplatte und wird nie
als Befehlszeilenargument übergeben. Lies vor dem Start die Voraussetzungen
weiter unten.

## Das Problem

Der GNOME-Anmeldeschlüsselbund ist mit deinem Passwort verschlüsselt. Die
Fingerabdruck-Authentifizierung (`fprintd`/`libpam-fprintd`) antwortet immer nur
mit Ja oder Nein – sie liefert nie das Passwort, das der Schlüsselbund braucht.
Nach einer Anmeldung per Fingerabdruck bleibt der Schlüsselbund also gesperrt.
Die erste Anwendung, die ein gespeichertes Geheimnis braucht (WLAN-Passwort, im
Browser gespeichertes Passwort, ein Token), löst eine manuelle Passwortabfrage
„Legitimierung erforderlich“ aus.

Die zwei naheliegenden Lösungen sind beide schlecht:
- **Das Schlüsselbund-Passwort leeren.** Die Abfrage verschwindet, aber mit ihr
  der einzige Schutz gespeicherter Geheimnisse, wenn deine Festplatte nicht
  verschlüsselt ist.
- **Das echte Passwort in einer normalen Datei ablegen und bei der Anmeldung
  einspeisen.** Dasselbe Problem – eine Passwortdatei im Klartext schützt nicht
  mehr als gar kein Passwort.

## Die Lösung

Das echte Schlüsselbund-Passwort wird im TPM versiegelt, gebunden an eine
PCR7-Richtlinie (den Secure-Boot-Zustand). Der versiegelte Datenblock ist
überall nutzlos außer auf genau diesem Rechner in genau diesem
Secure-Boot-Zustand – wird die Festplatte ausgebaut, ist er nur Chiffretext. Auf
diesem Rechner in seinem aktuellen Zustand lässt er sich automatisch entsiegeln
und in den normalen Entsperrweg des Schlüsselbunds einspeisen, egal ob du dich
mit Passwort oder Fingerabdruck angemeldet hast.

Das ergibt nur Sinn, wenn deine Festplatte nicht schon vollständig verschlüsselt
ist (ist sie es, verdoppelt das Schlüsselbund-Passwort größtenteils einen Schutz,
den die Festplattenverschlüsselung schon bietet, und du kannst es genauso gut
leeren).

## Wie es funktioniert

Zwei voneinander unabhängige Dinge mussten behoben werden:

**1. Ein Wettlauf zwischen systemd und PAM, der das automatische Entsperren des
Schlüsselbunds für *alle* verhindert – auch bei Anmeldung per Passwort –, auf
Distributionen, die `gnome-keyring-daemon.service` über
`graphical-session-pre.target` vorab starten.**
Diese Unit startet den Dienst, bevor Anmeldung und PAM laufen. Wenn die
PAM-eigene Entsperrlogik (`pam_gnome_keyring.so`) den Dienst mit deinem Passwort
anlegen oder entsperren will, gehören der von systemd gestarteten Instanz bereits
der D-Bus-Name und der Steuer-Socket – PAMs Versuch startet nur einen zweiten,
unverbundenen Dienst, statt den echten zu entsperren. Die Unit zu maskieren
(`systemctl --user mask gnome-keyring-daemon.socket
gnome-keyring-daemon.service`) beendet den Wettlauf: Der von PAM gestartete
Dienst ist dann der einzige, den es je gibt. Schon das allein behebt das
automatische Entsperren bei Anmeldung per Passwort. **Bekommst du die
Entsperrabfrage auch bei Anmeldung per Passwort, ist das vielleicht schon deine
ganze Lösung – probier es aus, bevor du die Fingerabdruck-Teile unten angehst.**

**2. Die Fingerabdruck-Authentifizierung setzt nie `PAM_AUTHTOK`; selbst ohne den
Wettlauf hat `pam_gnome_keyring.so` also nichts, was es übernehmen könnte.**
Ein kleines PAM-Modul (`pam/pam_tpm_keyring_authtok.c`) steht direkt vor
`pam_gnome_keyring.so` in jedem Anmelde-PAM-Stapel, der dieses enthält. Es
entsiegelt das im TPM versiegelte Passwort (über ein Hilfsskript, das root
gehört) und setzt es als `PAM_AUTHTOK`, nur damit das nächste Modul es nutzen
kann. Es ist immer `auth optional` und gibt immer `PAM_IGNORE` zurück – es kann
unter keinen Umständen allein eine Anmeldung gewähren oder verweigern, auch
nicht bei eigenem Fehlschlag. Ist `PAM_AUTHTOK` schon gesetzt (ein echtes
Passwort wurde getippt), tut es nichts. Welches Modul dich tatsächlich
authentifiziert hat (`pam_fprintd.so`, `pam_unix.so` über ein getipptes Passwort
usw.), bleibt das Einzige, das über den Erfolg der Anmeldung entscheidet.

```
auth	required	pam_fprintd.so
auth    optional        pam_tpm_keyring_authtok.so   <- von diesem Werkzeug ergänzt
auth    optional        pam_gnome_keyring.so          <- ab Werk schon vorhanden
```

**Es geht nicht nur um einen Dienst, der wörtlich `*fingerprint*` heißt.** Jeder
Anmelde-PAM-Stapel, der `pam_gnome_keyring.so` in seiner auth-Phase enthält,
braucht dieses Modul, wenn er *jemals* über etwas anderes als ein getipptes
Passwort erfolgreich sein kann – auch `gdm-password` selbst, sobald du den
Fingerabdruck mit `pam-auth-update --enable fprintd` systemweit einschaltest
(das fügt `pam_fprintd.so` in `common-auth` ein, das auch `gdm-password`
einbindet). `install.sh` berücksichtigt das: Es ändert jede Dienstdatei unter
`/etc/pam.d/` mit einer `pam_gnome_keyring.so`-Zeile in der auth-Phase, nicht
nur solche mit „fingerprint“ im Dateinamen.

## Auch Fingerabdruck für `sudo` und Software-Installation?

Das ist eine eigene, unabhängige Sache – nicht spezifisch für dieses Werkzeug –,
und der offiziell unterstützte Weg ist:

```bash
sudo pam-auth-update --enable fprintd
```

Das ist ein von den Paketbetreuern mitgeliefertes Profil
(`/usr/share/pam-configs/fprintd` unter Debian/Ubuntu), das den Fingerabdruck
systemweit als erste Authentifizierungsmethode einträgt, mit automatischem
Rückfall auf dein Passwort, wenn er scheitert oder die Zeit abläuft. Damit
nehmen `sudo` im Terminal und die von polkit geschützten grafischen Abfragen
(Installation eines Snaps aus dem Ubuntu App Center, GNOME Software usw.) einen
Fingerabdruck an.

Nutzt du das, führe `install.sh` danach (erneut) aus. Systemweite
Fingerabdruck-Authentifizierung heißt, dass auch dein normaler
Passwort-Anmeldebildschirm (`gdm-password`) jetzt per Fingerabdruck erfolgreich
sein kann, nicht nur eine eigene Fingerabdruck-Option – und das öffnet genau die
oben beschriebene `PAM_AUTHTOK`-Lücke wieder, bei einem Dienst, der gar nicht
nach Fingerabdrücken benannt ist. `install.sh` sucht aus genau diesem Grund
jeden Dienst unter `/etc/pam.d/` mit einer `pam_gnome_keyring.so`-Zeile in der
auth-Phase und ändert sie alle.

## Voraussetzungen

Harte Voraussetzungen – ohne sie macht das Werkzeug nicht weiter, sie sind nicht
optional:

- TPM 2.0 mit Ressourcenverwaltungs-Gerät (`/dev/tpmrm0`)
- Secure Boot eingeschaltet (ohne Secure Boot ist PCR7 als Schloss bedeutungslos)
- `gnome-keyring` als tatsächliche Verwaltung deiner Geheimnisse, mit bereits
  eingerichteter und funktionierender Anmeldung per Fingerabdruck
  (`fprintd`/`libpam-fprintd`, eingelesener Fingerabdruck) – dieses Werkzeug
  richtet die Fingerabdruck-Authentifizierung nicht ein, es behebt nur, was mit
  dem Schlüsselbund passiert, sobald sie schon funktioniert
- `tpm2-tools`, ein C-Compiler und PAM-Entwicklungsheader – `install.sh` bietet
  an, sie auf apt-, dnf-, pacman- und zypper-Systemen selbst zu installieren
  (für andere Paketverwaltungen siehe Kompatibilität unten)
- systemd als Init- und Sitzungsverwaltung (für den Schritt
  `systemctl --user mask` – siehe „Wie es funktioniert“, Teil 1)

## Kompatibilität

Alles in diesem Repository wurde auf genau einem echten Rechner gebaut und dort
direkt überprüft: Ubuntu, GNOME, GDM, systemd, TPM 2.0, Secure Boot an, keine
Festplattenverschlüsselung (das eigentliche Testprotokoll steht in `JOURNAL.md`).
Darüber hinaus hier eine ehrliche Aufstellung, was der Code berücksichtigt und
was nicht – „sollte funktionieren“ heißt unten, dass die Logik den Fall abdeckt,
nicht dass er dort ausprobiert wurde:

**Sollte funktionieren wie die getestete Einrichtung:**
- Jede GNOME-basierte Distribution mit `gnome-keyring` und GDM (Fedora
  Workstation, Debian, Pop!_OS usw.) – die PAM-Datei-Erkennung von `install.sh`
  arbeitet nach *Inhalt* (jeder Dienst unter `/etc/pam.d/` mit einer
  `pam_gnome_keyring.so`-Zeile in der auth-Phase), nicht nach Dateinamen, und
  ist daher von vornherein nicht auf GDM beschränkt.
- Andere Displaymanager (LightDM, SDDM, …), *wenn* tatsächlich `gnome-keyring`
  deine Geheimnisse verwaltet – aus demselben Grund, die Erkennung arbeitet nach
  Inhalt.
- `apt`-, `dnf`-, `pacman`- und `zypper`-Systeme für den Schritt, der die
  Abhängigkeiten installiert.
- `x86_64`- und `aarch64`-Rechner für die Erkennung des Installationspfads des
  PAM-Moduls.

**Funktioniert nicht, absichtlich oder wegen unpassender Architektur:**
- **KDE Plasma mit KWallet.** Ein ganz anderer Dienst für Geheimnisse, nicht
  `gnome-keyring` – dieses Werkzeug hat nichts, woran es sich anhängen könnte.
  (KDE mit `gnome-keyring` statt KWallet ist etwas anderes und sollte unter
  „sollte funktionieren“ oben fallen.)
- Kein TPM 2.0, Secure Boot aus oder ein Init-System ohne systemd – harte
  Voraussetzungen von oben; `install.sh` prüft sie und beendet sich sauber,
  statt etwas Halbfertiges zu tun.
- Jede andere Paketverwaltung (z. B. `apk` unter Alpine) – die automatische
  Installation der Abhängigkeiten ist dafür nicht eingebaut; installiere
  `tpm2-tools`, einen C-Compiler und die PAM-Header vorher selbst, dem Rest von
  `install.sh` ist egal, wie sie auf das System gekommen sind.

**Von einer automatischen Testsuite abgedeckt (siehe
[CONTRIBUTING.md](CONTRIBUTING.md), englisch), nicht nur durch Code-Durchsicht:**
Installation der Abhängigkeiten und Erkennung des PAM-Verzeichnisses für
`apt`/`dnf`/`pacman`/`zypper`, jeweils gegen das echte Basis-Image der
Distribution; die Erkennung des PAM-Pfads unter `aarch64`, quergebaut über
`docker buildx`/QEMU; das tatsächliche fork/exec-, Zeitlimit- und
`PAM_AUTHTOK`-Verhalten des PAM-Moduls; und – über `test/vm/run-vm-test.sh`,
eine echte VM (`swtpm` + OVMF, echter umschaltbarer Secure-Boot-Zustand) – die
tatsächliche Erkennungslogik von `require_secure_boot()` in beiden Zuständen,
ein echter Durchlauf von `bin/seal.sh` + `tpm-keyring-unseal.sh` gegen eine
echte PCR7-Richtlinie, dass dieser Durchlauf einen echten TPM-Reset übersteht
(einen echten Neustart des swtpm- und qemu-Prozesses, derselbe Auslöser wie ein
physischer Neustart), und zwei gleichzeitige Entsiegelungsaufrufe gegen dasselbe
TPM (die `flock`-Serialisierung). **Weiterhin wirklich ungetestet:** jede
TPM-Implementierung außer dem fTPM dieses einen Entwicklungsrechners und dem
Software-TPM der VM-Ebene (echte Hardware-TPMs, besonders fTPMs anderer
Hersteller, können sich bei gleichzeitigem Zugriff anders verhalten – genau das
hat die Fehler bei gleichzeitigem Zugriff in `JOURNAL.md` zutage gebracht) sowie
jeder Displaymanager außer GDM und jede echte grafische Anmeldung per
Fingerabdruck (die VM-Ebene läuft ohne Oberfläche – kein GDM, kein `libfprint`).
Stößt du bei einem davon auf einen Fehler, ist das ein echter Fehlerbericht, kein
„das wurde nie behauptet“ – bitte eröffne ein Issue.

## Deinstallation

```bash
./uninstall.sh
```

Macht jeden Schritt rückgängig. Dein eigentliches GNOME-Schlüsselbund-Passwort
ändert dieses Werkzeug nie, dort gibt es also nichts wiederherzustellen.

## Bedrohungsmodell, ehrlich

Wogegen es schützt: jemanden, der deinen ausgeschalteten Laptop in die Hände
bekommt und die Festplatte ausbaut. Das versiegelte Geheimnis ist ohne dieses
TPM wertlos.

Wogegen es **nicht** schützt: Jeder, der deinen laufenden, angemeldeten Rechner
kontrolliert (root oder du selbst), kann den entschlüsselten Wert des
versiegelten Geheimnisses genauso auslesen, wie es dieses Werkzeug tut – das
gehört untrennbar zu „automatisch entsperren, ohne zu fragen“ und ist kein
Fehler dieses Ansatzes.

Ändern sich jemals deine Secure-Boot-Einstellungen im BIOS (ein- oder
ausgeschaltet, Schlüssel zurückgesetzt), ändert sich PCR7 und das Siegel bricht
– dann musst du `bin/seal.sh` erneut ausführen. Gewöhnliche Kernel- und
Treiber-Updates beeinflussen PCR7 nicht und brechen es nicht.

## Fehlerbehebung

- **Nach der Installation weiterhin eine Abfrage.** Prüfe, welcher PAM-Dienst
  deine Anmeldung tatsächlich abgewickelt hat: `journalctl -b 0 | grep gkr-pam`.
  Der Dienstname in Klammern (z. B. `gdm-password][1234]`) zeigt, welche Datei
  unter `/etc/pam.d/` die Änderung braucht – führe `install.sh` erneut aus, es
  findet jeden übersehenen Dienst und bietet an, ihn zu ändern.
- **Hat funktioniert, nach einem Neustart nicht mehr, und du hast nichts an PAM
  geändert.** Prüfe `journalctl -b 0 | grep -i tpm` und probiere `sudo
  /usr/local/sbin/tpm-keyring-unseal $USER >/dev/null; echo $?` – ein
  Rückgabewert ungleich null heißt meist, dass sich PCR7 des TPM geändert hat
  (eine Secure-Boot-Einstellung wurde geändert) und das Siegel erneuert werden
  muss: `bin/seal.sh`.
- **Hat funktioniert, nach `pam-auth-update --enable fprintd` nicht mehr.**
  Siehe „Auch Fingerabdruck für `sudo`“ oben – führe `install.sh` erneut aus.
- **Die Anmeldung stockt einige Sekunden (Fingerabdruck oder Passwort), obwohl
  das automatische Entsperren funktioniert.** Der TPM-Vorgang, auf dem das
  beruht, hat einen schnellen Weg und einen langsamen Rückfallweg; versiegelte
  Geheimnisse, die angelegt wurden, bevor es den schnellen Weg gab, nutzen den
  langsamen, bis sie neu versiegelt werden. Lösung: `bin/seal.sh` (bei der
  Nachfrage „Overwrite“ wählen, dasselbe Passwort wie vorher). Warum das
  einmalig und sicher ist, steht in `JOURNAL.md` unter 2026-08-16 (englisch).
- **`install.sh` verweigert den Start, weil es den Secure-Boot-Zustand nicht
  bestimmen kann.** Es prüft zuerst über `mokutil --sb-state` und liest
  ersatzweise die EFI-Variable `SecureBoot` direkt, wenn `mokutil` nicht
  installiert ist. Klappt beides nicht (selten – meist ein sehr abgeschottetes
  efivarfs oder eine ungewöhnliche Firmware-Einrichtung), installiere `mokutil`
  oder stelle auf anderem Weg sicher, dass Secure Boot an ist, und starte dann
  erneut.
- Für alles Tiefergehende: `JOURNAL.md` in diesem Repository ist das
  vollständige, ungeschönte Untersuchungsprotokoll, aus dem dieses Werkzeug
  entstanden ist (englisch), einschließlich zweier Rückschritte, die nach der
  ersten Fassung dieser README gefunden wurden, und wie genau ihre Ursache
  ermittelt wurde. Stößt du auf etwas, das oben nicht abgedeckt ist, lohnt sich
  ein Blick hinein.

## Lizenz

MIT – siehe [LICENSE](LICENSE).
