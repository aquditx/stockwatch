# Runs the nightly report task now (instead of waiting for midnight IST).
# Run from the project root with $env:AWS_PROFILE set.
$tf = Join-Path $PSScriptRoot "..\terraform"
$region = terraform "-chdir=$tf" output -raw region
$subnet = terraform "-chdir=$tf" output -raw public_subnet_id
$sg     = terraform "-chdir=$tf" output -raw task_security_group_id
$net = "awsvpcConfiguration={subnets=[$subnet],securityGroups=[$sg],assignPublicIp=ENABLED}"
aws ecs run-task --region $region --cluster stockwatch --launch-type FARGATE --task-definition stockwatch-report --network-configuration $net --query "tasks[0].taskArn" --output text
Write-Host "Started. The task takes about 1 minute; the summary arrives by email. Logs: CloudWatch group /ecs/stockwatch-report"
