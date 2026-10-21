# Mac Diagnostika

Technická diagnostika Macu jedním příkazem v Terminálu. Nic se neinstaluje a na systému se nic nemění.

## Spuštění

Otevřete **Terminál** (Cmd+mezerník → „Terminál“) a vložte:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vojnvk/maccheck/main/maccheck.sh)
```

Jen rychlé automatické kontroly (asi 5 sekund, bez ručních testů):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vojnvk/maccheck/main/maccheck.sh) --quick
```

> **Nespouštějte s `sudo`** (`sudo bash <(curl …)` skončí chybou `/dev/fd/…: Bad file descriptor`). Skript si o heslo správce řekne sám, pokud ho budete chtít použít.

Skript se průběžně ptá. Odpovídáte `a` (ano), `n` (ne) nebo `p` (přeskočit), případně jen Enterem potvrdíte výchozí volbu.

### Přepínače

| Přepínač | Popis |
|---|---|
| `--quick` | jen automatické kontroly, bez ručních testů a zátěžového testu |
| `--no-sudo` | neptat se na heslo správce; kontroly vyžadující sudo se přeskočí |
| `--no-color` | výstup bez barev |
| `--stress-time N` | délka zátěžového testu v sekundách (výchozí 180) |
| `--help` | nápověda |

## Co se kontroluje

**Automaticky**
- **Hardware:** model, identifikátor a číslo modelu, čip, jádra CPU/GPU, RAM, SSD, sériové číslo, verze macOS
- **Activation Lock, Najít Mac, registrace MDM/DEP, konfigurační profily, SIP**
- **Baterie:** počet cyklů, stav, skutečná kapacita vůči návrhové (z `ioreg`), nabíječka
- **SSD:** SMART stav, model, kapacita; volitelně přes `smartctl` i opotřebení (Percentage Used), zapsaná data, doba provozu a chyby integrity
- **Kernel panic** za posledních 90 dní, vynucená vypnutí, pády aplikací
- **Periferie:** displej, kamera, reproduktory, mikrofon, Wi‑Fi, Bluetooth, Touch ID, klávesnice/trackpad, Thunderbolt
- **Uptime** a datum prvního nastavení systému
- Sériové číslo lze zkopírovat do schránky a otevřít [checkcoverage.apple.com](https://checkcoverage.apple.com/)

**Volitelně**
- **Zátěžový test CPU** (3 minuty, všechna jádra) se sledováním tepelného tlaku. Ctrl+C ho kdykoliv bezpečně ukončí.
- **Ruční testy:** lokální stránka v Safari (test displeje na celou obrazovku, klávesnice, trackpad), tón zvlášť v levém a pravém reproduktoru, kamera (Photo Booth), mikrofon (QuickTime) a kontrolní seznam portů
- Kontrolní seznam vizuálního stavu a návod ke spuštění Apple Diagnostics

**Sudo (volitelné, skript se zeptá):** záznam DEP z Apple Business Manageru, systémové konfigurační profily a `powermetrics` během zátěžového testu.

## Stavy a report

Každá kontrola má stav ✅ OK / ⚠️ Pozor / ❌ Chyba / ⏭️ Přeskočeno a k němu naměřenou hodnotu. Na konci se vypíše souhrn a seznam položek se stavem Pozor nebo Chyba. Report v Markdownu lze zkopírovat do schránky, případně uložit do `/tmp`.

Ukázka:

```
━━ Baterie a napájení ━━━━━━━━━━━━━━━━━━━━
  ✅ OK         Počet cyklů: 177 (návrhový limit 1000)
  ✅ OK         Stav baterie (macOS): Normal
  ✅ OK         Zdraví baterie: kapacita 95.4 % návrhové (5495 / 5760 mAh); macOS uvádí Maximum Capacity 98 %
  Aktuální nabití:         39 %
  Nabíječka:               nepřipojena

━━ Souhrn ━━━━━━━━━━━━━━━━━━━━
  ✅ OK: 19   ⚠️  Pozor: 0   ❌ Chyba: 0   ⏭️  Přeskočeno: 2
```

## Bezpečnost

- Skript **pouze čte**: nic neinstaluje, nemění nastavení ani hlasitost.
- Dočasné soubory (testovací stránka, zvuk, report) jsou ve vlastní složce v `/tmp` a po skončení se smažou.
- `smartctl` se stahuje jen na vyžádání: oficiální balíček smartmontools z GitHubu se ověří přes SHA-256 a rozbalí do dočasné složky v `/tmp`, neinstaluje se.
- Stránka s ručními testy běží lokálně, bez internetu a bez externích knihoven.
- Jeden soubor, čistý bash 3.2 (výchozí v macOS), jen nástroje dodávané s macOS.
- Před spuštěním si můžete [kód prohlédnout](maccheck.sh).

Primárně pro Apple Silicon (M1 a novější). Na Intel Macu skript poběží a kontroly, které nejsou k dispozici, označí jako přeskočené.

---

## English

**Mac Diagnostika** is a read-only hardware and system diagnostic for macOS. It is a single bash 3.2 script with no dependencies, and it installs and changes nothing.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vojnvk/maccheck/main/maccheck.sh)
```

It reports hardware details, Activation Lock / Find My / MDM status, battery cycles and capacity, SSD SMART status, kernel panics, SIP and peripherals. Optionally it runs a CPU stress test with thermal monitoring and guided manual tests (display, keyboard, trackpad, speakers, camera, microphone, ports). Output is in Czech. Options: `--quick`, `--no-sudo`, `--no-color`, `--stress-time N`, `--help`.

## Licence

[MIT](LICENSE)
