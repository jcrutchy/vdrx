$outputFile = "vdrx_daemon_snapshot.txt"
$excludeFolders = @("lib", ".git", "backup", ".vs", "data", "stress_test")

"--- PROJECT STRUCTURE ---" | Set-Content -Path $outputFile -Encoding utf8
Get-ChildItem -Recurse | Where-Object { 
    $pathParts = $_.FullName.Replace((Get-Location).Path + "\", "").Split("\")
    $skip = $false
    foreach ($part in $pathParts) {
        if ($excludeFolders -contains $part) { $skip = $true; break }
    }
    -not $skip
} | Select-Object @{Name="Path"; Expression={$_.FullName.Replace((Get-Location).Path, ".")}} | 
    Add-Content -Path $outputFile -Encoding utf8

# Capture files from the root and valid subdirectories, excluding folders
Get-ChildItem -Recurse -File | Where-Object { 
    $file = $_
    $isInExcluded = $false
    foreach ($exc in $excludeFolders) {
        if ($file.FullName -like "*\$exc\*") { $isInExcluded = $true }
    }
    (-not $isInExcluded) -and ($_.Extension -match "\.(pas|lpr)$")
} | ForEach-Object {
    $relativeName = $_.FullName.Replace((Get-Location).Path, ".")
    "`n--- FILE: $relativeName ---" | Add-Content -Path $outputFile -Encoding utf8
    Get-Content $_.FullName | Add-Content -Path $outputFile -Encoding utf8
}

Write-Host "Snapshot complete: $outputFile" -ForegroundColor Green