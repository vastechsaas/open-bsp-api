create function public.queue_media_preprocessing_trigger() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.enqueue_media_preprocessing(new.id);
  return new;
end;
$$;
revoke all on function public.queue_media_preprocessing_trigger() from public,anon,authenticated;
