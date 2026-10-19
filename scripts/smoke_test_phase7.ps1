# StockWatch Phase 7 test: seed sales history, check the forecast, check a live sale reaches Postgres.
#   powershell -ExecutionPolicy Bypass -File .\scripts\smoke_test_phase7.ps1 -OwnerEmail owner@example.com -Password 'StrongPass123'
param(
  [Parameter(Mandatory = $true)][string]$OwnerEmail,
  [Parameter(Mandatory = $true)][string]$Password
)
$ErrorActionPreference = "Continue"
$tfDir = Join-Path $PSScriptRoot "..\terraform"
function TfOut($name) { (terraform "-chdir=$tfDir" output -raw $name) }
$ApiUrl = TfOut "api_url"; $ClientId = TfOut "user_pool_client_id"; $Region = TfOut "region"; $Loader = TfOut "sales_loader_function"

function Check($label, $actual, $expected) {
  if ($actual -eq $expected) { Write-Host "  PASS  $label (got $actual)" -ForegroundColor Green }
  else { Write-Host "  FAIL  $label (expected $expected, got $actual)" -ForegroundColor Red }
}
function Call($Method, $Path, $Body) {
  $params = @{ Uri = "$ApiUrl$Path"; Method = $Method; Headers = @{ Authorization = $script:token }; UseBasicParsing = $true }
  if ($Body) { $params["Body"] = $Body; $params["ContentType"] = "application/json" }
  try { $r = Invoke-WebRequest @params; return @{ Code = [int]$r.StatusCode; Body = $r.Content } }
  catch { $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }; return @{ Code = $code; Body = $_.ErrorDetails.Message } }
}

$script:token = aws cognito-idp initiate-auth --region $Region --client-id $ClientId --auth-flow USER_PASSWORD_AUTH --auth-parameters "USERNAME=$OwnerEmail,PASSWORD=$Password" --query "AuthenticationResult.IdToken" --output text
if (-not $script:token -or $script:token -eq "None") { Write-Host "Login failed. Run the Phase 3 test once to create the users." -ForegroundColor Red; exit 1 }

Write-Host "== Create a test product"
$body = '{"name":"Forecast Test Rice","sku":"FC-1","stock":40,"reorder_threshold":5,"reorder_qty":50,"supplier_email":"supplier@example.com"}'
$r = Call "POST" "/products" $body
$pid2 = ($r.Body | ConvertFrom-Json).product_id
Check "product created" $r.Code 201

Write-Host "== Seed 14 days of sales history (runs inside the VPC, writes to RDS)"
'{"action":"seed","days":14}' | Set-Content -NoNewline "$env:TEMP\seed.json"
aws lambda invoke --region $Region --function-name $Loader --cli-binary-format raw-in-base64-out --payload fileb://$env:TEMP\seed.json "$env:TEMP\seed_out.json" | Out-Null
Write-Host "  loader said: $(Get-Content "$env:TEMP\seed_out.json")"

Write-Host "== Forecast"
$r = Call "GET" "/forecast" $null
Check "forecast endpoint" $r.Code 200
$mine = @(($r.Body | ConvertFrom-Json).items | Where-Object { $_.product_id -eq $pid2 })[0]
Check "test product has sales history" ($mine.sold_7d -gt 0) $true
Write-Host "  $($mine.name): stock $($mine.stock), $($mine.avg_daily)/day, $($mine.days_left) days left, suggest $($mine.suggested_qty)"
$before = $mine.sold_7d

Write-Host "== A live sale should reach Postgres through the stream"
Call "POST" "/products/$pid2/stock" '{"delta":-3}' | Out-Null
$after = $before
for ($i = 0; $i -lt 12 -and $after -eq $before; $i++) {
  Start-Sleep -Seconds 5
  $f = Call "GET" "/forecast" $null
  $after = @(($f.Body | ConvertFrom-Json).items | Where-Object { $_.product_id -eq $pid2 })[0].sold_7d
}
Check "sold_7d increased by 3" ($after - $before) 3

Write-Host "== Cleanup"
Call "DELETE" "/products/$pid2" $null | Out-Null
Write-Host "`nDone. Run .\scripts\run_report.ps1 to start the Fargate report; the email arrives in about a minute."
