-- Cron definitions are row data: db diff does not include them automatically.
-- Append this statement to the generated migration when this definition changes.
select cron.schedule(
  'preprocess-pending-messages',
  '* * * * *',
  'select public.enqueue_pending_media_preprocessing(25);'
);
