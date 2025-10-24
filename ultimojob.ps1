# CONFIGURAZIONE
$thresholdHours = 1
$csvPath = "C:\Temp\Veeam_All_Jobs_Report.csv"
$htmlPath = "C:\Temp\Veeam_Alert_Report.html"
$txtPath  = "C:\Temp\Veeam_Alert_Report.txt"

# Parametri per invio email (solo predisposizione)
$enableEmail = $true  # Cambia a $false se non vuoi mandare email
$emailSubject = "🚨 Nessun backup riuscito nelle ultime $thresholdHours ore"
$emailTo = "admin@tuodominio.com"
$emailFrom = "backup-alert@tuodominio.com"
$smtpServer = "smtp.tuodominio.com"
$smtpPort = 587
$emailUser = "smtpuser@tuodominio.com"
$emailPassword = "smtp-password"

# Inizializzazione
New-Item -ItemType Directory -Path (Split-Path $csvPath) -Force | Out-Null
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

# Variabili
$jobs = Get-VBRJob | Where-Object { $_.JobType -eq "Backup" }
$alertJobs = @()
$allJobInfo = @()
$recentBackups = $false  # Per controllo globale

foreach ($job in $jobs) {
    $lastSession = $job.FindLastSession()
    if ($lastSession) {
        $lastRun = $lastSession.EndTime
        $result = $lastSession.Result
        $hoursAgo = (New-TimeSpan -Start $lastRun -End (Get-Date)).TotalHours
        $roundedHours = [math]::Round($hoursAgo, 2)

        # Stampa dettagli job
        Write-Host "Job: $($job.Name) | Ultima esecuzione: $lastRun | Risultato: $result | $roundedHours ore fa"

        # Aggiunge a tutti i job (CSV)
        $allJobInfo += [PSCustomObject]@{
            JobName     = $job.Name
            LastSuccess = $lastRun
            Result      = $result
            HoursAgo    = $roundedHours
        }

        # Verifica se è considerato "vecchio"
        if ($result -eq "Success" -and $hoursAgo -gt $thresholdHours) {
            $alertJobs += [PSCustomObject]@{
                JobName     = $job.Name
                LastSuccess = $lastRun
                HoursAgo    = $roundedHours
            }
        }

        # Almeno un backup entro la soglia
        if ($result -eq "Success" -and $hoursAgo -le $thresholdHours) {
            $recentBackups = $true
        }
    } else {
        Write-Host "Job: $($job.Name) | Nessuna esecuzione trovata." -ForegroundColor Yellow

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

# CSV completo
$allJobInfo | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`n📄 CSV generato: $csvPath" -ForegroundColor Green

# HTML e TXT per job "in ritardo"
if ($alertJobs.Count -gt 0) {
    $htmlHeader = "<h2>Job Veeam in Ritardo</h2><p>Generato: $(Get-Date)</p><table border='1' cellpadding='5' cellspacing='0'><tr><th>Job Name</th><th>Ultima Esecuzione</th><th>Ore Trascorse</th></tr>"
    $htmlBody = ""
    foreach ($j in $alertJobs) {
        $htmlBody += "<tr><td>$($j.JobName)</td><td>$($j.LastSuccess)</td><td>$($j.HoursAgo)</td></tr>"
    }
    $htmlFooter = "</table>"
    "$htmlHeader$htmlBody$htmlFooter" | Out-File -Encoding UTF8 -FilePath $htmlPath
    Write-Host "📄 HTML generato: $htmlPath" -ForegroundColor Green

    $txtReport = "=== JOB VEEAM IN RITARDO (soglia: $thresholdHours ore) ===`nGenerato: $(Get-Date)`n"
    foreach ($j in $alertJobs) {
        $txtReport += "`n➡️ Job: $($j.JobName)`n    Ultima esecuzione: $($j.LastSuccess)`n    Ore fa: $($j.HoursAgo)`n"
    }
    $txtReport | Out-File -Encoding UTF8 -FilePath $txtPath
    Write-Host "📄 TXT generato: $txtPath" -ForegroundColor Green
}

# MESSAGGIO A VIDEO
if ($recentBackups) {
    Write-Host "`n✅ Almeno un backup eseguito con successo nelle ultime $thresholdHours ore." -ForegroundColor Green
} else {
    Write-Host "`n❌ Nessun backup riuscito nelle ultime $thresholdHours ore!" -ForegroundColor Red

    # Predisposizione per invio email solo se abilitato
    if ($enableEmail -and (Test-Path $htmlPath)) {
        $securePass = ConvertTo-SecureString $emailPassword -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($emailUser, $securePass)

        Send-MailMessage -From $emailFrom -To $emailTo -Subject $emailSubject `
            -Body "Nessun job di backup ha avuto successo nelle ultime $thresholdHours ore. In allegato il report." `
            -Attachments $htmlPath -SmtpServer $smtpServer -Port $smtpPort -UseSsl -Credential $cred

        Write-Host "📧 Email inviata a $emailTo con il report HTML." -ForegroundColor Cyan
    }
}
