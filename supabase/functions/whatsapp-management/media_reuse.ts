/** Cache coordinates uploads only; this module never sends a customer message. */
export type MediaCacheClaim =
  | { state: "ready"; media_id: string }
  | { state: "claimed"; lease_token: string }
  | { state: "busy" };

export type MediaReuseDependencies = {
  claim(staleMediaId?: string): Promise<MediaCacheClaim>;
  available(mediaId: string): Promise<boolean>;
  upload(): Promise<string>;
  complete(token: string, mediaId: string): Promise<boolean>;
  release(token: string): Promise<unknown>;
  wait?(): Promise<void>;
};

export function missingMediaReference(
  status: number,
  code?: number,
  subcode?: number,
) {
  return [404, 410].includes(status) ||
    (status === 400 && code === 100 && subcode === 33);
}

export async function reuseCampaignMedia(deps: MediaReuseDependencies) {
  let stale: string | undefined;
  let busyWaits = 0;
  // Bound concurrent replacement races. Backoff remains owned by the campaign job.
  for (let round = 0; round < 3; round++) {
    const claim = await deps.claim(stale);
    if (claim.state === "busy") {
      if (busyWaits++ >= 20) {
        throw new TypeError("Campaign image preparation is busy; retry later");
      }
      await (deps.wait?.() ??
        new Promise((resolve) => setTimeout(resolve, 1000)));
      round--;
      continue;
    }
    if (claim.state === "ready") {
      if (await deps.available(claim.media_id)) return claim.media_id;
      stale = claim.media_id;
      continue;
    }
    try {
      const id = await deps.upload();
      if (!await deps.complete(claim.lease_token, id)) {
        throw new TypeError("Campaign image preparation lease changed");
      }
      return id;
    } catch (error) {
      await deps.release(claim.lease_token).catch(() => undefined);
      throw error;
    }
  }
  throw new TypeError("Campaign image reference changed; retry later");
}
