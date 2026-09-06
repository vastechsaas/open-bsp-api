import { assertEquals } from "jsr:@std/assert";
import { audioFileToEndpointAudio } from "./payload.ts";

Deno.test("voice recordings retain their WhatsApp voice-note marker", () => {
  assertEquals(
    audioFileToEndpointAudio({
      uri: "media-id",
      mime_type: "audio/ogg; codecs=opus",
      size: 1024,
      voice: true,
    }),
    { id: "media-id", voice: true },
  );
});

Deno.test("ordinary audio remains a generic attachment", () => {
  assertEquals(
    audioFileToEndpointAudio({
      uri: "https://example.com/audio.mp3",
      mime_type: "audio/mpeg",
      size: 2048,
    }),
    { link: "https://example.com/audio.mp3" },
  );
});
