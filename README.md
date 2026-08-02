# ppv — powerapps-versioning

Interaktivní terminálové CLI (Windows) pro verzování exportů Power Platform solution v gitu — v **rozbalené, čitelné podobě**, ne jako binární `.zip`. Podporuje víc prostředí (dev/test/prod/…) najednou.

```
> ppv

  ╭──────────────────────────────────────────────────────────────────────────╮
  │  ppv  Power Platform solution versioning                                 │
  ╰──────────────────────────────────────────────────────────────────────────╯

  Aktivni prostredi     dev
  Repozitar             C:\repo\powerapps-versioning

  ❯ Synchronizovat solution
    Sprava prostredi
    Stav repozitare
    Nastaveni
    Konec
```

## Požadavky

| | |
|---|---|
| **Power Platform CLI** | `pac --version` musí něco vrátit |
| **git** | `git --version` |
| **PowerShell** | 7.x doporučeno (`pwsh`). Windows PowerShell 5.1 funguje taky. |

## Spuštění

Dvojklik na `ppv.cmd`, nebo z terminálu:

```powershell
.\ppv.cmd
```

Při prvním spuštění tě provede **setup průvodce**: založí git repo (pokud chybí), zeptá se na strukturu zdroje a založí první prostředí (URL + přihlášení přes `pac auth`, otevře se prohlížeč).

## Interaktivní menu

