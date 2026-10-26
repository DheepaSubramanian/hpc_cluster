<#
Post-apply smoke tests for this Terraform stack.

Usage:
  pwsh ./post_apply_test.ps1 -Region us-east-2
  pwsh ./post_apply_test.ps1 -Region us-east-2 -RunSsmChecks -RunJobTest -TestUser alice

Notes:
- Requires: terraform, aws CLI, and AWS credentials with read access + SSM send-command permissions.
- If you didn't define var.cluster_users, pass -TestUser to exercise the S3 archive path (or skip -RunJobTest).
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$Region,

  [Parameter(Mandatory = $false)]
  [switch]$RunSsmChecks,

  [Parameter(Mandatory = $false)]
  [switch]$RunJobTest,

  [Parameter(Mandatory = $false)]
  [string]$TestUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found in PATH: $Name"
  }
}

function Write-Section([string]$Title) {
  Write-Host "\n=== $Title ===" -ForegroundColor Cyan
}

function Ok([string]$Msg) { Write-Host "[OK]  $Msg" -ForegroundColor Green }
function Warn([string]$Msg) { Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Fail([string]$Msg) { Write-Host "[FAIL] $Msg" -ForegroundColor Red }

function Get-TfOutputs {
  $json = terraform output -json 2>$null
  if (-not $json) { throw "terraform output returned empty. Did you run terraform apply?" }
  return $json | ConvertFrom-Json
}

function Get-TfValue($Outputs, [string]$Key) {
  $prop = $Outputs.PSObject.Properties[$Key]
  if ($null -eq $prop) { return $null }
  if ($null -eq $prop.Value) { return $null }
  return $prop.Value.value
}

function Aws([string[]]$Args) {
  $full = @('aws') + $Args
  $out = & $full[0] $full[1..($full.Length-1)] 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "aws command failed ($LASTEXITCODE): $($Args -join ' ')`n$out"
  }
  return $out
}

function AwsJson([string[]]$Args) {
  $out = Aws ($Args + @('--output','json'))
  return $out | ConvertFrom-Json
}
function Test-TcpPort {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $false)][int]$TimeoutMs = 3000
  )

  try {
    $client = [System.Net.Sockets.TcpClient]::new()
    $task = $client.ConnectAsync($HostName, $Port)
    if (-not $task.Wait($TimeoutMs)) {
      $client.Dispose()
      return $false
    }
    $client.Dispose()
    return $true
  } catch {
    return $false
  }
}

function Wait-SsmCommand([string]$CommandId, [string]$InstanceId, [int]$TimeoutSeconds = 600) {
  $start = Get-Date
  while ($true) {
    $inv = AwsJson @('ssm','get-command-invocation','--command-id',$CommandId,'--instance-id',$InstanceId)
    if ($inv.Status -in @('Success','Cancelled','TimedOut','Failed')) {
      return $inv
    }

    if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
      throw "Timeout waiting for SSM command $CommandId"
    }

    Start-Sleep -Seconds 5
  }
}

Require-Command terraform
Require-Command aws

Write-Section "Terraform Outputs"
$outputs = Get-TfOutputs

$dcvInstanceId = Get-TfValue $outputs 'dcv_instance_id'
$dcvPublicIp   = Get-TfValue $outputs 'dcv_public_ip'
$dcvPublicDns  = Get-TfValue $outputs 'dcv_public_dns'
$archiveBucket = Get-TfValue $outputs 'archive_bucket'
$efsId         = Get-TfValue $outputs 'efs_id'
$pcsClusterId  = Get-TfValue $outputs 'pcs_cluster_id'
$pcsQueueName  = Get-TfValue $outputs 'pcs_queue_name'

if (-not $Region) {
  $Region = (aws configure get region 2>$null)
}
if (-not $Region) {
  throw "Region not provided and aws configure has no default. Re-run with -Region <region>."
}

Ok "Region: $Region"

if ($dcvInstanceId) { Ok "dcv_instance_id: $dcvInstanceId" } else { Warn "dcv_instance_id missing (run terraform apply first)" }
if ($dcvPublicIp)   { Ok "dcv_public_ip:   $dcvPublicIp" } else { Warn "dcv_public_ip missing" }
if ($dcvPublicDns)  { Ok "dcv_public_dns:  $dcvPublicDns" } else { Warn "dcv_public_dns missing" }
if ($archiveBucket) { Ok "archive_bucket:  $archiveBucket" } else { Warn "archive_bucket missing" }
if ($efsId)         { Ok "efs_id:          $efsId" } else { Warn "efs_id missing" }

if ($pcsClusterId)  { Ok "pcs_cluster_id:  $pcsClusterId" }
if ($pcsQueueName)  { Ok "pcs_queue_name:  $pcsQueueName" }

Write-Section "AWS Resource Checks"

if ($dcvInstanceId) {
  $desc = AwsJson @('ec2','describe-instances','--region',$Region,'--instance-ids',$dcvInstanceId)
  $inst = $desc.Reservations[0].Instances[0]

  if ($inst.State.Name -eq 'running') { Ok "DCV instance is running" } else { Fail "DCV instance state is $($inst.State.Name)" }

  if ($dcvPublicIp -and ($inst.PublicIpAddress -eq $dcvPublicIp)) {
    Ok "DCV public IP matches instance"
  } elseif ($dcvPublicIp) {
    Warn "Terraform output public IP ($dcvPublicIp) != instance public IP ($($inst.PublicIpAddress))"
  } else {
    Warn "Terraform output dcv_public_ip is empty"
  }

  if ($dcvPublicDns) {
    if (Test-TcpPort -HostName $dcvPublicDns -Port 8443) { Ok "Port 8443 reachable on $dcvPublicDns" } else { Warn "Port 8443 not reachable (yet) on $dcvPublicDns" }
  } else {
    Warn "Terraform output dcv_public_dns is empty"
  }
}

