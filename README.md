# Performance Manager for Galaxy Book

## Installazione rapida

Apri **PowerShell come Amministratore** ed esegui:

```powershell
irm https://raw.githubusercontent.com/AngPao29/PerformanceManagerGB/main/Install.ps1 | iex
```

Lo script scarica automaticamente l'ultima release, la installa in `C:\Scripts` e registra il Task Pianificato.

## Release / Aggiornamento

Ogni nuovo tag git nel formato `v*.*.*` (es. `v1.2.0`) genera automaticamente una GitHub Release con lo zip aggiornato.

Per aggiornare all'ultima versione, ri-esegui semplicemente la one-liner di installazione rapida sopra.

Per creare una nuova release:
```bash
git tag v1.2.0
git push origin v1.2.0
```

Gestisce automaticamente la modalità prestazioni del Galaxy Book in base ad alimentazione e carica batteria.

## Requisiti

- Windows con PowerShell 5+ o 7+ (`pwsh.exe`)
- Privilegi di Amministratore
- Samsung Settings installato

## Prima installazione

Aprire un terminale **come Amministratore** ed eseguire:

```powershell
pwsh -ExecutionPolicy Bypass -File "C:\Scripts\Installa-TaskPianificato.ps1"
```

Il task partirà automaticamente ad ogni accesso.

## Aggiornamento dopo modifiche

Il task pianificato punta direttamente a `C:\Scripts\PerformanceManagerGB.ps1`, quindi basta:

1. **Fermare il task in esecuzione** (terminale Amministratore):
   ```powershell
   Stop-ScheduledTask -TaskName "Performance Manager for Galaxy Book"
   ```
2. **Salvare le modifiche** al file `.ps1`
3. **Riavviare il task**:
   ```powershell
   Start-ScheduledTask -TaskName "Performance Manager for Galaxy Book"
   ```

> Se modifichi anche `Installa-TaskPianificato.ps1` (es. parametri del task), riesegui lo script di installazione: sovrascriverà il task esistente.

### Ciclo test locale (senza tag/push/IRM)

Per iterare rapidamente in locale:

1. **Esegui test Pester**:
   ```powershell
   Invoke-Pester -Path .\Tests -Output Detailed
   ```
2. **Aggiorna script usato dal task**:
   ```powershell
   Copy-Item .\PerformanceManagerGB.ps1 C:\Scripts\PerformanceManagerGB.ps1 -Force
   ```
3. **Riavvia task pianificato**:
   ```powershell
   Stop-ScheduledTask -TaskName "Performance Manager for Galaxy Book" -ErrorAction SilentlyContinue
   Start-ScheduledTask -TaskName "Performance Manager for Galaxy Book"
   ```

Opzionale: crea una symlink/hardlink tra `C:\Scripts\PerformanceManagerGB.ps1` e file nel repo, così non serve `Copy-Item` a ogni modifica.

## Disinstallazione

Esegui `Uninstall.ps1` come Amministratore:

```powershell
irm https://raw.githubusercontent.com/AngPao29/PerformanceManagerGB/main/Uninstall.ps1 | iex
```

Oppure, se hai già clonato il repo:

```powershell
pwsh -ExecutionPolicy Bypass -File Uninstall.ps1
```

Lo script ferma e rimuove tutti i task pianificati associati ed elimina i file da `C:\Scripts`.
