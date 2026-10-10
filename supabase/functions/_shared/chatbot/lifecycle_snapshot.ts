export function lifecycleFresh(
  lastSyncedAt: string | null | undefined,
  now = Date.now(),
) {
  const confirmed = lastSyncedAt ? Date.parse(lastSyncedAt) : NaN;
  return Number.isFinite(confirmed) && confirmed <= now &&
    now - confirmed <= 60_000;
}
