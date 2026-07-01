#Requires -RunAsAdministrator

# ============================================================================
# Samsung Galaxy Book - Performance Mode Automatico
# ============================================================================
# Compatibile con Galaxy Book Pro (registro con Value sempre presente) e
# Galaxy Book3/Book4 (Value assente finché l'utente non modifica la soglia;
# quando assente, Samsung usa 80% come default).
#
# Attiva "Prestazioni Elevate" solo quando:
#   1. Il PC è alimentato a corrente (AC)
#   2. La batteria ha raggiunto il limite di Protezione Batteria Samsung
# Se la Protezione Batteria è disabilitata, usa 100% come soglia (= carica completa).
# Il limite viene letto dinamicamente dal registro ad ogni ciclo:
#   se lo cambi in Samsung Settings, lo script si adatta automaticamente.
# ============================================================================

# --- Mutex per impedire istanze multiple ---
$mutexName = "Global\PerformanceManagerGB"
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Warning "Un'altra istanza dello script è già in esecuzione. Uscita."
    exit 1
}

try {  # try esterno: garantisce il rilascio del mutex alla fine

# --- Percorsi registro Samsung ---
$regPerformance    = "HKLM:\SOFTWARE\Samsung\SamsungSettings\ModulePerformance"
$regProtectBattery = "HKLM:\SOFTWARE\Samsung\SamsungSettings\ModuleProtectBattery"

# --- Costanti modalità Samsung ---
$MODE_NO_NOISE         = 0   # Nessun rumore
$MODE_SILENT           = 1   # Silenzioso
$MODE_OPTIMIZED        = 2   # Ottimizzata
$MODE_HIGH_PERFORMANCE = 3   # Prestazioni Elevate

# --- Mappa nomi modalità (per log leggibili) ---
$MODE_NAMES = @{
    $MODE_NO_NOISE         = 'Nessun rumore'
    $MODE_SILENT           = 'Silenzioso'
    $MODE_OPTIMIZED        = 'Ottimizzata'
    $MODE_HIGH_PERFORMANCE = 'Prestazioni Elevate'
}

# --- Mappa attesa PL1 (W) per modalità Samsung ---
$MODE_EXPECTED_PL1_W = @{
    $MODE_NO_NOISE         = 8
    $MODE_SILENT           = 18
    $MODE_OPTIMIZED        = 25
    $MODE_HIGH_PERFORMANCE = 25
}

# --- Mappa visual per notifiche (glyph + colore) ---
$MODE_VISUALS = @{
    $MODE_NO_NOISE = @{
        Glyph = [char]0xE74E  # Mute
        Color = '#7A7A7A'
    }
    $MODE_SILENT = @{
        Glyph = [char]0xE74F  # Volume basso
        Color = '#9AA0A6'
    }
    $MODE_OPTIMIZED = @{
        Glyph = [char]0xE946
        Color = '#60CDFF'
    }
    $MODE_HIGH_PERFORMANCE = @{
        Glyph = [char]0xE945
        Color = '#FFAA2C'
    }
}

# --- Mappa nomi stato batteria WMI (per log leggibili) ---
$BATTERY_STATUS_NAMES = @{
    1 = 'Batteria (scarica)'
    2 = 'AC (connesso)'
    3 = 'Carica completa'
    4 = 'Bassa'
    5 = 'Critica'
    6 = 'In carica'
    7 = 'In carica (alta)'
    8 = 'In carica (bassa)'
    9 = 'In carica (critica)'
    10 = 'Non definito'
    11 = 'Parzialmente carica'
}

# --- Costanti stato batteria WMI ---
# BatteryStatus: 2=AC, 3=Carica completa, 6=In carica, 7=In carica (alta),
#                8=In carica (bassa), 9=In carica (critica)
$AC_STATUSES = @(2, 3, 6, 7, 8, 9)

# --- Isteresi anti-oscillazione (%) ---
# Evita toggle ripetuti quando la carica oscilla intorno al limite.
# Attiva "Elevate" a >= (limite - tolleranza), torna a "Ottimizzata" solo a < (limite - margine).
$hysteresisMargin = 3

# --- Tolleranza soglia superiore (%) ---
# Sui Galaxy Book3/Book4 con protezione batteria attiva, Samsung ferma la ricarica
# ~1% sotto il limite impostato (es. 79% con limite 80%). Questa tolleranza
# permette allo script di riconoscere la carica come "limite raggiunto".
$chargeTolerance = 1

# --- Verifica PL1 dopo cambio modalità ---
$pl1VerifyMaxAttempts = 5
$pl1VerifyRetryDelayMs = 300
$script:_pl1TelemetryCimCandidates = $null

# --- Intervallo di polling (secondi) ---
$pollInterval = 30

# --- Soglia predefinita protezione batteria ---
# Sui Galaxy Book3/Book4 la proprietà "Value" nel registro non esiste finché
# l'utente non modifica la soglia in Samsung Settings. In quel caso Samsung
# usa 80% come limite predefinito.
$defaultProtectionLimit = 80

# --- File di log (stesso percorso dello script, max ~500 KB) ---
$logFile    = Join-Path $PSScriptRoot "PerformanceManagerGB.log"
$logMaxSize = 512KB

# --- Stato condiviso con la System Tray (thread-safe) ---
$script:trayState = [hashtable]::Synchronized(@{
    CurrentMode        = 'Ottimizzata'
    ChargePercent      = 0
    IsOnAC             = $false
    IsPaused           = $false
    SoundEnabled       = $true
    NotifPopupEnabled  = $true
    ControlMode        = 'Auto'   # Auto | Manual
    RequestedMode      = $null
    RequestedModeSource = $null
    ManualOverrideMode = $null
    ManualOverrideSource = $null
    ManualOverrideTimestamp = $null
    ResumeAutomaticRequested = $false
    RequestExit        = $false
    LogFile            = $logFile
    WakeSignal         = $null   # popolato dopo la creazione dell'AutoResetEvent
})

# ============================================================================
# Funzione: scrive una riga di log con timestamp (rotazione semplice)
# ============================================================================
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp  $Message"
    try {
        # Rotazione: se il file supera la dimensione massima, lo tronca
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt $logMaxSize) {
            # Mantieni solo l'ultima meta' delle righe
            $lines = Get-Content $logFile -Tail 200 -Encoding UTF8
            Set-Content $logFile -Value $lines -Encoding UTF8
        }
        Add-Content $logFile -Value $line -Encoding UTF8
    }
    catch {
        # Se non riesce a scrivere il log, prosegui comunque
    }
}

# ============================================================================
# Funzione: suono di notifica sottile al cambio modalità
# ============================================================================
function Play-NotificationSound {
    if (-not $script:trayState.SoundEnabled) { return }
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
}