if ($archiveBucket) {
  try {
    Aws @('s3api','head-bucket','--region',$Region,'--bucket',$archiveBucket) | Out-Null
    Ok "S3 archive bucket exists"
  } catch {
    Fail "S3 archive bucket not reachable: $archiveBucket"
  }
}

if ($efsId) {
  try {
    AwsJson @('efs','describe-file-systems','--region',$Region,'--file-system-id',$efsId) | Out-Null
    Ok "EFS exists"
  } catch {
    Fail "EFS not found: $efsId"
  }
}

if ($pcsClusterId) {
  try {
    # If the AWS CLI has PCS support, this should work. If not, we warn.
    AwsJson @('pcs','get-cluster','--region',$Region,'--cluster-identifier',$pcsClusterId) | Out-Null
    Ok "PCS cluster visible to AWS CLI"
  } catch {
    Warn "Could not query PCS cluster via AWS CLI (may be missing CLI support/permissions): $pcsClusterId"
  }
}

if ($RunSsmChecks -and $dcvInstanceId) {
  Write-Section "SSM Remote Checks (DCV instance)"

  # Confirm SSM managed
  try {
    $info = AwsJson @('ssm','describe-instance-information','--region',$Region,'--filters',"Key=InstanceIds,Values=$dcvInstanceId")
    if ($info.InstanceInformationList.Count -gt 0) {
      Ok "DCV instance is registered in SSM"
    } else {
      Warn "DCV instance not showing in SSM yet (agent may still be starting)"
    }
  } catch {
    Warn "Unable to query SSM instance information"
  }

  $cmds = @(
    'set -euxo pipefail',
    'echo "--- hostname ---"; hostname',
    'echo "--- /home mount ---"; df -h | (grep -E " /home$" || true)',
    'echo "--- sackd ---"; systemctl is-active sackd || true',
    'echo "--- slurm ---"; (command -v sinfo && sinfo) || true',
    'echo "--- queue ---"; (command -v squeue && squeue) || true'
  )

  $send = AwsJson @(
    'ssm','send-command',
    '--region',$Region,
    '--document-name','AWS-RunShellScript',
    '--instance-ids',$dcvInstanceId,
    '--parameters',("commands=" + ($cmds -join ','))
  )

  $commandId = $send.Command.CommandId
  Ok "SSM command sent: $commandId"

  $inv = Wait-SsmCommand -CommandId $commandId -InstanceId $dcvInstanceId -TimeoutSeconds 900

  if ($inv.Status -eq 'Success') {
    Ok "SSM checks succeeded"
    Write-Host $inv.StandardOutputContent
    if ($inv.StandardErrorContent) { Write-Host $inv.StandardErrorContent }
  } else {
    Fail "SSM checks ended with status $($inv.Status)"
    Write-Host $inv.StandardOutputContent
    Write-Host $inv.StandardErrorContent
  }
}

if ($RunJobTest -and $dcvInstanceId) {
  Write-Section "Job + Archive Test"

  if (-not $pcsQueueName) {
    Warn "pcs_queue_name not found in terraform outputs; skipping job test"
  } else {
    $jobCmds = @(
      'set -euxo pipefail',
      "echo '--- submit job ---'",
      "sbatch -p $pcsQueueName --wrap='hostname; nvidia-smi || true; sleep 10'",
      "sleep 5",
      "squeue || true"
    )

    if ($TestUser) {
      $jobCmds += @(
        "echo '--- archive test ---'",
        "install -d -m 700 /home/$TestUser/results || true",
        "echo test-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')) > /home/$TestUser/results/post_apply_test.txt",
        "sudo /usr/local/bin/archive-results.sh || true"
      )
    } else {
      $jobCmds += "echo 'No -TestUser provided; skipping S3 archive exercise'"
    }

    $send2 = AwsJson @(
      'ssm','send-command',
      '--region',$Region,
      '--document-name','AWS-RunShellScript',
      '--instance-ids',$dcvInstanceId,
      '--parameters',("commands=" + ($jobCmds -join ','))
    )

    $cmdId2 = $send2.Command.CommandId
    Ok "SSM job command sent: $cmdId2"

    $inv2 = Wait-SsmCommand -CommandId $cmdId2 -InstanceId $dcvInstanceId -TimeoutSeconds 1200
    if ($inv2.Status -eq 'Success') {
      Ok "Job/archive test completed"
      Write-Host $inv2.StandardOutputContent
      if ($inv2.StandardErrorContent) { Write-Host $inv2.StandardErrorContent }
    } else {
      Fail "Job/archive test ended with status $($inv2.Status)"
      Write-Host $inv2.StandardOutputContent
      Write-Host $inv2.StandardErrorContent
    }

    if ($TestUser -and $archiveBucket) {
      Warn "If archive ran, check S3 path: s3://$archiveBucket/results/$TestUser/"
    }
  }
}

Write-Section "Done"
Ok "Smoke test script finished"




