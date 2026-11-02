$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$expectedProject = 'buvjopvpkgvzhykwsxnk'
if ((Get-Content -Raw (Join-Path $repository 'supabase/.temp/project-ref')).Trim() -ne $expectedProject) {
  throw 'Refusing backup: linked project is not Main.'
}
$cli = Join-Path $repository 'node_modules/supabase/dist/supabase.js'
$directory = Join-Path $repository 'node_modules/.campaign-main-ops'
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $directory /inheritance:r /grant:r "${identity}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect backup directory.' }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$schemaPath = Join-Path $directory "main-before-campaign-parity-$stamp.sql"
$target = Join-Path $directory "main-before-campaign-parity-$stamp.dpapi"
if ((Test-Path -LiteralPath $schemaPath) -or (Test-Path -LiteralPath $target)) { throw 'Backup already exists.' }
& node $cli db dump --linked --schema public,billing,storage --file $schemaPath
if ($LASTEXITCODE -ne 0) { throw 'Main schema backup failed.' }
$query = @'
select jsonb_build_object(
  'project','buvjopvpkgvzhykwsxnk','captured_at',clock_timestamp(),
  'campaigns',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaigns t),
  'deliveries',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_deliveries t),
  'jobs',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_dispatch_jobs t),
  'recipients',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_csv_recipients t),
  'transport_settings',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_dispatch_settings t)
) as snapshot;
'@
$captured = & node $cli db query --linked $query --output json
if ($LASTEXITCODE -ne 0) { throw 'Main data backup failed.' }
$result = ($captured -join "`n") | ConvertFrom-Json
if ($result.rows.Count -ne 1 -or $result.rows[0].snapshot.project -ne $expectedProject) { throw 'Invalid backup response.' }
$envelope = @{ data = $result.rows[0].snapshot; schema = [IO.File]::ReadAllText($schemaPath) } | ConvertTo-Json -Depth 100 -Compress
Add-Type -AssemblyName System.Security
$encrypted = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($envelope), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
[IO.File]::WriteAllBytes($target, $encrypted)
$roundtrip = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($target), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)) | ConvertFrom-Json
if ($roundtrip.data.project -ne $expectedProject -or -not $roundtrip.schema.Contains('CREATE')) { throw 'Backup verification failed.' }
Remove-Item -LiteralPath $schemaPath
Write-Output "Encrypted Main backup verified: $target"
Get-FileHash -LiteralPath $target -Algorithm SHA256 | Select-Object Algorithm,Hash
Write-Output "Campaigns: $($roundtrip.data.campaigns.Count); deliveries: $($roundtrip.data.deliveries.Count); jobs: $($roundtrip.data.jobs.Count)"