# ============================================================================
# Funzione: legge il limite di protezione batteria dal registro Samsung
# Restituisce il valore % se attiva, 100 se disabilitata o non leggibile
# ============================================================================
# - Galaxy Book Pro: "Value" è sempre presente con la soglia % impostata.
# - Galaxy Book3/Book4: "Value" non esiste finché l'utente non cambia la soglia
#   in Samsung Settings (default Samsung = 80%). Una volta modificata, "Value"
#   resta anche se si riporta a 80%.
# ============================================================================
function Get-BatteryProtectionLimit {
    try {
        $protectBattery = Get-ItemProperty -Path $regProtectBattery -ErrorAction Stop
        if ($protectBattery.OnOff -eq 1) {
            if ($null -ne $protectBattery.Value) {
                return [int]$protectBattery.Value
            }
            else {
                # Galaxy Book3/4: Value assente → soglia predefinita Samsung
                return $defaultProtectionLimit
            }
        }
        else {
            # Protezione disabilitata: si considera "piena" a 100%
            return 100
        }
    }
    catch {
        # Chiave non trovata o errore di lettura → fallback sicuro
        return 100
    }
}

# ============================================================================
# Funzione: legge la modalità performance attuale dal registro Samsung
# ============================================================================
function Get-CurrentPerformanceMode {
    try {
        return [int](Get-ItemProperty -Path $regPerformance -ErrorAction Stop).Value
    }
    catch {
        return $null
    }
}

# ============================================================================
# Funzione: imposta la modalità performance nel registro Samsung
# ============================================================================
function Set-PerformanceMode {
    param([int]$Mode)
    Set-ItemProperty -Path $regPerformance -Name "Value" -Value $Mode -ErrorAction Stop
}

# ============================================================================
# Funzione: restituisce PL1 atteso per una modalità Samsung
# ============================================================================
function Get-ExpectedModePl1W {
    param([int]$Mode)
    return $MODE_EXPECTED_PL1_W[$Mode]
}

# ============================================================================
# Funzione: telemetria PL1 dinamica (mockabile in test)
# Restituisce sempre: Available, Pl1W, Source, Error
# ============================================================================
function Convert-ToPl1Watts {
    param([object]$RawValue)

    if ($null -eq $RawValue) { return $null }

    $numeric = 0.0
    $rawText = [string]$RawValue
    if (-not [double]::TryParse($rawText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$numeric)) {
        if (-not [double]::TryParse($rawText, [ref]$numeric)) {
            return $null
        }
    }

    if ($numeric -le 0) { return $null }
    if ($numeric -gt 1000) { $numeric = $numeric / 1000.0 }  # mW -> W
    if ($numeric -gt 300) { return $null }                   # filtro valori implausibili

    return [Math]::Round($numeric, 1)
}

function Get-Pl1TelemetryFromCimRuntime {
    $propertyRegex = '(?i)(PL1|Long.*Term.*Power.*Limit|PowerLimit1|Package.*Power.*Limit)'

    if ($null -eq $script:_pl1TelemetryCimCandidates) {
        $script:_pl1TelemetryCimCandidates = @()
        foreach ($namespace in @('root\wmi', 'root\Intel')) {
            try {
                $classes = Get-CimClass -Namespace $namespace -ClassName '*Power*Limit*' -ErrorAction Stop
                foreach ($class in $classes) {
                    foreach ($property in $class.CimClassProperties) {
                        if ($property.Name -match $propertyRegex) {
                            $script:_pl1TelemetryCimCandidates += [PSCustomObject]@{
                                Namespace = $namespace
                                ClassName = $class.CimClassName
                                Property  = $property.Name
                            }
                        }
                    }
                }
            }
            catch { }
        }
    }

    foreach ($candidate in $script:_pl1TelemetryCimCandidates) {
        try {
            $instance = Get-CimInstance -Namespace $candidate.Namespace -ClassName $candidate.ClassName -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $instance) { continue }

            $pl1W = Convert-ToPl1Watts -RawValue $instance.($candidate.Property)
            if ($null -eq $pl1W) { continue }

            return [PSCustomObject]@{
                Available  = $true
                Verifiable = $true
                Pl1W       = $pl1W
                Source     = "CIM:$($candidate.Namespace):$($candidate.ClassName).$($candidate.Property)"
                Error      = $null
            }
        }
        catch { }
    }

    return $null
}

function Get-Pl1TelemetryFromSamsungRegistry {
    $nameRegex = '(?i)(PL1|LongTerm|PowerLimit)'
    $paths = @($regPerformance)

    try {
        $children = Get-ChildItem -Path $regPerformance -ErrorAction Stop
        foreach ($child in $children) {
            $paths += $child.PSPath
        }
    }
    catch { }

    foreach ($path in $paths) {
        try {
            $item = Get-ItemProperty -Path $path -ErrorAction Stop
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
                if ($prop.Name -notmatch $nameRegex) { continue }

                $pl1W = Convert-ToPl1Watts -RawValue $prop.Value
                if ($null -eq $pl1W) { continue }

                return [PSCustomObject]@{
                    Available  = $false
                    Verifiable = $false
                    Pl1W       = $pl1W
                    Source     = "SamsungRegistry:$path\$($prop.Name)"
                    Error      = 'Valore configurazione rilevato, ma non verificabile come PL1 runtime attivo.'
                }
            }
        }
        catch { }
    }

    return $null
}

function Get-DynamicPl1Telemetry {
    try {
        $cimTelemetry = Get-Pl1TelemetryFromCimRuntime
        if ($null -ne $cimTelemetry) {
            return $cimTelemetry
        }

        $registryTelemetry = Get-Pl1TelemetryFromSamsungRegistry
        if ($null -ne $registryTelemetry) {
            return $registryTelemetry
        }

        return [PSCustomObject]@{
            Available = $false
            Pl1W      = $null
            Verifiable = $false
            Source    = 'NotVerifiable'
            Error     = 'Nessuna sorgente PL1 runtime disponibile (CIM/registro Samsung).'
        }
    }
    catch {
        return [PSCustomObject]@{
            Available = $false
            Pl1W      = $null
            Verifiable = $false
            Source    = 'TelemetryError'
            Error     = "$_"
        }
    }
}

# ============================================================================
# Funzione: delay retry verifica PL1 (mockabile in test)
# ============================================================================
function Wait-Pl1VerificationDelay {
    param([int]$Milliseconds)
    Start-Sleep -Milliseconds $Milliseconds
}

