# StockWatch Phase 1 smoke test (PowerShell, no jq or Git Bash needed).
# Run from the project root, in a window where AWS_PROFILE is set if you use a profile:
#   powershell -ExecutionPolicy Bypass -File .\scripts\smoke_test.ps1 -OwnerEmail owner@example.com -StaffEmail staff@example.com -Password 'StrongPass123'
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

function Call($Method, $Path, $Token, $Body) {
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
  Write-Host "  -> HTTP $code  $text"
  return @{ Code = $code; Body = $text }
}

$newProduct = '{"name":"Widget","sku":"W-1","stock":12,"reorder_threshold":5,"reorder_qty":50,"supplier_email":"supplier@example.com"}'

Write-Host "== Creating users"
EnsureUser $OwnerEmail "owner"
EnsureUser $StaffEmail "staff"
$ownerToken = GetToken $OwnerEmail
$staffToken = GetToken $StaffEmail
if (-not $ownerToken -or -not $staffToken -or $ownerToken -eq "None" -or $staffToken -eq "None") {
  Write-Host "Login failed. Check the password rules (10+ chars, upper, lower, number)." -ForegroundColor Red
  exit 1
}

Write-Host "`n== No token (expect 401)"
Call "GET" "/products" $null $null | Out-Null

Write-Host "`n== Staff creates product (expect 403)"
Call "POST" "/products" $staffToken $newProduct | Out-Null

Write-Host "`n== Owner creates product (expect 201)"
$created = Call "POST" "/products" $ownerToken $newProduct
$productId = ($created.Body | ConvertFrom-Json).product_id
if (-not $productId) { Write-Host "No product id returned, stopping." -ForegroundColor Red; exit 1 }

Write-Host "`n== Staff lists products (expect 200)"
Call "GET" "/products" $staffToken $null | Out-Null

Write-Host "`n== Staff sells 10, stock 12 -> 2 (expect 200)"
Call "POST" "/products/$productId/stock" $staffToken '{"delta":-10}' | Out-Null

Write-Host "`n== Staff sells 10 more (expect 409, insufficient stock)"
Call "POST" "/products/$productId/stock" $staffToken '{"delta":-10}' | Out-Null

Write-Host "`n== Invalid payload (expect 400)"
Call "POST" "/products" $ownerToken '{"name":"","stock":-1}' | Out-Null

Write-Host "`n== Staff deletes (expect 403)"
Call "DELETE" "/products/$productId" $staffToken $null | Out-Null

Write-Host "`n== Owner deletes (expect 200)"
Call "DELETE" "/products/$productId" $ownerToken $null | Out-Null

Write-Host "`nDone."