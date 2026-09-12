$writer.Flush()
$writer.Close()

Write-Line ""
Write-Ok "ГОТОВО за $(Format-Time $globalSw.Elapsed.TotalSeconds)!"
Write-Line "Отчёт: $outFile  ($sizeNow МБ)"

if ($reportAborted) {
    Write-Warn2 "Отчёт обрезан. Увеличь: -MaxReportSizeMB 1000"
}

try {
    if ($sizeNow -gt 100) {
        Write-Warn2 "Отчёт большой ($sizeNow МБ). Открываю через notepad.exe..."
        Start-Process "notepad.exe" -ArgumentList "`"$outFile`""
    } else {
        Start-Process $outFile
        Write-Ok "Отчёт открыт."
    }
} catch {
    Write-Err "Не удалось открыть: $($_.Exception.Message)"
    Write-Line "Открой вручную: $outFile"
}

$ans = Read-Host "Удалить временные файлы? (y/N)"
if ($ans -match '^[YyДд]$') {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Удалено."
}

Write-Line ""
Read-Host "Нажмите Enter для выхода"