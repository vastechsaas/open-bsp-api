begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select plan(16);
select ok(not has_function_privilege('authenticated', 'public.claim_campaign_deliveries(integer)', 'execute'), 'campaign claims are not a public user RPC');
select ok(has_function_privilege('service_role', 'public.claim_campaign_deliveries(integer)', 'execute'), 'campaign worker retains execution permission');

select ok(public.valid_carousel_assets('[]', '16000000-0000-4000-8000-000000000001'), 'standard templates preserve empty metadata');
select ok(public.valid_carousel_assets('[{"card_id":"16000000-0000-4000-8000-000000000010"}]', '16000000-0000-4000-8000-000000000001', true), 'incomplete draft slots retain card identities');
select ok(not public.valid_carousel_assets('[{"card_id":"16000000-0000-4000-8000-000000000010"}]', '16000000-0000-4000-8000-000000000001'), 'incomplete image cannot be sent');
select ok(not public.valid_carousel_assets('{}', '16000000-0000-4000-8000-000000000001'), 'metadata must be an array');
select ok(not public.valid_carousel_assets('[{"card_id":"invalid"}]', '16000000-0000-4000-8000-000000000001', true), 'invalid card identity is rejected');
select ok(not public.valid_carousel_assets('[{"card_id":"16000000-0000-4000-8000-000000000010"},{"card_id":"16000000-0000-4000-8000-000000000010"}]', '16000000-0000-4000-8000-000000000001', true), 'duplicate identities are rejected');

create temporary table carousel_fixture (template jsonb, media jsonb, mapping jsonb);
insert into carousel_fixture values (
  '{"category":"MARKETING","components":[{"type":"BODY","text":"Offers"},{"type":"CAROUSEL","cards":[{"components":[{"type":"HEADER","format":"IMAGE"},{"type":"BODY","text":"Hello {{1}}"},{"type":"BUTTONS","buttons":[{"type":"URL","text":"Shop","url":"https://example.com"}]}]},{"components":[{"type":"HEADER","format":"IMAGE"},{"type":"BODY","text":"Offer two"},{"type":"BUTTONS","buttons":[{"type":"URL","text":"Shop","url":"https://example.com"}]}]}]}]}',
  '[{"card_index":0},{"card_index":1}]', '{"carousel.0.body.1":"contact.name"}'
);
select ok(public.carousel_campaign_ready(template, media, mapping), 'valid carousel routing indexes and mappings are ready') from carousel_fixture;
select ok(not public.carousel_campaign_ready(template, '[]', mapping), 'missing card images fail readiness') from carousel_fixture;
select ok(not public.carousel_campaign_ready(template, '[{"card_index":1},{"card_index":0}]', mapping), 'card indexes must match frozen ordering') from carousel_fixture;
select ok(not public.carousel_campaign_ready(template, media, '{}'), 'card-level variables must be mapped') from carousel_fixture;
select ok(not public.carousel_campaign_ready(jsonb_set(template, '{category}', '"UTILITY"'), media, mapping), 'carousel must be Marketing') from carousel_fixture;
select ok(not public.carousel_campaign_ready(jsonb_set(template, '{components,1,cards,0,components,0,format}', '"VIDEO"'), media, mapping), 'unsupported imported videos are rejected') from carousel_fixture;
select ok(not public.valid_carousel_assets(jsonb_build_array(jsonb_build_object('card_id', gen_random_uuid(), 'storage_uri', 'internal://media/organizations/another/attachments/' || repeat('a',43), 'file_name','image.png','mime_type','image/png','size',42)), '16000000-0000-4000-8000-000000000001'), 'image references cannot cross organizations');
select ok(public.carousel_campaign_ready('{"components":[{"type":"BODY","text":"Standard"}]}', '[]', '{}'), 'standard campaign readiness is unchanged');
select * from finish();
rollback;
