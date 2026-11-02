$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$expectedProject = 'acifbsuxmpdtlhbsvhlj'
if ((Get-Content -Raw (Join-Path $repository 'supabase/.temp/project-ref')).Trim() -ne $expectedProject) {
  throw 'Refusing backup: linked project is not staging.'
}
$cli = Join-Path $repository 'node_modules/supabase/dist/supabase.js'
$trackingDirectory = Join-Path $repository 'node_modules/.campaign-tracking-backup'
New-Item -ItemType Directory -Force -Path $trackingDirectory | Out-Null
$query = @'
select jsonb_build_object(
  'project','acifbsuxmpdtlhbsvhlj','captured_at',clock_timestamp(),
  'campaigns',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaigns t),
  'deliveries',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_deliveries t),
  'jobs',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_dispatch_jobs t),
  'recipients',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_csv_recipients t),
  'transport_settings',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_dispatch_settings t),
  'send_ledger',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_send_ledger t)
) as snapshot;
'@
$captured = & node $cli db query --linked $query --output json
if ($LASTEXITCODE -ne 0) { throw 'Staging data backup query failed.' }
$result = ($captured -join "`n") | ConvertFrom-Json
if ($result.rows.Count -ne 1 -or $result.rows[0].snapshot.project -ne $expectedProject) { throw 'Invalid backup response.' }
$schemaPath = Join-Path $repository 'node_modules/campaign-tracking-staging-schema-before.sql'
if (-not (Test-Path -LiteralPath $schemaPath)) { throw 'Run the staging schema dump first.' }
$envelope = @{ data = $result.rows[0].snapshot; schema = [IO.File]::ReadAllText($schemaPath) } | ConvertTo-Json -Depth 100 -Compress
Add-Type -AssemblyName System.Security
$encrypted = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($envelope), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
$target = Join-Path $trackingDirectory 'staging-before-campaign-tracking.dpapi'
if (Test-Path -LiteralPath $target) { throw 'Backup already exists; do not overwrite the pre-deployment snapshot.' }
[IO.File]::WriteAllBytes($target, $encrypted)
$roundtrip = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($target), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)) | ConvertFrom-Json
if ($roundtrip.data.project -ne $expectedProject) { throw 'Backup verification failed.' }
Write-Output "Encrypted backup verified: $target"
Get-FileHash -LiteralPath $target -Algorithm SHA256 | Select-Object Algorithm, Hash
Write-Output "Campaigns: $($roundtrip.data.campaigns.Count); deliveries: $($roundtrip.data.deliveries.Count); jobs: $($roundtrip.data.jobs.Count)"
