alter table "public"."contacts" add column "city" text;

alter table "public"."contacts" add column "company" text;

alter table "public"."contacts" add column "country" text;

alter table "public"."contacts" add column "email" text;

alter table "public"."contacts" add column "job_title" text;

alter table "public"."contacts" add constraint "contacts_city_check" CHECK (((city IS NULL) OR (char_length(city) <= 120))) not valid;

alter table "public"."contacts" validate constraint "contacts_city_check";

alter table "public"."contacts" add constraint "contacts_company_check" CHECK (((company IS NULL) OR (char_length(company) <= 200))) not valid;

alter table "public"."contacts" validate constraint "contacts_company_check";

alter table "public"."contacts" add constraint "contacts_country_check" CHECK (((country IS NULL) OR (char_length(country) <= 120))) not valid;

alter table "public"."contacts" validate constraint "contacts_country_check";

alter table "public"."contacts" add constraint "contacts_email_check" CHECK (((email IS NULL) OR ((char_length(email) <= 254) AND (email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'::text)))) not valid;

alter table "public"."contacts" validate constraint "contacts_email_check";

alter table "public"."contacts" add constraint "contacts_job_title_check" CHECK (((job_title IS NULL) OR (char_length(job_title) <= 120))) not valid;

alter table "public"."contacts" validate constraint "contacts_job_title_check";

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables publication_table
    where publication_table.pubname = 'supabase_realtime'
      and publication_table.schemaname = 'public'
      and publication_table.tablename = 'contacts'
  ) then
    alter publication supabase_realtime add table only public.contacts;
  end if;
end
$$;
