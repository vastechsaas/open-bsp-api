import { HTTPException } from "jsr:@hono/hono/http-exception";
import type { ContentfulStatusCode } from "jsr:@hono/hono/utils/http-status";
import type {
  MediaHeaderFormat,
  TemplateDraftInput,
} from "./types/whatsapp_template_types.ts";
import type { WhatsAppOrganizationAddressExtra } from "./types/extra_types.ts";

export const META_GRAPH_API_VERSION = "v24.0";

const MEDIA_RULES: Record<
  MediaHeaderFormat,
  {
    types: ReadonlySet<string>;
    extensions: ReadonlySet<string>;
    maxSize: number;
  }
> = {
  IMAGE: {
    types: new Set(["image/jpeg", "image/png"]),
    extensions: new Set(["jpg", "jpeg", "png"]),
    maxSize: 5 * 1024 * 1024,
  },
  VIDEO: {
    types: new Set(["video/mp4"]),
    extensions: new Set(["mp4"]),
    maxSize: 16 * 1024 * 1024,
  },
  DOCUMENT: {
    types: new Set(["application/pdf"]),
    extensions: new Set(["pdf"]),
    maxSize: 50 * 1024 * 1024,
  },
};

function mediaLabel(format: MediaHeaderFormat) {
  return format === "DOCUMENT" ? "PDF document" : format.toLowerCase();
}

export function getTemplateMediaHeaderFormat(
  template: TemplateDraftInput,
): MediaHeaderFormat | null {
  const header = template.components.find((component) =>
    component.type === "HEADER"
  );
  if (!header || header.format === "TEXT") return null;
  return header.format;
}

export function validateTemplateMediaSample(
  file: File | undefined,
  format: MediaHeaderFormat,
): File {
  if (!file || file.size === 0) {
    throw new HTTPException(400, {
      message: `A ${mediaLabel(format)} sample is required before submission`,
    });
  }

  const rule = MEDIA_RULES[format];
  const extension = file.name.toLowerCase().split(".").pop() || "";
  if (!rule.types.has(file.type) || !rule.extensions.has(extension)) {
    throw new HTTPException(400, {
      message: format === "IMAGE"
        ? "Template image must be a JPEG or PNG file"
        : format === "VIDEO"
        ? "Template video must be an MP4 file"
        : "Template document must be a PDF file",
    });
  }
  if (file.size > rule.maxSize) {
    throw new HTTPException(400, {
      message: `Template ${mediaLabel(format)} must be ${
        {
          IMAGE: 5,
          VIDEO: 16,
          DOCUMENT: 50,
        }[format]
      } MB or smaller`,
    });
  }

  return file;
}

export function resolveMetaApplicationId(
  extra: WhatsAppOrganizationAddressExtra,
) {
  if (extra.application_id) return extra.application_id;

  const applicationIds = (Deno.env.get("META_APP_ID") || "")
    .split("|")
    .filter(Boolean);
  if (applicationIds.length === 1) return applicationIds[0];

  throw new HTTPException(409, {
    message:
      "Cannot identify the Meta application for this integration. Reconnect the WhatsApp account before uploading media.",
  });
}

async function readMetaJson<T>(
  response: Response,
  message: string,
): Promise<T> {
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new HTTPException(response.status as ContentfulStatusCode, {
      message,
      cause: body,
    });
  }
  return body as T;
}

export async function uploadMetaResumableMedia(
  applicationId: string,
  accessToken: string,
  file: File,
): Promise<string> {
  const sessionUrl = new URL(
    `https://graph.facebook.com/${META_GRAPH_API_VERSION}/${applicationId}/uploads`,
  );
  sessionUrl.searchParams.set("file_name", file.name);
  sessionUrl.searchParams.set("file_length", String(file.size));
  sessionUrl.searchParams.set("file_type", file.type);

  const sessionResponse = await fetch(sessionUrl, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const session = await readMetaJson<{ id: string }>(
    sessionResponse,
    "Could not create the Meta media upload session",
  );

  const uploadResponse = await fetch(
    `https://graph.facebook.com/${META_GRAPH_API_VERSION}/${session.id}`,
    {
      method: "POST",
      headers: {
        Authorization: `OAuth ${accessToken}`,
        file_offset: "0",
        "Content-Type": "application/octet-stream",
      },
      body: await file.arrayBuffer(),
    },
  );
  const upload = await readMetaJson<{ h: string }>(
    uploadResponse,
    "Could not upload the template media sample",
  );
  if (!upload.h) {
    throw new HTTPException(502, {
      message: "Meta did not return a media upload handle",
    });
  }
  return upload.h;
}

export function withTemplateMediaHandle(
  template: TemplateDraftInput,
  handle: string,
): TemplateDraftInput {
  return {
    ...template,
    components: template.components.map((component) => {
      if (component.type !== "HEADER" || component.format === "TEXT") {
        return component;
      }
      return {
        type: "HEADER" as const,
        format: component.format,
        example: { header_handle: [handle] as [string] },
      };
    }),
  };
}

export function stripTemplateMediaHandles<T extends TemplateDraftInput>(
  template: T,
): T {
  return {
    ...template,
    components: template.components.map((component) => {
      if (
        component.type !== "HEADER" ||
        !["IMAGE", "VIDEO", "DOCUMENT"].includes(component.format)
      ) {
        return component;
      }
      return { type: "HEADER" as const, format: component.format };
    }),
  };
}
