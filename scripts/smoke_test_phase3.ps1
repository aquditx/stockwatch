# StockWatch Phase 3 test: low stock -> purchase order -> approval workflow.
# Run from the project root (set $env:AWS_PROFILE first if you use a profile):
#   powershell -ExecutionPolicy Bypass -File .\scripts\smoke_test_phase3.ps1 -OwnerEmail owner@example.com -StaffEmail staff@example.com -Password 'StrongPass123'
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

function GetOrders($productId) {
  $r = Call "GET" "/orders?limit=100" $script:staffToken $null $true
  if ($r.Code -ne 200) { return @() }
  $items = ($r.Body | ConvertFrom-Json).items
  return @($items | Where-Object { $_.product_id -eq $productId })
}

function WaitForOrder($productId, $status, $timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $match = @(GetOrders $productId) | Where-Object { $_.status -eq $status } | Select-Object -First 1
    if ($match) { return $match }
    Start-Sleep -Seconds 3
  }
  return $null
}

function Check($label, $actual, $expected) {
  if ($actual -eq $expected) {
    Write-Host "  PASS  $label (got $actual)" -ForegroundColor Green
  } else {
    Write-Host "  FAIL  $label (expected $expected, got $actual)" -ForegroundColor Red
  }
}

function NewProduct($name, $sku) {
  $body = '{"name":"' + $name + '","sku":"' + $sku + '","stock":12,"reorder_threshold":5,"reorder_qty":50,"supplier_email":"supplier@example.com"}'
  $r = Call "POST" "/products" $ownerToken $body $true
  return ($r.Body | ConvertFrom-Json).product_id
}

function Sell($productId, $delta) {
  Call "POST" "/products/$productId/stock" $script:staffToken ('{"delta":' + $delta + '}') $true | Out-Null
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

# ---- Scenario A: approve -----------------------------------------------------
Write-Host "`n== Scenario A: low stock, owner approves"
$productA = NewProduct "PO Test Widget A" "PO-A"
if (-not $productA) { Write-Host "Could not create product A, stopping." -ForegroundColor Red; exit 1 }
Write-Host "  staff sells 8 (12 -> 4, below threshold 5); waiting for the order (up to 2 min)..."
Sell $productA -8
$po = WaitForOrder $productA "PENDING_APPROVAL" 120
Check "order created and waiting for approval" ([bool]$po) $true

if ($po) {
  Write-Host "  staff tries to approve (expect 403)"
  $r = Call "POST" "/orders/$($po.po_id)/approve" $script:staffToken $null $true
  Check "staff cannot approve" $r.Code 403

  Write-Host "  owner approves (expect 200)"
  $r = Call "POST" "/orders/$($po.po_id)/approve" $ownerToken $null $true
  Check "owner approve call" $r.Code 200

  Write-Host "  approving again (expect 409)"
  $r = Call "POST" "/orders/$($po.po_id)/approve" $ownerToken $null $true
  Check "double approval blocked" $r.Code 409

  Write-Host "  waiting for the workflow to email the supplier..."
  $sent = WaitForOrder $productA "SENT_TO_SUPPLIER" 60
  Check "order sent to supplier" ([bool]$sent) $true
}

# ---- Scenario B: one open order per product, then reject ---------------------
Write-Host "`n== Scenario B: second crossing does not create a second order; owner rejects"
$productB = NewProduct "PO Test Widget B" "PO-B"
Sell $productB -8
$poB = WaitForOrder $productB "PENDING_APPROVAL" 120
Check "order created for product B" ([bool]$poB) $true

Write-Host "  restock +10 then sell 10 to cross the threshold a second time..."
Sell $productB 10
Start-Sleep -Seconds 4
Sell $productB -10
Start-Sleep -Seconds 25
$count = @(GetOrders $productB).Count
Check "still exactly one order for product B" $count 1

if ($poB) {
  Write-Host "  owner rejects (expect 200)"
  $r = Call "POST" "/orders/$($poB.po_id)/reject" $ownerToken $null $true
  Check "owner reject call" $r.Code 200
  $rej = WaitForOrder $productB "REJECTED" 30
  Check "order marked REJECTED" ([bool]$rej) $true
}

Write-Host "`n== Cleanup: owner deletes the test products (orders are kept as history)"
if ($productA) { Call "DELETE" "/products/$productA" $ownerToken $null $true | Out-Null }
if ($productB) { Call "DELETE" "/products/$productB" $ownerToken $null $true | Out-Null }

Write-Host "`nDone. Your inbox should have 'Approve purchase order' and 'Purchase order sent' emails."
Write-Host "Open Step Functions in the AWS console to see the execution graphs for the demo."
