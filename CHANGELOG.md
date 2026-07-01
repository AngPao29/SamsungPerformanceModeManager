# Changelog

Tutte le modifiche rilevanti a questo progetto sono documentate qui.  
Formato basato su [Keep a Changelog](https://keepachangelog.com/it/1.0.0/),
versioning secondo [Semantic Versioning](https://semver.org/).

---

## [Unreleased]
### Added
- Nuove modalità energetiche: Silenzioso e Nessun rumore
- Nuova voce nella tray per Riprendi/Torna ad automatico dopo un override manuale

### Fixed
- Il comando "Forza modalità" dalla tray ora usa lo stesso percorso di applicazione della logica automatica e verifica la modalità realmente impostata prima di aggiornare UI/stato

## [1.0.4] - 2026-03-04
### Fixed
- "Forza Ottimizzata" e "Forza Prestazioni Elevate" ora applicano la modalità istantaneamente: i click handler segnalano il `WakeSignal` condiviso, risvegliando immediatamente il loop principale invece di attendere il prossimo ciclo di polling (30 s)
- Il colore dell'icona nella system tray si aggiorna subito dopo aver forzato una modalità (conseguenza diretta del fix precedente)
- Prevenuta race condition: se un evento hardware e un override manuale coincidono nello stesso ciclo, l'override non viene annullato prematuramente (`$justForced`)
- Limite tooltip `NotifyIcon` alzato da 63 a 127 caratteri (massimo reale .NET) per evitare troncamento del testo "Override manuale attivo"
- La modalità forzata manualmente dalla tray non viene più sovrascritta dal ciclo automatico: introdotto `ManualOverrideMode` che sospende la valutazione automatica fino al prossimo evento hardware genuino (AC plug/unplug)

## [1.0.3] - 2026-03-02
### Changed
- Rinominato il progetto in PerformanceManagerGB nel README e negli script

## [1.0.2] - 2026
### Added
- Compatibilità con PowerShell 5.1+

## [1.0.1] - 2026
### Added
- Possibilità di disabilitare i popup di notifica
- Test Pester per i moduli principali

## [1.0.0] - 2026
### Added
- Prima versione pubblica
- Gestione automatica della modalità prestazioni in base ad alimentazione e carica
- Task Pianificato di Windows per l'avvio automatico all'accesso