# ============================================================================
# Funzione: applica una modalità e verifica che sia stata realmente impostata
# ============================================================================ 
function Invoke-ModeSelection {
    param(
        [int]$Mode,
        [string]$Subtitle = '',
        [switch]$PlaySound
    )

    Set-PerformanceMode -Mode $Mode

    $appliedMode = Get-CurrentPerformanceMode
    if ($appliedMode -ne $Mode) {
        $expectedName = $MODE_NAMES[$Mode]
        if (-not $expectedName) { $expectedName = "$Mode" }
        $appliedName = $MODE_NAMES[$appliedMode]
        if (-not $appliedName) { $appliedName = "$appliedMode" }
        throw "Verifica applicazione fallita: richiesta=$expectedName($Mode), rilevata=$appliedName($appliedMode)."
    }

    $expectedPl1W = Get-ExpectedModePl1W -Mode $Mode
    if ($null -ne $expectedPl1W) {
        $telemetry = Get-DynamicPl1Telemetry
        $supportsVerifiableFlag = $telemetry.PSObject.Properties.Name -contains 'Verifiable'
        $isVerifiableTelemetry = $telemetry.Available -and ((-not $supportsVerifiableFlag) -or $telemetry.Verifiable)

        if ($isVerifiableTelemetry) {
            $verified = $false
            for ($attempt = 1; $attempt -le $pl1VerifyMaxAttempts; $attempt++) {
                if ($telemetry.Pl1W -eq $expectedPl1W) {
                    $verified = $true
                    Write-Log "DEBUG Verifica PL1 OK: modalita=$Mode, PL1=${expectedPl1W}W, sorgente=$($telemetry.Source), tentativo=$attempt."
                    break
                }

                if ($attempt -lt $pl1VerifyMaxAttempts) {
                    Wait-Pl1VerificationDelay -Milliseconds $pl1VerifyRetryDelayMs
                    $telemetry = Get-DynamicPl1Telemetry
                }
            }

            if (-not $verified) {
                $actualPl1Text = if ($null -ne $telemetry.Pl1W) { "$($telemetry.Pl1W)W" } else { 'n/d' }
                throw "Verifica PL1 fallita: modalita=$Mode, atteso=${expectedPl1W}W, rilevato=$actualPl1Text, sorgente=$($telemetry.Source), errore=$($telemetry.Error)."
            }
        }
        elseif ($null -ne $telemetry.Pl1W) {
            Write-Log "WARN  Telemetria PL1 non verificabile runtime: valore=$($telemetry.Pl1W)W, modalita=$Mode, sorgente=$($telemetry.Source), dettaglio=$($telemetry.Error)."
        }
        else {
            Write-Log "WARN  Telemetria PL1 non disponibile: salto verifica (modalita=$Mode, sorgente=$($telemetry.Source), errore=$($telemetry.Error))."
        }
    }

    $modeName = $MODE_NAMES[$Mode]
    if (-not $modeName) { $modeName = "$Mode" }
    $visual = $MODE_VISUALS[$Mode]
    if (-not $visual) {
        $visual = @{
            Glyph = [char]0xE946
            Color = "#60CDFF"
        }
    }

    Show-ModeNotification -ModeName $modeName -IconGlyph $visual.Glyph -AccentColor $visual.Color -Subtitle $Subtitle
    if ($PlaySound) {
        Play-NotificationSound
    }
}

# ============================================================================
# Funzione: mostra un overlay OSD (stile Samsung Fn+F11) al cambio modalità
# Viene eseguito in un runspace STA separato, non blocca il loop principale.
# ============================================================================
$script:_notifPS = $null
$script:_notifRS = $null

function Show-ModeNotification {
    param(
        [string]$ModeName,
        [string]$IconGlyph,
        [string]$AccentColor,
        [string]$Subtitle = ''
    )
    if (-not $script:trayState.NotifPopupEnabled) { return }
    try {
        # Pulizia risorse della notifica precedente
        if ($script:_notifPS) {
            try { $script:_notifPS.Stop(); $script:_notifPS.Dispose() } catch { }
            try { $script:_notifRS.Close(); $script:_notifRS.Dispose() } catch { }
        }

        $script:_notifRS = [runspacefactory]::CreateRunspace()
        $script:_notifRS.ApartmentState = "STA"
        $script:_notifRS.ThreadOptions  = "ReuseThread"
        $script:_notifRS.Open()

        $script:_notifPS = [powershell]::Create()
        $script:_notifPS.Runspace = $script:_notifRS

        [void]$script:_notifPS.AddScript({
            param($ModeName, $IconGlyph, $AccentColor, $Subtitle)
            try {
                Add-Type -AssemblyName PresentationFramework
                Add-Type -AssemblyName PresentationCore
                Add-Type -AssemblyName WindowsBase

                $xamlString = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    WindowStyle="None" AllowsTransparency="True" Background="Transparent"
    Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight"
    ResizeMode="NoResize" Opacity="0">
  <Window.Triggers>
    <EventTrigger RoutedEvent="Window.Loaded">
      <BeginStoryboard>
        <Storyboard>
          <DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity">
            <EasingDoubleKeyFrame KeyTime="0:0:0.0" Value="0"/>
            <EasingDoubleKeyFrame KeyTime="0:0:0.3" Value="1">
              <EasingDoubleKeyFrame.EasingFunction>
                <QuadraticEase EasingMode="EaseOut"/>
              </EasingDoubleKeyFrame.EasingFunction>
            </EasingDoubleKeyFrame>
            <EasingDoubleKeyFrame KeyTime="0:0:2.5" Value="1"/>
            <EasingDoubleKeyFrame KeyTime="0:0:3.0" Value="0">
              <EasingDoubleKeyFrame.EasingFunction>
                <QuadraticEase EasingMode="EaseIn"/>
              </EasingDoubleKeyFrame.EasingFunction>
            </EasingDoubleKeyFrame>
          </DoubleAnimationUsingKeyFrames>
        </Storyboard>
      </BeginStoryboard>
    </EventTrigger>
  </Window.Triggers>
  <Border Background="#EB1E1E2E" CornerRadius="16" Padding="28,18" Margin="20"
          BorderBrush="#1EFFFFFF" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="20" ShadowDepth="4" Opacity="0.5" Color="Black"/>
    </Border.Effect>
    <StackPanel Orientation="Horizontal">
      <TextBlock x:Name="IconText" FontFamily="Segoe MDL2 Assets" FontSize="34"
                 VerticalAlignment="Center" Margin="0,0,18,0"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock Text="Modalità Prestazioni" FontSize="12"
                   FontFamily="Segoe UI Variable, Segoe UI" FontWeight="Light"
                   Foreground="#8CFFFFFF" Margin="0,0,0,2"/>
        <TextBlock x:Name="ModeLabel" FontSize="20"
                   FontFamily="Segoe UI Variable, Segoe UI" FontWeight="SemiBold"
                   Foreground="White"/>
        <TextBlock x:Name="SubtitleLabel" FontSize="11"
                   FontFamily="Segoe UI Variable, Segoe UI" FontWeight="Normal"
                   Foreground="#8CFFFFFF" Margin="0,4,0,0"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
                [xml]$xaml = $xamlString
                $reader = [System.Xml.XmlNodeReader]::new($xaml)
                $window = [System.Windows.Markup.XamlReader]::Load($reader)

                # Imposta contenuti dinamici
                $window.FindName("IconText").Text      = $IconGlyph
                $window.FindName("IconText").Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($AccentColor)
                $window.FindName("ModeLabel").Text      = $ModeName

                # Sottotitolo (info contestuale: carica, alimentazione, motivo)
                $subtitleBlock = $window.FindName("SubtitleLabel")
                if ($Subtitle) { $subtitleBlock.Text = $Subtitle }
                else { $subtitleBlock.Visibility = [System.Windows.Visibility]::Collapsed }

                # Posiziona in basso al centro, sopra la taskbar
                $window.Add_Loaded({
                    param($sender, $e)
                    $wa = [System.Windows.SystemParameters]::WorkArea
                    $sender.Left = $wa.Left + ($wa.Width  - $sender.ActualWidth)  / 2
                    $sender.Top  = $wa.Bottom - $sender.ActualHeight - 40
                })

                # Chiudi dopo fine animazione (3.1 s)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(3100)
                $timer.Add_Tick({
                    param($s, $e)
                    $s.Stop()
                    $window.Close()
                }.GetNewClosure())
                $timer.Start()

                [void]$window.ShowDialog()
            }
            catch { }  # Notifica non critica: errori silenziati
        }).AddArgument($ModeName).AddArgument($IconGlyph).AddArgument($AccentColor).AddArgument($Subtitle)

        [void]$script:_notifPS.BeginInvoke()
    }
    catch {
        Write-Log "WARN  Impossibile mostrare notifica OSD: $_"
    }
}

