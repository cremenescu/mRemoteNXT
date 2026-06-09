# mRemoteNXT

> English: see [README.md](README.md)

Client multi-protocol pentru macOS (SSH, RDP, Telnet, SFTP, HTTP/HTTPS), cu
import nativ al fisierelor `confCons.xml` din **mRemoteNG**.

Scris ca alternativa nativa Mac pentru cei care folosesc mRemoteNG pe Windows
si nu vor sa renunte la arborele de conexiuni, parolele criptate si layout-ul
cu tab-uri si paneluri.

> Status: **alpha**. Functional zilnic pe ~700 conexiuni reale, dar sunt
> features lipsa si bug-uri care apar pe configuri exotice. Vezi
> [Limitari cunoscute](#limitari-cunoscute).

## Capturi de ecran

*(de adaugat — porneste app-ul cu un confCons.xml de test.)*

## Ce merge

- **Import direct** `confCons.xml` (schema 2.6, passphrase-ul implicit al mRemoteNG sau
  proprie). Crypto validat byte-exact (PBKDF2-HMAC-SHA1 + AES-256-GCM).
- **Arbore de conexiuni** cu foldere, mostenire de atribute, drag&drop reorder,
  iconite originale mRemoteNG, linii de ghidaj.
- **Paneluri** — gruparea conexiunilor in tab-uri de top, ca pe Windows.
- **Cautare / filtru** pe nume, host, protocol, descriere.
- **SSH** + **Telnet** embedat in tab (PTY peste `ssh`/`telnet` de sistem,
  prin SwiftTerm). Copy-on-select, click-dreapta = paste (stil PuTTY).
- **SFTP** in terminal (click-dreapta pe conexiune SSH → "Transfer fisiere").
- **RDP** embedat prin **FreeRDP** (canalele GFX/disp/cliprdr cablate manual,
  resize live, scaling DPI corect pe Retina, Ctrl+Alt+Del prin meniu).
- **HTTP / HTTPS** embedat in `WKWebView` cu autofill pentru user + parola din
  arbore (util pentru web-UI de routere / iLO / switch-uri).
- **External Tools** cu macro-uri (`%Host% %Username% %Port% %Password%
  %Domain% %Name%`) — rulate intr-un tab terminal.
- **Editor de conexiune** stil Royal TSX (modal cu categorii: General /
  Conexiune / Credentiale / Aspect / Avansat) + status bar in josul
  sidebar-ului cu host / user / parola click-to-copy.
- **Salvare cu backup automat** in `backups/confCons-<timestamp>.xml` la
  fiecare scriere (fisierul tau original nu se pierde niciodata).
- **Teme terminal** (Implicit, Solarized, Dracula, etc.), font reglabil
  live, zoom Cmd+/Cmd-.

## Ce NU merge inca

- `FullFileEncryption="true"` (intregul XML criptat) — neimplementat.
- Schema `ConfVersion > 2.6` — netestat.
- Tab inheritance pentru `Panel` peste niveluri multiple — partial.
- RDP: redirect clipboard imagine, redirect drive / sunet, cursor remote
  vizibil (pointer set/new callbacks).
- VNC (planificat).
- Aplicatii externe (`IntApp` nodes) — lansare neimplementata.
- Quick Connect (URL `ssh://user@host:port`) din CLI.

## Cerinte sistem

- macOS 14 (Sonoma) sau mai nou.
- Xcode 16+ (cu Metal Toolchain — vezi [BUILD.md](BUILD.md)).
- Homebrew cu `freerdp` (3.x) si `xcodegen`.

## Instalare

Nu exista release pre-compilat momentan. Vezi [BUILD.md](BUILD.md) pentru
build local.

Daca downloadezi vreodata un `.dmg` din Releases, e semnat ad-hoc — vei
avea nevoie sa permiti executia:

```bash
xattr -dr com.apple.quarantine /Applications/mRemoteNXT.app
```

## Licenta

**GPL-2.0-or-later**. Vezi [LICENSE](LICENSE).

Folosesc iconite preluate din proiectul oficial
[mRemoteNG](https://github.com/mRemoteNG/mRemoteNG) (GPL-2.0), motiv pentru
care si acest proiect este sub aceeasi licenta. Codul si formatul `confCons.xml`
au fost re-implementate independent (nu e port de cod) din observarea
fisierelor reale produse de mRemoteNG.

## Crediti / dependinte

- [mRemoteNG](https://github.com/mRemoteNG/mRemoteNG) — formatul `confCons.xml`
  si setul de iconite (GPL-2.0).
- [FreeRDP](https://github.com/FreeRDP/FreeRDP) — RDP client library
  (Apache-2.0).
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulator
  (MIT).
- Apple SwiftUI / AppKit / WebKit / CryptoKit / CommonCrypto.

## Repository-uri impostor

Singurul repo oficial mRemoteNXT este
**<https://github.com/cremenescu/mRemoteNXT>**. Release-urile (`.dmg`) se
publica doar acolo.

Orice alt repo de pe GitHub care foloseste numele "mRemoteNXT" nu are
legatura cu acest proiect si poate fi malitios. Proiectul e **doar Swift**
— daca un repo care zice ca e mRemoteNXT contine Lua, Python, JavaScript
sau executabile gata facute, nu-l clona si nu rula nimic din el.

## Disclaimer

Acest proiect nu este afiliat cu, nu este sustinut de si nu este garantat de
echipa mRemoteNG. "mRemoteNG" este folosit doar ca referinta de
compatibilitate de format.

## Autor

Razvan Cremenescu — <https://github.com/cremenescu>
