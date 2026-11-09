-- Data definitions: db diff cannot capture bucket/cron records. Include these
-- statements in the generated feature migration as the documented data exception.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('campaign-log-exports','campaign-log-exports',false,20971520,array['text/csv'])
on conflict(id) do nothing;

select cron.schedule('campaign-log-exports-every-minute','* * * * *',
  $job$ select net.http_post(
    url:=(select decrypted_secret from vault.decrypted_secrets where name='edge_functions_url')||'/campaign-log-export',
    headers:=jsonb_build_object('content-type','application/json','authorization','Bearer '||
      (select decrypted_secret from vault.decrypted_secrets where name='edge_functions_token')),
    body:='{}'::jsonb,timeout_milliseconds:=30000); $job$);
