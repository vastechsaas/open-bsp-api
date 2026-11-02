$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
if ((Get-Content -Raw (Join-Path $repository 'supabase/.temp/project-ref')).Trim() -ne 'buvjopvpkgvzhykwsxnk') { throw 'Not Main.' }
$cli = Join-Path $repository 'node_modules/supabase/dist/supabase.js'
$backup = Join-Path $repository 'node_modules/.campaign-main-ops/main-before-campaign-parity-20261102T142832Z.dpapi'
Add-Type -AssemblyName System.Security
$before = ([Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($backup), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)) | ConvertFrom-Json).data
$query = @'
select jsonb_build_object(
 'campaigns',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaigns t),
 'deliveries',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_deliveries t),
 'jobs',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_dispatch_jobs t),
 'recipients',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_csv_recipients t),
 'transport_settings',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.campaign_dispatch_settings t),
 'private_ingest',not has_function_privilege('authenticated','public.ingest_campaign_receipt(uuid,text,text,text,timestamptz,text,text)','execute'),
 'worker_ingest',has_function_privilege('service_role','public.ingest_campaign_receipt(uuid,text,text,text,timestamptz,text,text)','execute'),
 'private_activity',not has_table_privilege('authenticated','public.campaign_activity','select'),
 'policy_count',(select count(*) from public.campaign_sending_policies where enabled),
 'activity_count',(select count(*) from public.campaign_activity)
) as snapshot;
'@
$response = & node $cli db query --linked $query --output json
if ($LASTEXITCODE -ne 0) { throw 'Main verification query failed.' }
$after = (($response -join "`n") | ConvertFrom-Json).rows[0].snapshot
foreach ($table in @('campaigns','deliveries','jobs','recipients','transport_settings')) {
  $originals = @($before.$table)
  $current = @($after.$table)
  if ($originals.Count -ne $current.Count) { throw "Record count changed: $table" }
  foreach ($original in $originals) {
    $identity = if ($table -eq 'transport_settings') { 'organization_id' } else { 'id' }
    $match = @($current | Where-Object { $_.$identity -eq $original.$identity })
    if ($match.Count -ne 1) { throw "Identity changed: $table" }
    foreach ($property in $original.PSObject.Properties) {
      $left = $property.Value | ConvertTo-Json -Depth 100 -Compress
      $right = $match[0].($property.Name) | ConvertTo-Json -Depth 100 -Compress
      if ($left -cne $right) { throw "Original field changed: $table / $($property.Name)" }
    }
  }
  Write-Output "Preserved $table rows: $($originals.Count)"
}
if (-not $after.private_ingest -or -not $after.worker_ingest -or -not $after.private_activity) { throw 'Campaign reporting ACL mismatch.' }
Write-Output 'Private receipt/activity permissions verified.'
Write-Output "Enabled sending policies: $($after.policy_count); activity events: $($after.activity_count)"
