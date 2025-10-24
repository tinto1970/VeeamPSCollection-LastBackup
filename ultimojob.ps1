# === CONFIGURAZIONE ===
$thresholdHours = 3              # soglia per backup normali
$thresholdHoursLogs = 2          # soglia per backup log SQL

$csvPath = "C:\Temp\Veeam_All_Jobs_Report.csv"
$htmlPath = "C:\Temp\Veeam_Alert_Report.html"
$txtPath  = "C:\Temp\Veeam_Alert_Report.txt"

# === Email (opzionale) ===
$enableEmail = $true
$emailSubject = "🚨 Alert backup: uno o più tipi di job non hanno avuto esecuzione entro soglia"
$emailTo = "admin@tuodominio.com"
$emailFrom = "backup-alert@tuodominio.com"
$smtpServer = "smtp.tuodominio.com"
$smtpPort = 587
$emailUser = "smtpuser@tuodominio.com"
$emailPassword = "smtp-password"

# === PREPARAZIONE ===
New-Item -ItemType Directory -Path (Split-Path $csvPath) -Force | Out-Null
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

# === Inizializza flag ===
$recentBackupNormal = $false
$recentBackupLogs   = $false

# === RACCOLTA JOB NORMALI ===
$jobs = Get-VBRJob | Where-Object { $_.JobType -eq "Backup" }
$allSessions = Get-VBRBackupSession
$allJobInfo = @()
$alertJobs = @()

foreach ($job in $jobs) {
    $lastSession = $allSessions |
        Where-Object { $_.JobName -eq $job.Name -and $_.Result -ne $null } |
        Sort-Object EndTime -Descending |
        Select-Object -First 1

    if ($lastSession) {
        $lastRun = $lastSession.EndTime
        $result = $lastSession.Result
        $hoursAgo = (New-TimeSpan -Start $lastRun -End (Get-Date)).TotalHours
        $roundedHours = [math]::Round($hoursAgo, 2)

        Write-Host "Job: $($job.Name) | Ultima esecuzione: $lastRun | Risultato: $result | $roundedHours ore fa"

        $allJobInfo += [PSCustomObject]@{
            JobName     = $job.Name
            LastSuccess = $lastRun
            Result      = $result
            HoursAgo    = $roundedHours
        }

        if ($result -eq "Success" -and $hoursAgo -le $thresholdHours) {
            $recentBackupNormal = $true
        } elseif ($result -eq "Success" -and $hoursAgo -gt $thresholdHours) {
            $alertJobs += [PSCustomObject]@{
                JobName     = $job.Name
                LastSuccess = $lastRun
                HoursAgo    = $roundedHours
            }
        }
    } else {
        Write-Host "Job: $($job.Name) | Nessuna sessione trovata." -ForegroundColor Yellow

        $allJobInfo += [PSCustomObject]@{
            JobName     = $job.Name
            LastSuccess = "Mai eseguito"
            Result      = "Nessuno"
            HoursAgo    = "N/A"
        }

        $alertJobs += [PSCustomObject]@{
            JobName     = $job.Name
            LastSuccess = "Mai eseguito"
            HoursAgo    = "N/A"
        }
    }
}

# === SEZIONE AGGIUNTIVA: SQL LOG BACKUP ===
$sqlLogSessions = Get-VBRSession -Type SqlLogBackup
$sqlLogAlertList = @()

if ($sqlLogSessions.Count -gt 0) {
    $groupedByVm = $sqlLogSessions |
        Where-Object { $_.Result -eq "Success" -and $_.EndTime -gt [datetime]"2000-01-01" } |
        Sort-Object EndTime -Descending |
        Group-Object {$_.Name}

    foreach ($group in $groupedByVm) {
        $lastLogSession = $group.Group | Sort-Object EndTime -Descending | Select-Object -First 1
        $lastLogRun = $lastLogSession.EndTime
        $hoursAgo = (New-TimeSpan -Start $lastLogRun -End (Get-Date)).TotalHours
        $roundedHours = [math]::Round($hoursAgo, 2)

        Write-Host "SQL Log Backup: $($group.Name) | Ultima esecuzione: $lastLogRun | $roundedHours ore fa"

        if ($hoursAgo -le $thresholdHoursLogs) {
            $recentBackupLogs = $true
        } else {
            $sqlLogAlertList += [PSCustomObject]@{
                Target      = $group.Name
                LastLogTime = $lastLogRun
                HoursAgo    = $roundedHours
            }
        }
    }
} else {
    Write-Host "⚠️ Nessun backup dei log SQL trovato." -ForegroundColor Yellow
    # Qui potresti considerare che è un alert se vuoi
    $sqlLogAlertList += [PSCustomObject]@{
        Target      = "Tutti i log SQL"
        LastLogTime = "Nessuna sessione"
        HoursAgo    = "N/A"
    }
}

