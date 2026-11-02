$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$project = 'acifbsuxmpdtlhbsvhlj'
if ((Get-Content -Raw (Join-Path $repository 'supabase/.temp/project-ref')).Trim() -ne $project) {
  throw 'Refusing backup: linked project is not staging.'
}
$cli = Join-Path $repository 'node_modules/supabase/dist/supabase.js'
$targetDirectory = Join-Path $repository 'node_modules/.campaign-controls-backup'
New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
$schema = Join-Path $targetDirectory 'schema-before.sql'
$target = Join-Path $targetDirectory 'staging-before-campaign-controls.dpapi'
if (Test-Path -LiteralPath $target) { throw 'Pre-deployment backup already exists; refusing overwrite.' }
& node $cli db dump --linked --schema public --file $schema
if ($LASTEXITCODE -ne 0) { throw 'Staging schema backup failed.' }
$query = @'
select jsonb_build_object('project','acifbsuxmpdtlhbsvhlj','captured_at',clock_timestamp(),
 'campaigns',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaigns t),
 'deliveries',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_deliveries t),
 'jobs',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_dispatch_jobs t),
 'recipients',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_csv_recipients t),
 'activity',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_activity t),
 'receipts',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_delivery_receipts t),
 'send_ledger',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_send_ledger t)) as snapshot;
'@
$captured = & node $cli db query --linked $query --output json
if ($LASTEXITCODE -ne 0) { throw 'Staging data backup failed.' }
$result = ($captured -join "`n") | ConvertFrom-Json
if ($result.rows.Count -ne 1 -or $result.rows[0].snapshot.project -ne $project) { throw 'Invalid staging snapshot.' }
$envelope = @{ data = $result.rows[0].snapshot; schema = [IO.File]::ReadAllText($schema) } | ConvertTo-Json -Depth 100 -Compress
Add-Type -AssemblyName System.Security
$encrypted = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($envelope),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
[IO.File]::WriteAllBytes($target,$encrypted)
$check = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($target),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)) | ConvertFrom-Json
if ($check.data.project -ne $project) { throw 'Encrypted backup verification failed.' }
Write-Output "Encrypted staging backup verified: $target"
Write-Output "Campaigns: $($check.data.campaigns.Count); deliveries: $($check.data.deliveries.Count); jobs: $($check.data.jobs.Count)"
Get-FileHash -LiteralPath $target -Algorithm SHA256 | Select-Object Algorithm,Hash
