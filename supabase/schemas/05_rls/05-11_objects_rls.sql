create policy "members can download their orgs media"
on storage.objects
for select
to authenticated, anon
using (
  bucket_id = 'media'
  and (storage.foldername(name))[2] in ( select get_authorized_orgs('member')::text ) -- message v1 path is organizations/<org_id>/attachments/<file_id>
);

create policy "members can upload their orgs media"
on storage.objects
for insert
to authenticated, anon
with check (
  bucket_id = 'media'
  and (storage.foldername(name))[2] in ( select get_authorized_orgs('member')::text ) -- message v1 path is organizations/<org_id>/attachments/<file_id>
);

create policy "agents can download referenced visible media"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'media'
  and public.agent_can_download_media_object(name)
);

create policy "agents can upload their orgs media"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'media'
  and public.get_request_organization_role(
    ((storage.foldername(name))[2])::uuid
  ) = 'agent'::public.role
);