# === ESPORTA FILE ===
$allJobInfo | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`n📄 CSV generato: $csvPath" -ForegroundColor Green

# === REPORT HTML/TXT ===
$htmlHeader = "<h2>Job Veeam in Ritardo</h2><p>Generato: $(Get-Date)</p>"
$htmlBody = ""

if ($alertJobs.Count -gt 0) {
    $htmlBody += "<h3>Backup Job Normali</h3><table border='1' cellpadding='5' cellspacing='0'><tr><th>Job Name</th><th>Ultima Esecuzione</th><th>Ore Trascorse</th></tr>"
    foreach ($j in $alertJobs) {
        $htmlBody += "<tr><td>$($j.JobName)</td><td>$($j.LastSuccess)</td><td>$($j.HoursAgo)</td></tr>"
    }
    $htmlBody += "</table>"
}

if ($sqlLogAlertList.Count -gt 0) {
    $htmlBody += "<br><h3>Log SQL in Ritardo</h3><table border='1' cellpadding='5' cellspacing='0'><tr><th>Target</th><th>Ultimo Backup Log</th><th>Ore Trascorse</th></tr>"
    foreach ($log in $sqlLogAlertList) {
        $htmlBody += "<tr><td>$($log.Target)</td><td>$($log.LastLogTime)</td><td>$($log.HoursAgo)</td></tr>"
    }
    $htmlBody += "</table>"
}

if ($htmlBody -ne "") {
    "$htmlHeader$htmlBody" | Out-File -Encoding UTF8 -FilePath $htmlPath
    Write-Host "📄 HTML generato: $htmlPath" -ForegroundColor Green

    $txtReport = "=== ALERT BACKUP ===`nGenerato: $(Get-Date)`n"

    foreach ($j in $alertJobs) {
        $txtReport += "`n➡️ Job: $($j.JobName)`n    Ultima esecuzione: $($j.LastSuccess)`n    Ore fa: $($j.HoursAgo)`n"
    }
    foreach ($log in $sqlLogAlertList) {
        $txtReport += "`n➡️ SQL Log: $($log.Target)`n    Ultimo log: $($log.LastLogTime)`n    Ore fa: $($log.HoursAgo)`n"
    }

    $txtReport | Out-File -Encoding UTF8 -FilePath $txtPath
    Write-Host "📄 TXT generato: $txtPath" -ForegroundColor Green
}

# === STAMPA FINALE E INVIO EMAIL SE NECESSARIO ===
if ($recentBackupNormal -and $recentBackupLogs) {
    Write-Host "`n✅ OK: backup normali E log SQL eseguiti entro soglia." -ForegroundColor Green
} else {
    Write-Host "`n❌ ALERT: uno o entrambi i tipi di job NON hanno avuto backup entro le soglie ($thresholdHours h normali / $thresholdHoursLogs h log SQL)!" -ForegroundColor Red

    if ($enableEmail -and (Test-Path $htmlPath)) {
        try {
            $securePass = ConvertTo-SecureString $emailPassword -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential ($emailUser, $securePass)

            Send-MailMessage -From $emailFrom -To $emailTo -Subject $emailSubject `
                -Body "Attenzione: uno o più tipi di job non hanno avuto backup recenti. In allegato il report." `
                -Attachments $htmlPath -SmtpServer $smtpServer -Port $smtpPort -UseSsl -Credential $cred

            Write-Host "📧 Email inviata a $emailTo con report allegato." -ForegroundColor Cyan
        } catch {
            Write-Host "⚠️ Errore nell'invio email: $_" -ForegroundColor Red
        }
    }
}
