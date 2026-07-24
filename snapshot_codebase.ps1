$outputFile = "vrdx_daemon_snapshot.txt"
$excludeFolders = @("lib", ".git", "backup")

"--- PROJECT STRUCTURE ---" | Set-Content -Path $outputFile -Encoding utf8
Get-ChildItem -Recurse | Where-Object { $excludeFolders -notcontains $_.Parent.Name } | 
    Select-Object @{Name="Path"; Expression={$_.FullName.Replace((Get-Location).Path, ".")}} | 
    Add-Content -Path $outputFile -Encoding utf8

if (Test-Path "daemon") {
    Get-ChildItem -Path "daemon" -Recurse -File | Where-Object { $_.Extension -match "md|pas|lpr" } | ForEach-Object {
        $relativeName = $_.FullName.Replace((Get-Location).Path, ".")
        "`n--- FILE: $relativeName ---" | Add-Content -Path $outputFile -Encoding utf8
        Get-Content $_.FullName | Add-Content -Path $outputFile -Encoding utf8
    }
}

Write-Host "Snapshot complete: $outputFile" -ForegroundColor Green