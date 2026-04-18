# NeovimLog Architecture Map (AI Optimized)

## PROJECT: NeovimLog (Logseq in Neovim)
## STATE: Global config via logseq.config.current. Buffer-local init via vim.b.logseq_active.
## ENTRY: lua/logseq/init.lua sets up commands, autocmds, and UI bindings.
## Modulkart (Komplett oversikt)
### CORE & STATE
lua/logseq/init.lua: Hovedinngang for plugin, kommandoer (inkl. :LogseqConflicts og :LogseqRecover), autocmds og aktivering av moduler.

lua/logseq/config.lua: Leser/skriver state og håndterer defaults for innstillinger.

lua/logseq/util.lua: Hjelpefunksjoner for stihåndtering, normalisering og filnavn-koding.

lua/logseq/prev_metrics.lua: Sporing av ytelse/tilstand.

### DATA & PARSING
lua/logseq/parser.lua: Tolker Logseq Markdown til et tre (AST) og cacher pr. buffer.

lua/logseq/indexer.lua: Asynkron skanning av vault for backlinks og tags.

lua/logseq/query_engine.lua: Backend for evaluering av Logseq-spørringer.

lua/logseq/query_parser.lua: Tolker syntaksen i spørringer.

### EDITING & MOTIONS
lua/logseq/editing.lua: Insert mode mappings, property-håndtering og smart split.

lua/logseq/motions.lua: Blokknigasjon (parent, child, siblings) og flytting av trær.

lua/logseq/fold.lua: Logikk for folding/skjuling av blokker.

lua/logseq/dedup.lua: Fjerner duplikate linjer i buffer eller hele vaultet.

lua/logseq/zoom.lua: Funksjonalitet for å isolere/fokusere på en spesifikk blokk.

### LINKS & NAVIGATION
lua/logseq/links.lua: Følger [[wikilinks]], ((block-refs)) og #tags.

lua/logseq/backlinks.lua: Samler referanser til gjeldende side.

lua/logseq/file_search.lua: Fillsøk-integrasjon for vault.

lua/logseq/page_search.lua: Sidesøk/fuzzy-søk for navigasjon.

lua/logseq/namespace_tree.lua: Håndterer Logseqs namespaces (NS___Child).

### UI & PANELS
lua/logseq/ui.lua: Winbar, statusline og concealment.

lua/logseq/panels.lua: Sidevinduer (backlinks, queries).

lua/logseq/config_ui.lua: Interaktivt grensesnitt for snarveier.

lua/logseq/query_ui.lua: Visning av query-resultater.

lua/logseq/query_builder.lua: Verktøy for å bygge queries interaktivt.

lua/logseq/templates.lua: Maler og interaktive placeholders.

lua/logseq/slash_commands.lua: Menysystem for / kommandoer.

### INTEGRATIONS
lua/logseq/calendar.lua: ICS kalendersynkronisering.

lua/logseq/reminders.lua: Møtevarsler i winbar.

lua/logseq/autosave.lua: Sikkerhetsmekanismer for lagring og endringer.

lua/logseq/sync_conflicts.lua: Løser Syncthing-konflikter, tilbyr diff-verktøy for manuell fletting, og varsler om gjenoppretting.

lua/logseq/embeds.lua: Håndterer block embeds.

lua/logseq/external.lua: Grensesnitt mot eksterne verktøy.

lua/logseq/ical_parser.py: Python-script for ICS-prosessering.

### OS, SETUP & INFRASTRUCTURE
init.lua: Neovim rot-konfigurasjon (når repoet brukes som standalone config).

lua/clipboard.lua: Tverrplattform utklippstavle-logikk i Lua.

clipboard.vim: Tverrplattform utklippstavle-logikk i Vimscript.

windows_setup.ps1: Setup-script for Windows.

termux_setup.sh: Setup-script for Android/Termux.

termux-url-opener: Hjelpescript for Termux.

requirements.txt: Python-avhengigheter for kalenderscriptet.

.gitattributes & .gitignore: Git-konfigurasjon.

lazy-lock.json: Låsefil for plugin-avhengigheter (hvis satt opp via lazy.nvim).

### DOCS & TESTS
README.md & lua/logseq/README.md: Prosjektdokumentasjon.

doc/logseq.txt: Neovim :help fil.

docs/backlinks.md, docs/dedup.md, docs/queries.md, docs/templates.md: Feature-dokumentasjon.

tests/test_parser.lua: Enhetstester for AST-parseren.