# ============================================================================
# Funzione: System Tray Icon (runspace STA separato con message pump WinForms)
# Mostra stato corrente, permette di forzare la modalità o sospendere.
# ============================================================================
$script:_trayPS = $null
$script:_trayRS = $null

function Start-TrayIcon {
    $script:_trayRS = [runspacefactory]::CreateRunspace()
    $script:_trayRS.ApartmentState = "STA"
    $script:_trayRS.ThreadOptions  = "ReuseThread"
    $script:_trayRS.Open()

    $script:_trayPS = [powershell]::Create()
    $script:_trayPS.Runspace = $script:_trayRS

    [void]$script:_trayPS.AddScript({
        param($State)

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        # DPI awareness: necessaria per posizionamento corretto su schermi HiDPI
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@ -ErrorAction SilentlyContinue
        [DpiHelper]::SetProcessDPIAware() | Out-Null

        # --- Crea icone colorate 16x16 ---
        function New-CircleIcon([string]$HexColor) {
            $bmp = [System.Drawing.Bitmap]::new(16, 16)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.Clear([System.Drawing.Color]::Transparent)
            $brush = [System.Drawing.SolidBrush]::new(
                [System.Drawing.ColorTranslator]::FromHtml($HexColor))
            $g.FillEllipse($brush, 0, 0, 15, 15)
            $brush.Dispose(); $g.Dispose()
            return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        }

        $iconNoNoise = New-CircleIcon "#7A7A7A"  # Grigio scuro: Nessun rumore
        $iconSilent  = New-CircleIcon "#9AA0A6"  # Grigio chiaro: Silenzioso
        $iconOpt     = New-CircleIcon "#60CDFF"  # Blu: Ottimizzata
        $iconPerf    = New-CircleIcon "#FFAA2C"  # Arancione: Prestazioni Elevate
        $iconPause   = New-CircleIcon "#888888"  # Grigio: Automatismo sospeso

        # --- NotifyIcon ---
        $notify = [System.Windows.Forms.NotifyIcon]::new()
        $notify.Icon    = $iconOpt
        $notify.Text    = "Performance Manager GB"
        $notify.Visible = $true

        # --- Menu contestuale ---
        $menu = [System.Windows.Forms.ContextMenuStrip]::new()

        $statusItem = [System.Windows.Forms.ToolStripMenuItem]::new("Inizializzazione...")
        $statusItem.Enabled = $false
        [void]$menu.Items.Add($statusItem)
        [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

        $forceNoNoiseItem = [System.Windows.Forms.ToolStripMenuItem]::new("Forza Nessun rumore")
        $forceNoNoiseItem.Add_Click({
            if ($State.ControlMode -eq 'Manual' -and $State.ManualOverrideMode -eq 0) {
                $State.ResumeAutomaticRequested = $true
            } else {
                $State.RequestedMode = 0
                $State.RequestedModeSource = 'Tray'
            }
            try { $State.WakeSignal.Set() } catch { }
        }.GetNewClosure())
        [void]$menu.Items.Add($forceNoNoiseItem)

        $forceSilentItem = [System.Windows.Forms.ToolStripMenuItem]::new("Forza Silenzioso")
        $forceSilentItem.Add_Click({
            if ($State.ControlMode -eq 'Manual' -and $State.ManualOverrideMode -eq 1) {
                $State.ResumeAutomaticRequested = $true
            } else {
                $State.RequestedMode = 1
                $State.RequestedModeSource = 'Tray'
            }
            try { $State.WakeSignal.Set() } catch { }
        }.GetNewClosure())
        [void]$menu.Items.Add($forceSilentItem)

        $forceOptItem = [System.Windows.Forms.ToolStripMenuItem]::new("Forza Ottimizzata")
        $forceOptItem.Add_Click({
            if ($State.ControlMode -eq 'Manual' -and $State.ManualOverrideMode -eq 2) {
                $State.ResumeAutomaticRequested = $true
            } else {
                $State.RequestedMode = 2
                $State.RequestedModeSource = 'Tray'
            }
            try { $State.WakeSignal.Set() } catch { }
        }.GetNewClosure())
        [void]$menu.Items.Add($forceOptItem)

        $forcePerfItem = [System.Windows.Forms.ToolStripMenuItem]::new("Forza Prestazioni Elevate")
        $forcePerfItem.Add_Click({
            if ($State.ControlMode -eq 'Manual' -and $State.ManualOverrideMode -eq 3) {
                $State.ResumeAutomaticRequested = $true
            } else {
                $State.RequestedMode = 3
                $State.RequestedModeSource = 'Tray'
            }
            try { $State.WakeSignal.Set() } catch { }
        }.GetNewClosure())
        [void]$menu.Items.Add($forcePerfItem)

        $resumeAutoItem = [System.Windows.Forms.ToolStripMenuItem]::new("Riprendi automatico")
        $resumeAutoItem.Enabled = $false
        $resumeAutoItem.Add_Click({
            $State.ResumeAutomaticRequested = $true
            try { $State.WakeSignal.Set() } catch { }
        }.GetNewClosure())
        [void]$menu.Items.Add($resumeAutoItem)

        [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

        $pauseItem = [System.Windows.Forms.ToolStripMenuItem]::new("Sospendi automatismo")
        $pauseItem.CheckOnClick = $true
        $pauseItem.Add_CheckedChanged({
            $State.IsPaused = $pauseItem.Checked
        }.GetNewClosure())
        [void]$menu.Items.Add($pauseItem)

        $soundItem = [System.Windows.Forms.ToolStripMenuItem]::new("Suono notifica")
        $soundItem.CheckOnClick = $true
        $soundItem.Checked = $State.SoundEnabled
        $soundItem.Add_CheckedChanged({
            $State.SoundEnabled = $soundItem.Checked
        }.GetNewClosure())
        [void]$menu.Items.Add($soundItem)

        $popupItem = [System.Windows.Forms.ToolStripMenuItem]::new("Popup notifiche")
        $popupItem.CheckOnClick = $true
        $popupItem.Checked      = $State.NotifPopupEnabled
        $popupItem.Add_CheckedChanged({
            $State.NotifPopupEnabled = $popupItem.Checked
        }.GetNewClosure())
        [void]$menu.Items.Add($popupItem)

        [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

        $logItem = [System.Windows.Forms.ToolStripMenuItem]::new("Apri file di log")
        $logItem.Add_Click({
            try { [System.Diagnostics.Process]::Start('notepad.exe', $State.LogFile) } catch { }
        }.GetNewClosure())
        [void]$menu.Items.Add($logItem)

        [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

        $exitItem = [System.Windows.Forms.ToolStripMenuItem]::new("Esci")
        $exitItem.Add_Click({
            $State.RequestExit = $true
            try { $State.WakeSignal.Set() } catch { }
            [System.Windows.Forms.Application]::Exit()
        }.GetNewClosure())
        [void]$menu.Items.Add($exitItem)

        $notify.ContextMenuStrip = $menu

        # Metodo privato ShowContextMenu: usa TrackPopupMenuEx di Win32
        # che posiziona e chiude il menu correttamente (anche dalla tray overflow).
        $showMenuMethod = [System.Windows.Forms.NotifyIcon].GetMethod(
            'ShowContextMenu',
            [System.Reflection.BindingFlags]'Instance,NonPublic'
        )

        $notify.Add_MouseClick({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
                $showMenuMethod.Invoke($notify, $null)
            }
        }.GetNewClosure())

        # --- Timer: aggiorna tooltip e icona ogni 2s dallo stato condiviso ---
        $timer = [System.Windows.Forms.Timer]::new()
        $timer.Interval = 2000
        $timer.Add_Tick({
            $mode   = $State.CurrentMode
            $charge = $State.ChargePercent
            $ac     = if ($State.IsOnAC) { "AC" } else { "Batteria" }
            $paused = $State.IsPaused
            $controlMode = $State.ControlMode

            $manualOverride = if ($controlMode -eq 'Manual') { $State.ManualOverrideMode } else { $null }

            # Checkmark radio-style sui menu Forza X (solo uno selezionato alla volta)
            $forceNoNoiseItem.Checked = ($manualOverride -eq 0)
            $forceSilentItem.Checked  = ($manualOverride -eq 1)
            $forceOptItem.Checked     = ($manualOverride -eq 2)
            $forcePerfItem.Checked    = ($manualOverride -eq 3)
            $resumeAutoItem.Enabled   = ($controlMode -eq 'Manual' -and $null -ne $State.ManualOverrideMode)

            # Tooltip (max 127 caratteri per NotifyIcon.Text in .NET 2.0+)
            $tip = "Modalita': $mode`nCarica: $charge% ($ac)"
            if ($paused) { $tip += "`nSospeso" }
            elseif ($null -ne $manualOverride) { $tip += "`nOverride manuale" }
            else { $tip += "`nAutomatico" }
            if ($tip.Length -gt 127) { $tip = $tip.Substring(0, 127) }
            $notify.Text = $tip

            # Icona
            if ($paused) {
                $notify.Icon = $iconPause
            }
            elseif ($mode -eq 'Prestazioni Elevate') {
                $notify.Icon = $iconPerf
            }
            elseif ($mode -eq 'Nessun rumore') {
                $notify.Icon = $iconNoNoise
            }
            elseif ($mode -eq 'Silenzioso') {
                $notify.Icon = $iconSilent
            }
            else {
                $notify.Icon = $iconOpt
            }

            # Status nel menu
            $statusItem.Text = "$mode | $charge% ($ac)" +
                $(if ($paused) { " | Sospeso" } elseif ($null -ne $manualOverride) { " | Override" } else { " | Automatico" })

            # Shutdown richiesto dal loop principale
            if ($State.RequestExit) { [System.Windows.Forms.Application]::Exit() }
        }.GetNewClosure())
        $timer.Start()

        # Form nascosta come proprietaria del message pump.
        # Necessaria perche' senza una finestra proprietaria, WinForms non
        # riesce a calcolare correttamente la posizione del ContextMenuStrip.
        $ownerForm = [System.Windows.Forms.Form]::new()
        $ownerForm.ShowInTaskbar = $false
        $ownerForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
        $ownerForm.Size = [System.Drawing.Size]::new(0, 0)
        $ownerForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $ownerForm.Location = [System.Drawing.Point]::new(-32000, -32000)
        $ownerForm.Add_Shown({ $this.Hide() })
        [System.Windows.Forms.Application]::Run($ownerForm)

        # Cleanup
        $timer.Stop(); $timer.Dispose()
        $notify.Visible = $false; $notify.Dispose()
    })

    [void]$script:_trayPS.AddArgument($script:trayState)
    [void]$script:_trayPS.BeginInvoke()
}

function Stop-TrayIcon {
    try { $script:trayState.RequestExit = $true } catch { }
    try { if ($script:_trayPS) { $script:_trayPS.Stop(); $script:_trayPS.Dispose() } } catch { }
    try { if ($script:_trayRS) { $script:_trayRS.Close(); $script:_trayRS.Dispose() } } catch { }
}

# ============================================================================
# Funzione: valuta lo stato corrente e aggiorna la modalità se necessario
# ============================================================================
function Update-PerformanceMode {
    param(
        [string]$Trigger = 'polling'
    )

    # Lettura stato batteria hardware
    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1

    if ($null -eq $battery) {
        Write-Log "WARN  [$Trigger] Nessuna batteria rilevata (desktop o errore driver). Salto ciclo."
        return
    }

    $chargePercent = $battery.EstimatedChargeRemaining
    $batteryStatus = $battery.BatteryStatus
    $statusName    = $BATTERY_STATUS_NAMES[[int]$batteryStatus]
    if (-not $statusName) { $statusName = "Sconosciuto($batteryStatus)" }

    # Lettura dinamica del limite dal registro Samsung (si aggiorna in tempo reale)
    $chargeLimit = Get-BatteryProtectionLimit

    # Lettura modalita' corrente
    $currentMode = Get-CurrentPerformanceMode
    $currentModeName = $MODE_NAMES[[int]$currentMode]
    if (-not $currentModeName) { $currentModeName = "Sconosciuta($currentMode)" }

    # --- Rilevamento alimentazione AC (copertura completa) ---
    $isOnAC = $batteryStatus -in $AC_STATUSES
    $controlMode = $script:trayState.ControlMode
    if (-not $controlMode) {
        $controlMode = 'Auto'
        $script:trayState.ControlMode = 'Auto'
    }
    $manualOverride = $script:trayState.ManualOverrideMode
    if ($null -ne $manualOverride -and $controlMode -ne 'Manual') {
        $controlMode = 'Manual'
        $script:trayState.ControlMode = 'Manual'
    }

    Write-Log "DEBUG [$Trigger] Stato: batteria=$statusName($batteryStatus), carica=$chargePercent%, AC=$isOnAC, limite=$chargeLimit%, modalita=$currentModeName($currentMode), controllo=$controlMode"

    # Aggiorna stato condiviso per la System Tray
    $script:trayState.CurrentMode   = $currentModeName
    $script:trayState.ChargePercent = $chargePercent
    $script:trayState.IsOnAC        = $isOnAC

    # Se l'automatismo e' sospeso dall'utente, nessun cambio automatico
    if ($script:trayState.IsPaused) {
        Write-Log "DEBUG [$Trigger] Automatismo sospeso, salto valutazione."
        return
    }

    # Se l'utente ha forzato manualmente una modalita', rispettarla finche' non arriva un evento hardware
    if ($controlMode -eq 'Manual' -and $null -ne $manualOverride) {
        $overrideName = $MODE_NAMES[$manualOverride]
        if (-not $overrideName) { $overrideName = "$($script:trayState.ManualOverrideMode)" }
        Write-Log "DEBUG [$Trigger] Override manuale attivo ($overrideName), salto valutazione automatica."
        return
    }
    elseif ($controlMode -eq 'Manual' -and $null -eq $manualOverride) {
        $script:trayState.ControlMode = 'Auto'
        $script:trayState.ManualOverrideSource = $null
        $script:trayState.ManualOverrideTimestamp = $null
    }

    # --- Logica decisionale con isteresi ---
    # Attiva "Elevate" quando: AC + carica >= (limite - tolleranza)
    # Torna a "Ottimizzata" quando: non AC, oppure carica < (limite - margine)
    # La tolleranza compensa il fatto che Samsung può fermare la ricarica 1% sotto il limite.
    # L'isteresi evita toggle rapidi quando la carica oscilla di 1-2% intorno al limite.
    if ($isOnAC -and ($chargePercent -ge ($chargeLimit - $chargeTolerance))) {
        if ($currentMode -ne $MODE_HIGH_PERFORMANCE) {
            Invoke-ModeSelection -Mode $MODE_HIGH_PERFORMANCE -Subtitle "$statusName · $chargePercent% — Soglia raggiunta" -PlaySound
            Write-Log "INFO  [$Trigger] Modalita' -> PRESTAZIONI ELEVATE (AC=$isOnAC, carica $chargePercent% >= limite $chargeLimit% - tolleranza $chargeTolerance%)"
        }
        else {
            Write-Log "DEBUG [$Trigger] Nessun cambio: gia' in Prestazioni Elevate"
        }
    }
    elseif ((-not $isOnAC) -or ($chargePercent -lt ($chargeLimit - $hysteresisMargin))) {
        # Non su AC, oppure carica scesa sotto la soglia di isteresi
        if ($currentMode -ne $MODE_OPTIMIZED) {
            $reason = if (-not $isOnAC) { "Scollegato da corrente" } else { "Carica sotto soglia" }
            Invoke-ModeSelection -Mode $MODE_OPTIMIZED -Subtitle "$statusName · $chargePercent% — $reason" -PlaySound
            Write-Log "INFO  [$Trigger] Modalita' -> OTTIMIZZATA (batteria=$statusName, carica $chargePercent%, limite $chargeLimit%, isteresi $hysteresisMargin%)"
        }
        else {
            Write-Log "DEBUG [$Trigger] Nessun cambio: gia' in Ottimizzata"
        }
    }
    else {
        Write-Log "DEBUG [$Trigger] Zona isteresi: carica $chargePercent% in [$($chargeLimit - $hysteresisMargin)%-$chargeLimit%], mantengo $currentModeName"
    }
}

# ============================================================================
# Rilevamento cambio alimentazione
# ============================================================================
# PROBLEMA: Sia Register-ObjectEvent/Register-CimIndicationEvent (coda PS)
# che .add_EventXxx() con scriptblock (delegate PS) causano deadlock quando
# il main thread è bloccato su WaitOne(): i callback PowerShell tentano di
# entrare nel runspace occupato → deadlock completo (nemmeno il timeout scatta).
#
# SOLUZIONE: compilare una classe C# che gestisce i callback interamente in
# .NET puro. I lambda C# compilati eseguono sul thread nativo del watcher
# senza mai toccare il runspace PowerShell → Set() funziona istantaneamente.
#
# Watcher principale: EventLog "Microsoft-Windows-Kernel-Power" EventID 105
#   → emesso dal kernel subito al cambio AC ↔ batteria.
#   Verificato presente su questo Galaxy Book.
#
# Watcher backup: WMI ManagementEventWatcher su Win32_PowerManagementEvent
#
# Fallback: polling ogni $pollInterval secondi per variazioni graduali.
# ============================================================================
$wakeSignal = [System.Threading.AutoResetEvent]::new($false)
$script:trayState.WakeSignal = $wakeSignal   # condiviso con la tray per segnalare immediatamente
$eventLogWatcher = $null
$wmiWatcher = $null

# --- Flag di shutdown per garantire il cleanup ---
$script:shutdownRequested = $false

# Handler per ProcessExit (shutdown/logoff/chiusura del task)
# In .NET, AppDomain.ProcessExit viene invocato anche durante lo shutdown del sistema.
$null = Register-ObjectEvent -InputObject ([AppDomain]::CurrentDomain) -EventName 'ProcessExit' -Action {
    $script:shutdownRequested = $true
    try {
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Samsung\SamsungSettings\ModulePerformance' -Name 'Value' -Value 2 -ErrorAction Stop
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        "$ts  INFO  [shutdown] Modalita' reimpostata a OTTIMIZZATA prima della chiusura." |
            Out-File -FilePath (Join-Path $PSScriptRoot 'PerformanceManagerGB.log') -Append -Encoding utf8
    } catch { }
}

# --- Compilazione helper C# per callback nativi ---
# In .NET 5+/PS7, Add-Type con Roslyn non riesce a risolvere AutoResetEvent
# a causa del multi-hop type forwarding (System.Threading → System.Private.CoreLib).
# Soluzione: usare P/Invoke kernel32!SetEvent sull'handle nativo.
Add-Type -AssemblyName System.Management -ErrorAction Stop

$runtimeDir = [System.IO.Path]::GetDirectoryName([object].Assembly.Location)

# Seleziona i riferimenti in base al runtime (.NET Framework vs .NET 5+)
if ($PSVersionTable.PSVersion.Major -ge 7) {
    # PS7+ / .NET 5+ / Roslyn: path assoluti obbligatori
    $interopDll = Join-Path $runtimeDir 'System.Runtime.InteropServices.dll'
    if (-not (Test-Path $interopDll)) {
        # Fallback: localizza l'assembly tramite il tipo già caricato
        $interopDll = [System.Runtime.InteropServices.Marshal].Assembly.Location
    }
    $addTypeRefs = @(
        $interopDll,
        [System.Diagnostics.Eventing.Reader.EventLogWatcher].Assembly.Location,
        [System.Management.ManagementEventWatcher].Assembly.Location
    )
} else {
    # PS 5.1 / .NET Framework / CodeDOM: nomi brevi GAC
    # System.Runtime.InteropServices è in mscorlib → NON includerlo esplicitamente
    $addTypeRefs = @(
        'System.Core',       # EventLogWatcher (System.Diagnostics.Eventing.Reader)
        'System.Management'  # ManagementEventWatcher
    )
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics.Eventing.Reader;
using System.Management;

public class PowerWakeHandler
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetEvent(IntPtr hEvent);

    private readonly IntPtr _handle;

    public PowerWakeHandler(IntPtr eventHandle)
    {
        _handle = eventHandle;
    }

    public void SubscribeEventLog(EventLogWatcher watcher)
    {
        watcher.EventRecordWritten += (s, e) => SetEvent(_handle);
    }

    public void SubscribeWmi(ManagementEventWatcher watcher)
    {
        watcher.EventArrived += (s, e) => SetEvent(_handle);
    }
}
'@ -ReferencedAssemblies $addTypeRefs -ErrorAction Stop

$wakeHandler = [PowerWakeHandler]::new($wakeSignal.SafeWaitHandle.DangerousGetHandle())

# --- Watcher principale: Event Log Kernel-Power EventID 105 ---
try {
    $xpathQuery = "*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=105)]]"
    $evtQuery = [System.Diagnostics.Eventing.Reader.EventLogQuery]::new(
        "System",
        [System.Diagnostics.Eventing.Reader.PathType]::LogName,
        $xpathQuery
    )
    $eventLogWatcher = [System.Diagnostics.Eventing.Reader.EventLogWatcher]::new($evtQuery)
    $wakeHandler.SubscribeEventLog($eventLogWatcher)
    $eventLogWatcher.Enabled = $true
    Write-Log "INFO  Watcher EventLog Kernel-Power/105 registrato (C# nativo). Rilevamento AC istantaneo."
}
catch {
    Write-Log "WARN  Impossibile registrare watcher EventLog Kernel-Power: $_"
}

# --- Watcher backup: WMI ManagementEventWatcher (C# nativo) ---
try {
    $wmiWatcher = [System.Management.ManagementEventWatcher]::new(
        "SELECT * FROM Win32_PowerManagementEvent"
    )
    $wakeHandler.SubscribeWmi($wmiWatcher)
    $wmiWatcher.Start()
    Write-Log "INFO  Watcher WMI PowerManagementEvent registrato (C# nativo, backup)."
}
catch {
    Write-Log "WARN  Impossibile registrare watcher WMI: $_"
}

$watcherCount = (@($eventLogWatcher, $wmiWatcher) | Where-Object { $_ }).Count
if ($watcherCount -eq 0) {
    Write-Log "WARN  Nessun watcher attivo. Solo polling ogni $pollInterval secondi."
}

# ============================================================================
# Loop principale (event-driven con fallback polling)
# ============================================================================
Write-Log "Script avviato (PID $PID). Polling ogni $pollInterval secondi, $watcherCount watcher C# attivi."
$script:loopCount = 0

# --- Avvio System Tray Icon ---
try {
    Start-TrayIcon
    Write-Log "INFO  System Tray icon avviata."
}
catch {
    Write-Log "WARN  Impossibile avviare System Tray icon: $_"
}

# Safe-default: all'avvio imposta sempre Ottimizzata prima di valutare le condizioni.
# Cosi' anche se il precedente shutdown non ha fatto cleanup, si riparte da Ottimizzata.
try {
    $currentModeAtStart = [int](Get-ItemProperty -Path $regPerformance -ErrorAction Stop).Value
    if ($currentModeAtStart -ne $MODE_OPTIMIZED) {
        Set-PerformanceMode -Mode $MODE_OPTIMIZED
        $prevModeName = if ($null -ne $MODE_NAMES[$currentModeAtStart]) { $MODE_NAMES[$currentModeAtStart] } else { "$currentModeAtStart" }
        Write-Log "INFO  [avvio] Safe-default: reimpostata OTTIMIZZATA (era $prevModeName)."
    }
} catch {
    Write-Log "WARN  [avvio] Impossibile impostare safe-default: $_"
}

# Prima esecuzione immediata: valuta le condizioni e cambia se necessario
$modeBeforeStartup = Get-CurrentPerformanceMode
try {
    Update-PerformanceMode -Trigger 'avvio'
}
catch {
    Write-Log "ERROR [avvio] Eccezione in Update-PerformanceMode: $_"
}

# Notifica di avvio (solo se Update-PerformanceMode non ha già mostrato un OSD)
try {
    $modeAfterStartup = Get-CurrentPerformanceMode
    if ($modeBeforeStartup -eq $modeAfterStartup) {
        $startupModeName = $MODE_NAMES[$modeAfterStartup]
        if (-not $startupModeName) { $startupModeName = 'Attiva' }
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        $startupSub = "Gestore avviato"
        if ($bat) { $startupSub += " — $($bat.EstimatedChargeRemaining)%" }
        $startupVisual = $MODE_VISUALS[$modeAfterStartup]
        if (-not $startupVisual) {
            $startupVisual = @{
                Glyph = [char]0xE946
                Color = "#60CDFF"
            }
        }
        $startupGlyph = $startupVisual.Glyph
        $startupColor = $startupVisual.Color
        Show-ModeNotification -ModeName $startupModeName -IconGlyph $startupGlyph -AccentColor $startupColor -Subtitle $startupSub
    }
} catch {
    Write-Log "WARN  [avvio] Impossibile mostrare notifica di avvio: $_"
}

while ($true) {
    $script:loopCount++

    # Attende: si sblocca immediatamente se un watcher C# chiama Set(),
    # oppure dopo $pollInterval secondi (fallback per variazioni di carica graduale)
    $waitStart = Get-Date
    $eventFired = $wakeSignal.WaitOne($pollInterval * 1000)
    $waitMs = [int]((Get-Date) - $waitStart).TotalMilliseconds

    if ($eventFired) {
        # Drena tutti i segnali accumulati nella coda per evitare loop a 0ms
        $drainCount = 1
        while ($wakeSignal.WaitOne(0)) { $drainCount++ }

        Write-Log "DEBUG Evento ricevuto dopo ${waitMs}ms (ciclo #$($script:loopCount), $drainCount segnale/i drenati)."
        $trigger = 'evento'
    }
    else {
        $trigger = 'polling'
    }

    # --- Controllo comandi dalla System Tray ---
    if ($script:trayState.RequestExit) {
        Write-Log "INFO  Richiesta di uscita dalla System Tray."
        break
    }

    $justForced = $false
    $resumeRequested = $false
    $modeBeforeResume = $null
    if ($script:trayState.ResumeAutomaticRequested) {
        $script:trayState.ResumeAutomaticRequested = $false
        $resumeRequested = $true
        $modeBeforeResume = Get-CurrentPerformanceMode
        $script:trayState.RequestedMode = $null
        $script:trayState.RequestedModeSource = $null
        if ($script:trayState.ControlMode -ne 'Auto' -or $null -ne $script:trayState.ManualOverrideMode) {
            Write-Log "INFO  [tray] Ripristino gestione automatica richiesto dall'utente."
        }
        else {
            Write-Log "DEBUG [tray] Ripristino gestione automatica richiesto, gia' in automatico."
        }
        $script:trayState.ControlMode = 'Auto'
        $script:trayState.ManualOverrideMode = $null
        $script:trayState.ManualOverrideSource = $null
        $script:trayState.ManualOverrideTimestamp = $null
        $trigger = 'resume'
    }

    $requestedMode = $null
    $requestedModeSource = $null
    if (-not $resumeRequested) {
        # TODO: quando verranno introdotte le hotkey, valorizzare RequestedMode/RequestedModeSource e WakeSignal.
        $requestedMode = $script:trayState.RequestedMode
        $requestedModeSource = $script:trayState.RequestedModeSource
    }

    if ($null -ne $requestedMode) {
        $script:trayState.RequestedMode = $null
        $script:trayState.RequestedModeSource = $null
        $reqModeName = $MODE_NAMES[$requestedMode]
        if ($reqModeName) {
            $overrideSource = if ($requestedModeSource) { $requestedModeSource } else { 'Tray' }
            try {
                Invoke-ModeSelection -Mode $requestedMode -Subtitle "Impostata manualmente" -PlaySound
                $script:trayState.CurrentMode = $reqModeName
                $script:trayState.ControlMode = 'Manual'
                $script:trayState.ManualOverrideMode = $requestedMode
                $script:trayState.ManualOverrideSource = $overrideSource
                $script:trayState.ManualOverrideTimestamp = Get-Date
                $justForced = $true
                Write-Log "INFO  [tray] Modalita' forzata a $reqModeName dall'utente (sorgente=$overrideSource)."
            }
            catch {
                Write-Log "ERROR [tray] Impossibile forzare modalita': $_"
            }
        }
    }

    # Se arriva un evento hardware genuino (AC plug/unplug), cancella l'override manuale.
    # $justForced protegge dalla race condition: se l'utente ha appena forzato nello stesso ciclo,
    # l'override non viene azzerato immediatamente.
    if ($trigger -eq 'evento' -and -not $justForced -and $null -ne $script:trayState.ManualOverrideMode) {
        $overrideName = $MODE_NAMES[$script:trayState.ManualOverrideMode]
        if (-not $overrideName) { $overrideName = "$($script:trayState.ManualOverrideMode)" }
        Write-Log "INFO  [evento] Override manuale ($overrideName) rimosso: ripresa gestione automatica."
        $script:trayState.ControlMode = 'Auto'
        $script:trayState.ManualOverrideMode = $null
        $script:trayState.ManualOverrideSource = $null
        $script:trayState.ManualOverrideTimestamp = $null
    }

    try {
        Update-PerformanceMode -Trigger $trigger
    }
    catch {
        Write-Log "ERROR [$trigger] Eccezione in Update-PerformanceMode: $_"
    }

    if ($resumeRequested) {
        try {
            $modeAfterResume = Get-CurrentPerformanceMode
            if ($modeBeforeResume -eq $modeAfterResume) {
                $resumeVisual = $MODE_VISUALS[$modeAfterResume]
                if (-not $resumeVisual) {
                    $resumeVisual = @{
                        Glyph = [char]0xE946
                        Color = "#60CDFF"
                    }
                }
                Show-ModeNotification -ModeName "Automatico" -IconGlyph $resumeVisual.Glyph -AccentColor $resumeVisual.Color -Subtitle "Gestione automatica ripristinata"
                Play-NotificationSound
            }
        }
        catch {
            Write-Log "WARN  [resume] Impossibile mostrare notifica di ripristino automatico: $_"
        }
    }
}

}  # fine try esterno (mutex)
catch {
    # Log errore fatale non catturato (es. compilazione C# fallita, eccezione critica)
    try { Write-Log "FATAL Eccezione non gestita: $_" } catch { }
}
finally {
    # Rilascio di tutte le risorse in ogni caso (chiusura, Ctrl+C, errore fatale)
    try { Stop-TrayIcon } catch { }
    try {
        if ($script:_notifPS) {
            try { $script:_notifPS.Stop() } catch { }
            try { $script:_notifPS.Dispose() } catch { }
            $script:_notifPS = $null
        }
        if ($script:_notifRS) {
            try { $script:_notifRS.Close() } catch { }
            try { $script:_notifRS.Dispose() } catch { }
            $script:_notifRS = $null
        }
    } catch { }
    try {
        if ($eventLogWatcher) {
            $eventLogWatcher.Enabled = $false
            $eventLogWatcher.Dispose()
        }
        if ($wmiWatcher) {
            $wmiWatcher.Stop()
            $wmiWatcher.Dispose()
        }
    } catch { }

    # Reimposta la modalità a Ottimizzata (se non già fatto dall'handler ProcessExit)
    if (-not $script:shutdownRequested) {
        try {
            Set-PerformanceMode -Mode $MODE_OPTIMIZED
            Write-Log "INFO  Modalita' reimpostata a OTTIMIZZATA alla chiusura."
        } catch {
            Write-Log "WARN  Impossibile reimpostare la modalita' alla chiusura: $_"
        }
    }

    $wakeSignal.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Write-Log "Script terminato. Risorse rilasciate."
}