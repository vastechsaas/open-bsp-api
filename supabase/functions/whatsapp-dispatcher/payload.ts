import type { FilePart, OutgoingAudio } from "../_shared/supabase.ts";

export function audioFileToEndpointAudio(
  file: FilePart["file"],
): OutgoingAudio["audio"] {
  const mediaReference = file.uri.startsWith("http://") ||
      file.uri.startsWith("https://")
    ? { link: file.uri }
    : { id: file.uri };

  return {
    ...mediaReference,
    ...(file.voice ? { voice: true } : {}),
  };
}
