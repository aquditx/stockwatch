# StockWatch Phase 2 test: low-stock detection pipeline, end to end.
# Run from the project root (set $env:AWS_PROFILE first if you use a profile):
#   powershell -ExecutionPolicy Bypass -File .\scripts\smoke_test_phase2.ps1 -OwnerEmail owner@example.com -StaffEmail staff@example.com -Password 'StrongPass123'
param(
  [Parameter(Mandatory = $true)][string]$OwnerEmail,
  [Parameter(Mandatory = $true)][string]$StaffEmail,
  [Parameter(Mandatory = $true)][string]$Password
)

$ErrorActionPreference = "Continue"
$tfDir = Join-Path $PSScriptRoot "..\terraform"

function TfOut($name) { (terraform "-chdir=$tfDir" output -raw $name) }

$ApiUrl   = TfOut "api_url"
$PoolId   = TfOut "user_pool_id"
$ClientId = TfOut "user_pool_client_id"
$Region   = TfOut "region"

if (-not $ApiUrl -or -not $PoolId -or -not $ClientId -or -not $Region) {
  Write-Host "Could not read Terraform outputs. Run this from the project root after 'terraform apply'." -ForegroundColor Red
  exit 1
}

function EnsureUser($email, $group) {
  aws cognito-idp admin-create-user --region $Region --user-pool-id $PoolId --username $email --message-action SUPPRESS --user-attributes "Name=email,Value=$email" "Name=email_verified,Value=true" 2>$null | Out-Null
  aws cognito-idp admin-set-user-password --region $Region --user-pool-id $PoolId --username $email --password $Password --permanent | Out-Null
  aws cognito-idp admin-add-user-to-group --region $Region --user-pool-id $PoolId --username $email --group-name $group | Out-Null
}

function GetToken($email) {
  aws cognito-idp initiate-auth --region $Region --client-id $ClientId --auth-flow USER_PASSWORD_AUTH --auth-parameters "USERNAME=$email,PASSWORD=$Password" --query "AuthenticationResult.IdToken" --output text
}

function Call($Method, $Path, $Token, $Body, $Quiet = $false) {
  $headers = @{}
  if ($Token) { $headers["Authorization"] = $Token }
  $params = @{ Uri = "$ApiUrl$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true }
  if ($Body) { $params["Body"] = $Body; $params["ContentType"] = "application/json" }
  $code = 0
  $text = ""
  try {
    $r = Invoke-WebRequest @params
    $code = [int]$r.StatusCode
    $text = $r.Content
  } catch {
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    $text = $_.ErrorDetails.Message
    if (-not $text) {
      try {
        $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $text = $sr.ReadToEnd()
      } catch { }
    }
  }
  if (-not $Quiet) { Write-Host "  -> HTTP $code  $text" }
  return @{ Code = $code; Body = $text }
}

function CountAlerts($productId) {
  $r = Call "GET" "/alerts?limit=100" $script:staffToken $null $true
  if ($r.Code -ne 200) { return -1 }
  $items = ($r.Body | ConvertFrom-Json).items
  return @($items | Where-Object { $_.product_id -eq $productId }).Count
}

function WaitForAlerts($productId, $expected, $timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  $count = 0
  while ((Get-Date) -lt $deadline) {
    $count = CountAlerts $productId
    if ($count -ge $expected) { break }
    Start-Sleep -Seconds 3
  }
  return $count
}

function Check($label, $actual, $expected) {
  if ($actual -eq $expected) {
    Write-Host "  PASS  $label (got $actual)" -ForegroundColor Green
  } else {
    Write-Host "  FAIL  $label (expected $expected, got $actual)" -ForegroundColor Red
  }
}

Write-Host "== Logging in"
EnsureUser $OwnerEmail "owner"
EnsureUser $StaffEmail "staff"
$ownerToken = GetToken $OwnerEmail
$script:staffToken = GetToken $StaffEmail
if (-not $ownerToken -or -not $script:staffToken -or $ownerToken -eq "None" -or $script:staffToken -eq "None") {
  Write-Host "Login failed. Check the password rules (10+ chars, upper, lower, number)." -ForegroundColor Red
  exit 1
}

Write-Host "`n== Owner creates 'Demo Widget': stock 12, reorder threshold 5"
$body = '{"name":"Demo Widget","sku":"DEMO-1","stock":12,"reorder_threshold":5,"reorder_qty":50,"supplier_email":"supplier@example.com"}'
$created = Call "POST" "/products" $ownerToken $body
$productId = ($created.Body | ConvertFrom-Json).product_id
if (-not $productId) { Write-Host "No product id returned, stopping." -ForegroundColor Red; exit 1 }

Write-Host "`n== Staff sells 8 (12 -> 4, crosses the threshold): expect ONE alert"
Call "POST" "/products/$productId/stock" $script:staffToken '{"delta":-8}' | Out-Null
Write-Host "  waiting for stream -> detector -> EventBridge -> SQS -> notifier (up to 90s)..."
$n = WaitForAlerts $productId 1 90
Check "alerts after first sale" $n 1

Write-Host "`n== Staff sells 1 more (4 -> 3, already low): expect NO new alert"
Call "POST" "/products/$productId/stock" $script:staffToken '{"delta":-1}' | Out-Null
Start-Sleep -Seconds 15
$n = CountAlerts $productId
Check "alerts after second sale" $n 1

Write-Host "`n== Staff restocks +10 (3 -> 13), then sells 9 (13 -> 4): expect a SECOND alert"
Call "POST" "/products/$productId/stock" $script:staffToken '{"delta":10}' | Out-Null
Start-Sleep -Seconds 5
Call "POST" "/products/$productId/stock" $script:staffToken '{"delta":-9}' | Out-Null
$n = WaitForAlerts $productId 2 90
Check "alerts after restock and sell-down" $n 2

Write-Host "`n== Latest alert for this product"
$r = Call "GET" "/alerts?limit=100" $script:staffToken $null $true
($r.Body | ConvertFrom-Json).items | Where-Object { $_.product_id -eq $productId } | Select-Object -First 1 | Format-List name, stock, previous_stock, suggested_order_qty, status, detected_at

Write-Host "== Cleanup: owner deletes the demo product (alert history is kept)"
Call "DELETE" "/products/$productId" $ownerToken $null | Out-Null

Write-Host "`nDone. Check your inbox for 2 'Low stock: Demo Widget' emails (confirm the SNS subscription first if you have not)."
