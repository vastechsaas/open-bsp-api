-- pg_cron job definitions are data: carry this statement into the generated migration.
select cron.schedule('whatsapp-attachment-recovery', '10 seconds',
  'select public.wake_whatsapp_attachment_recovery();');
