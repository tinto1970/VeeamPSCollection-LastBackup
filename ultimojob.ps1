
# === CONFIGURAZIONE ===
$thresholdHours = 24              # soglia per backup normali
$thresholdHoursLogs = 12          # soglia per backup log SQL

$csvPath = "C:\Temp\Veeam_All_Jobs_Report.csv"
$htmlPath = "C:\Temp\Veeam_Alert_Report.html"
$txtPath  = "C:\Temp\Veeam_Alert_Report.txt"

# === Email (opzionale) ===
$enableEmail = $true
$emailSubject = "🚨 Alert backup: uno o più job non hanno avuto esecuzione entro soglia"
$emailTo = "admin@tuodominio.com"
$emailFrom = "backup-alert@tuodominio.com"
$smtpServer = "smtp.tuodominio.com"
$smtpPort = 587
$emailUser = "smtpuser@tuodominio.com"
$emailPassword = "smtp-password"

# === PREPARAZIONE ===
New-Item -ItemType Directory -Path (Split-Path $csvPath) -Force | Out-Null
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

# === FLAG ===
$recentBackupNormal = $false
$recentBackupLogs   = $false

# === JOB NORMALI ===
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

# === BACKUP LOG SQL ===
$sqlLogSessions = Get-VBRSession -Type SqlLogBackup
$sqlLogAlertList = @()
$sqlLogTargetLatest = @{}

if ($sqlLogSessions.Count -gt 0) {
    foreach ($session in $sqlLogSessions) {
        if ($session.Result -eq "Success" -and $session.EndTime -gt [datetime]"2000-01-01") {
            $tasks = Get-VBRTaskSession -Session $session
            foreach ($task in $tasks) {
                $targetName = $task.Name
                $taskEnd = $task.EndTime
                $taskStatus = $task.Status.ToString()

                if (-not $sqlLogTargetLatest.ContainsKey($targetName) -or $taskEnd -gt $sqlLogTargetLatest[$targetName].Time) {
                    $sqlLogTargetLatest[$targetName] = @{
                        Time = $taskEnd
                        Status = $taskStatus
                    }
                }
            }
        }
    }

    foreach ($entry in $sqlLogTargetLatest.GetEnumerator()) {
        $name = $entry.Key
        $logData = $entry.Value
        $lastLogTime = $logData.Time
        $status = $logData.Status

        if ($lastLogTime -ne $null -and $lastLogTime -gt [datetime]"2000-01-01") {
            $hoursAgo = (New-TimeSpan -Start $lastLogTime -End (Get-Date)).TotalHours
            $roundedHours = [math]::Round($hoursAgo, 2)

            Write-Host "SQL Log Backup: $name | Ultimo log salvato: $lastLogTime | Stato: $status | $roundedHours ore fa"

            if ($roundedHours -le $thresholdHoursLogs -and $status -eq "Success") {
                $recentBackupLogs = $true
            } else {
                $sqlLogAlertList += [PSCustomObject]@{
                    Target      = $name
                    LastLogTime = $lastLogTime
                    HoursAgo    = $roundedHours
                    Status      = $status
                }
            }
        } else {
            Write-Host "⚠️ Log SQL non valido per: $name (nessuna data disponibile)" -ForegroundColor Yellow

            $sqlLogAlertList += [PSCustomObject]@{
                Target      = $name
                LastLogTime = "Non disponibile"
                HoursAgo    = "N/A"
                Status      = "N/A"
            }
        }
    }
} else {
    Write-Host "⚠️ Nessun backup dei log SQL trovato." -ForegroundColor Yellow
    $sqlLogAlertList += [PSCustomObject]@{
        Target      = "Tutti i log SQL"
        LastLogTime = "Nessuna sessione"
        HoursAgo    = "N/A"
        Status      = "N/A"
    }
}

# === EXPORT CSV ===
$allJobInfo | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`n📄 CSV generato: $csvPath" -ForegroundColor Green

# === REPORT HTML / TXT ===
$htmlHeader = "<h2>Job Veeam in Ritardo</h2><p>Generato: $(Get-Date)</p>"
$htmlBody = ""

if ($alertJobs.Count -gt 0) {
    $htmlBody += "<h3>Backup Job Normali</h3><table border='1' cellpadding='5' cellspacing='0'>
    <tr style='background-color:#f2f2f2;'><th>Job Name</th><th>Ultima Esecuzione</th><th>Ore Trascorse</th></tr>"
    foreach ($j in $alertJobs) {
        $htmlBody += "<tr style='color:red;'><td>$($j.JobName)</td><td>$($j.LastSuccess)</td><td>$($j.HoursAgo)</td></tr>"
    }
    $htmlBody += "</table>"
}

if ($sqlLogAlertList.Count -gt 0) {
    $htmlBody += "<br><h3>Log SQL in Ritardo</h3><table border='1' cellpadding='5' cellspacing='0'>
    <tr style='background-color:#f2f2f2;'><th>Target</th><th>Ultimo Backup Log</th><th>Ore Trascorse</th><th>Stato</th></tr>"
    foreach ($log in $sqlLogAlertList) {
        $isCritical = ($log.LastLogTime -eq "Non disponibile" -or ($log.HoursAgo -ne "N/A" -and [double]$log.HoursAgo -gt $thresholdHoursLogs) -or $log.Status -ne "Success")
        $rowStyle = ""
        if ($isCritical) {
            $rowStyle = "style='color:red;'"
        }
        $htmlBody += "<tr $rowStyle><td>$($log.Target)</td><td>$($log.LastLogTime)</td><td>$($log.HoursAgo)</td><td>$($log.Status)</td></tr>"
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
        $txtReport += "`n➡️ SQL Log: $($log.Target)`n    Ultimo log: $($log.LastLogTime)`n    Ore fa: $($log.HoursAgo)`n    Stato: $($log.Status)`n"
    }

    $txtReport | Out-File -Encoding UTF8 -FilePath $txtPath
    Write-Host "📄 TXT generato: $txtPath" -ForegroundColor Green
}

# === STAMPA A VIDEO E INVIO EMAIL ===
if ($recentBackupNormal -and $recentBackupLogs) {
    Write-Host "`n✅ OK: backup normali e log SQL eseguiti entro soglia." -ForegroundColor Green
} else {
    Write-Host "`n❌ ALERT: almeno un tipo di backup NON è stato eseguito entro soglia!" -ForegroundColor Red

    if ($enableEmail -and (Test-Path $htmlPath)) {
        try {
            $securePass = ConvertTo-SecureString $emailPassword -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential ($emailUser, $securePass)

            Send-MailMessage -From $emailFrom -To $emailTo -Subject $emailSubject `
                -Body "Attenzione: almeno un tipo di backup (normale o SQL log) non è stato eseguito entro soglia. In allegato il report." `
                -Attachments $htmlPath -SmtpServer $smtpServer -Port $smtpPort -UseSsl -Credential $cred

            Write-Host "📧 Email inviata a $emailTo con report allegato." -ForegroundColor Cyan
        } catch {
            Write-Host "⚠️ Errore nell'invio email: $_" -ForegroundColor Red
        }
    }
}