- **Synchronizovat solution** — vybereš prostředí → zdroj (zip ze složky `drop\`, nebo rovnou export z prostředí, s multi-selectem solutions) → volitelně commit/tag/push.
- **Správa prostředí** — přidat/upravit/odebrat prostředí, přepnout aktivní, ověřit nebo obnovit `pac auth` přihlášení.
- **Stav repozitáře** — branch, necommitnuté změny, posledních 8 commitů.
- **Porovnat commity** — vybereš dva commity z historie (starší → novější, nebo HEAD) a zobrazí se souhrn změn, volitelně i plný diff (do konzole nebo uložit jako `.patch`).
- **Nastavení** — auto-commit/tag/push, formátování JSON, režim rozbalení canvas appů.

Ovládání: šipky nahoru/dolů, `Enter` potvrdit, `Esc` zpět, u víceného výběru navíc mezerník (přepnout) a `a` (vše/nic). Když terminál neumí číst klávesy (např. spouštíš přes nějaký wrapper), CLI samo přepne na číslovaný seznam a zadání čísla přes `Enter`.

## Příkazová řádka (automatizace, CI)

Stejné jádro jde ovládat i bez menu:

```powershell
ppv.cmd sync -Environment dev                                   # zpracuje zipy z drop\
ppv.cmd sync -Environment prod -Mode Export -Solution MojeSolution -Tag -Push
ppv.cmd sync -Environment dev -Zip C:\Temp\MojeSolution.zip -NoCommit
ppv.cmd env list
ppv.cmd status
ppv.cmd diff -From v1.2.0 -To HEAD
ppv.cmd diff -From abc1234 -To def5678 -Path src/dev/MojeSolution
```

| Parametr `sync` | Význam |
|---|---|
| `-Environment <name>` | povinné (nebo nastav `activeEnvironment` v configu) |
| `-Mode Drop\|Export` | zdroj zipu (výchozí `Drop`) |
| `-Solution <name,...>` | omezí export/výběr na konkrétní solution |
| `-Zip <cesta>` | konkrétní soubor mimo `drop\` |
| `-NoCommit` | rozbalí a normalizuje, ale necommitne |
| `-Tag` | vytvoří tag `<prostredi>/<Solution>/v<Verze>` |
| `-Push` | po commitu pushne |
| `-Message "..."` | vlastní commit message |

| Parametr `diff` | Význam |
|---|---|
| `-From <ref>` | povinné — commit hash, tag nebo branch |
| `-To <ref>` | výchozí `HEAD` |
| `-Path <relativni-cesta>` | omezí diff na podslozku (napr. konkretni solution/prostredi) |

`diff` v davkovem rezimu vzdy vypise cely diff rovnou do konzole (bez interaktivnich dotazu), takze se da presmerovat do souboru (`ppv.cmd diff -From v1 -To v2 > zmeny.patch`).

## Struktura repa

```
├─ drop/                          sem exportované zipy (gitignored)
├─ src/
│  └─ <prostredi>/<Solution>/     ← tohle je to, co se verzuje
│     ├─ Other/Solution.xml          verze, publisher, komponenty
│     ├─ Workflows/*.json            cloud flows (naformátované)
│     └─ CanvasApps/src/             rozbalené canvas appy (.fx.yaml)
├─ tools/
│  ├─ ppv.ps1                     hlavní CLI
│  └─ lib/                        PPV.Config / UI / Pac / Common / Sync / Setup / Compare
├─ ppv.config.json                vytvoří setup průvodce při prvním spuštění
└─ ppv.cmd                        dvojklikatelný launcher
```

Struktura `src\<prostredi>\<Solution>` (výchozí, `sourceLayout: byEnvironment`) umožňuje mít dev/test/prod vedle sebe a **diffovat je mezi sebou** (`git diff src/dev/MojeSolution src/prod/MojeSolution`). Pro jedno prostředí lze v Nastavení přepnout na `bySolution` (`src\<Solution>` bez mezistupně).

## Instalace do vlastního solution repa (`install.ps1`)

Tenhle repozitář (`PA-versioning-tool`) obsahuje **kód nástroje**. Solution ale verzuj v **samostatném** repu — typicky lokálním, nebo na tvém interním git serveru — nikdy ne v tomhle. `install.ps1` zkopíruje `tools\`, `ppv.cmd`, `.gitignore` a `.gitattributes` do cílové složky a založí tam `git init` (bez remote), pokud tam ještě žádný repo není:

```powershell
git clone https://github.com/ret3030/PA-versioning-tool.git C:\Nastroje\PA-versioning-tool
cd C:\Nastroje\PA-versioning-tool
.\install.ps1 -Target C:\Users\<jmeno>\PowerApps-Solutions

cd C:\Users\<jmeno>\PowerApps-Solutions
.\ppv.cmd
```

`ppv.config.json`, `src\` a `drop\` v cílové složce se nikdy nepřepisují — `install.ps1` je proto bezpečné spouštět opakovaně i jen pro aktualizaci nástroje (po `git pull` v klonu `PA-versioning-tool` znovu spusť `install.ps1` se stejným `-Target`).

## Prostředí a přihlášení

Každé prostředí má vlastní pojmenovaný `pac auth` profil (`ppv-<nazev>`), takže přepínání mezi dev/test/prod nepřepisuje přihlášení ostatních — CLI před každou operací sám vybere správný profil (`pac auth select`). Profily se dají kdykoliv spravovat v menu **Správa prostředí → Ověřit / obnovit přihlášení**.

## Konfigurace (`ppv.config.json`)

```jsonc
{
  "version": 2,
  "pacPath": "pac",                 // nebo plná cesta k pac.exe
  "sourceLayout": "byEnvironment",  // byEnvironment | bySolution
  "activeEnvironment": "dev",

  "environments": [
    {
      "name": "dev",
      "url": "https://dev-org.crm4.dynamics.com",
      "authProfile": "ppv-dev",
      "packageType": "Unmanaged",   // Unmanaged | Managed | Both
      "solutions": ["MojeSolution"]
    },
    {
      "name": "prod",
      "url": "https://prod-org.crm4.dynamics.com",
      "authProfile": "ppv-prod",
      "packageType": "Managed",
      "solutions": ["MojeSolution"]
    }
  ],

  "canvas": { "mode": "Auto" },       // Auto | ProcessFlag | PerMsapp | None

  "normalize": {
    "prettyPrintJson": true,
    "scrubTimestamps": true,
    "removeNoiseFiles": true,
    "noiseFiles": ["Entropy.json", "AppCheckerResult.sarif"]
  },

  "git": {
    "autoCommit": true,
    "tag": false,
    "push": false,
    "messageTemplate": "[{env}] {solution} {version} ({type})"
    // placeholdery: {env} {solution} {version} {type} {date}
  }
}
```

Starší jednoprostředový config (`environment`/`solutions` v kořeni) se při načtení automaticky migruje na tuhle strukturu — nic se nemusí ručně přepisovat.

---

## Proč to dělá zrovna tohle

**Cílová složka se před rozbalením maže.** `pac` má na to přepínač `--allowDelete`, ale ten [ve spojení s `--processCanvasApps` maže rozbalený zdroj canvas appu při druhém spuštění](https://github.com/microsoft/powerplatform-vscode/issues/334). Vyčištění vlastní režií je spolehlivější a smazané komponenty se stejně korektně projeví jako smazání v gitu.

**Normalizace není kosmetika.** Bez ní ti každý export vyrobí stovky řádků falešných změn — `Entropy.json` a `AppCheckerResult.sarif` se generují znovu při každém rozbalení, `Header.json` obsahuje `LastSavedDateTimeUTC`, které se mění i bez reálné úpravy, a flow definice bývají v exportu na jednom řádku (po naformátování je z diffu vidět, která akce se skutečně změnila).

**Commit se přeskočí, když se nic nezměnilo** — v historii tak nezůstávají prázdné commity z pokusných exportů.

**Prostředí jsou oddělená na úrovni cesty i auth profilu**, aby náhodné přepnutí prostředí v `pac` nezpůsobilo export dat z jiného org do špatné složky.

## Na co si dát pozor

⚠️ **Canvas appy: `--processCanvasApps` i `pac canvas pack/unpack` jsou označené jako deprecated.** Microsoft místo toho [doporučuje Power Platform Git integration](https://learn.microsoft.com/en-us/power-platform/developer/cli/reference/canvas). Zatím to funguje a nástroj má fallback (`Auto` → zkusí přepínač, při selhání rozbalí každý `.msapp` zvlášť), ale počítej s tím, že to jednou přestane fungovat úplně.

⚠️ **Tohle je nástroj na *verzování*, ne na nasazování.** Zpětné zabalení (`pac solution pack`) z rozbalených zdrojů je vlastní téma se svými nástrahami — u canvas appů se s deprecated packerem nedoporučuje vůbec. Pro nasazení dál používej původní zip.

⚠️ **Nekomitni tajemství.** Connection references a environment variables mohou mít v exportu vyplněné hodnoty. Před prvním pushem si projdi `src\<prostredi>\<Solution>\environmentvariabledefinition` a `Other\Customizations.xml`.

## Zscaler / firemní síť

Rozbalování, normalizace i git commit jsou **plně offline** — firemní proxy do nich nemluví. Síť potřebuješ jen na dvě věci:

- **`pac auth create`** (otevře prohlížeč) a **export z prostředí** — pokud tady dostáváš TLS chyby, nejjednodušší je exportovat solution ručně z prohlížeče, hodit zip do `drop\` a zvolit v menu "Zpracovat zipy ze složky drop\". Nástroj kvůli tomu umí obojí.
- **`git push`**, pokud remote používáš. Bez remote funguje repo čistě lokálně — historie a diffy jsou stejně užitečné.

Pokud `pac` hlásí chyby certifikátu, bývá to firemní MITM proxy a řešením je doplnit firemní root CA do trust store, který .NET používá — záleží na nastavení tvého IT.

## Řešení problémů

| Chyba | Co s tím |
|---|---|
| `pac CLI nenalezeno` | nainstaluj (`winget install Microsoft.PowerAppsCLI`) nebo nastav `pacPath` v configu |
| `Auth profil '...' neexistuje` | menu **Správa prostředí → Ověřit / obnovit přihlášení**, nebo `pac auth create --name ppv-<env> --environment <url>` |
| `Export selhal` | `pac auth list` — vypršelo přihlášení pro dané prostředí? |
| `V archivu chybi solution.xml` | zip není export solution (nebo je to zabalený `.msapp`) |
| `--processCanvasApps neprosel` | normální, fallback se spustí sám; natvrdo obejdeš v Nastavení → Canvas režim → `PerMsapp` |
| Obří diff i bez reálné změny | zkontroluj `.gitattributes` (`text=auto`), případně přidej problémový soubor do `noiseFiles` |
| `execution of scripts is disabled` | `ppv.cmd` už řeší `-ExecutionPolicy Bypass`; při přímém volání `.ps1` ho přidej taky |
