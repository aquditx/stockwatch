# Installs the Postgres driver next to the analytics Lambda code (it is zipped by Terraform).
# Run from the project root:  powershell -ExecutionPolicy Bypass -File .\scripts\install_analytics_deps.ps1
$target = Join-Path $PSScriptRoot "..\lambdas\analytics\vendor"
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
python -m pip install --quiet --target $target pg8000
if ($LASTEXITCODE -ne 0) { Write-Host "pip failed. Check that python and pip work." -ForegroundColor Red; exit 1 }
Write-Host "Installed to $target" -ForegroundColor Green
