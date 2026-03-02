# Performance Manager for Galaxy Book

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

## Disinstallazione

```powershell
Stop-ScheduledTask -TaskName "Performance Manager for Galaxy Book"
Unregister-ScheduledTask -TaskName "Performance Manager for Galaxy Book" -Confirm:$false
```
