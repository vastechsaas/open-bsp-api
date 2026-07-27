import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "../_shared/logger.ts";
import {
  createUnsecureClient,
  type EndpointMessage,
  type EndpointStatus,
  type MessageRow,
  type OutgoingMessage,
  type WebhookPayload,
} from "../_shared/supabase.ts";
import { downloadFromStorage } from "../_shared/media.ts";
import { commitDispatchedMessage } from "../_shared/dispatch.ts";
import { markdownToWhatsApp } from "../_shared/markdown.ts";
import {
  getWhatsAppErrorDetails,
  postPayloadToWhatsAppEndpoint,
  resolveWhatsAppRecipient,
  WHATSAPP_API_VERSION,
  WhatsAppError,
} from "../_shared/whatsapp.ts";

const DEFAULT_ACCESS_TOKEN = Deno.env.get("META_SYSTEM_USER_ACCESS_TOKEN") ||
  "";
const SERVICE_ROLE_KEY = Deno.env.get("EDGE_FUNCTIONS_TOKEN")!;

/** Uploads media to WA servers
 *
 * Allowed MIME types:
 *
 * Audio: up to 16 MB
 * - audio/aac
 * - audio/mp4
 * - audio/mpeg
 * - audio/amr
 * - audio/ogg
 * - audio/opus
 *
 * Documents: up to 100 MB
 * - application/vnd.ms-powerpoint
 * - application/msword
 * - application/vnd.openxmlformats-officedocument.wordprocessingml.document
 * - application/vnd.openxmlformats-officedocument.presentationml.presentation
 * - application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
 * - application/pdf
 * - application/vnd.ms-excel
 * - text/plain
 *
 * Images: up to 5 MB
 * - image/jpeg
 * - image/png
 *
 * Sticker: animated 500 KB / static 100 KB
 * - image/webp
 *
 * Video: up to 16 MB
 * - video/mp4
 * - video/3gpp
 */

// WhatsApp Cloud API file size limits per media type
const WHATSAPP_MAX_FILE_SIZE: Record<string, number> = {
  audio: 16 * 1000 * 1000, // 16 MB
  document: 100 * 1000 * 1000, // 100 MB
  image: 5 * 1000 * 1000, // 5 MB
  sticker: 500 * 1000, // 500 KB (animated), 100 KB static
  video: 16 * 1000 * 1000, // 16 MB
};

function formatSize(bytes: number): string {
  if (bytes < 1000) return `${bytes} B`;
  if (bytes < 1000 * 1000) return `${(bytes / 1000).toFixed(0)} KB`;
  return `${(bytes / (1000 * 1000)).toFixed(1)} MB`;
}
/**
 * Checks if a URI uses an external protocol (http/https)
 */
function isExternalUri(uri: string): boolean {
  return uri.startsWith("http://") || uri.startsWith("https://");
}

async function uploadMediaItem({
  message,
  access_token,
  client,
}: {
  message: MessageRow;
  access_token: string;
  client: SupabaseClient;
}): Promise<MessageRow> {
  if (message.content.type !== "file") {
    return message;
  }

  // Skip upload for external URLs - they will be sent as 'link' instead of 'id'
  if (isExternalUri(message.content.file.uri)) {
    return message;
  }

  let file = await downloadFromStorage(client, message.content.file.uri);

  // Validate file size against WhatsApp limits before uploading
  const kind = message.content.kind;
  const maxSize = WHATSAPP_MAX_FILE_SIZE[kind];

  if (maxSize && file.size > maxSize) {
    log.warn("File exceeds WhatsApp size limit", {
      kind,
      size: file.size,
      limit: maxSize,
    });
    throw new WhatsAppError(
      `File too large for WhatsApp: ${formatSize(file.size)} (limit: ${
        formatSize(maxSize)
      } for ${kind})`,
    );
  }

  let mime_type = message.content.file.mime_type;

  // make WA accept text/csv
  if (mime_type.startsWith("text/")) {
    mime_type = "text/plain";
    file = new Blob([file], { type: "text/plain" });
  }

  const formData = new FormData();
  formData.append("file", file);
  formData.append("type", mime_type);
  formData.append("messaging_product", "whatsapp");

  const phone_number_id = message.organization_address;

  const response = await fetch(
    `https://graph.facebook.com/${WHATSAPP_API_VERSION}/${phone_number_id}/media`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${access_token}` },
      body: formData,
    },
  );

  if (!response.ok) {
    throw new WhatsAppError(
      "Could not upload media item to WhatsApp servers",
      await response.json().catch(() => ({})),
    );
  }

  const mediaMetadata = (await response.json()) as { id: string };

  message.content.file.uri = mediaMetadata.id;

  return message;
}

function outgoingMessageToEndpointMessage({
  content,
  to,
  recipient,
}: {
  content: OutgoingMessage;
  to?: string;
  recipient?: string;
}): EndpointMessage {
  const baseMessage = {
    messaging_product: "whatsapp" as const,
    recipient_type: "individual" as const,
    // Send both identifiers; whichever is undefined is dropped by JSON.stringify.
    // If both are present, WhatsApp uses `to` (the phone number) and ignores
    // `recipient` (the BSUID).
    to,
    recipient,
    ...(content.kind !== "reaction" && // From the docs: You cannot send a reaction message as a contextual reply.
        content.re_message_id &&
        !content.forwarded
      ? { context: { message_id: content.re_message_id } }
      : {}),
  };

  switch (content.kind) {
    case "text": {
      return {
        ...baseMessage,
        type: "text",
        text: {
          body: markdownToWhatsApp(content.text),
        },
      };
    }
    case "reaction": {
      return {
        ...baseMessage,
        type: "reaction",
        reaction: {
          emoji: content.text,
          message_id: content.re_message_id!,
        },
      };
    }
    case "audio": {
      const mediaRef = isExternalUri(content.file.uri)
        ? { link: content.file.uri }
        : { id: content.file.uri };
      return {
        ...baseMessage,
        type: "audio",
        audio: mediaRef,
      };
    }
    case "image": {
      const mediaRef = isExternalUri(content.file.uri)
        ? {
          link: content.file.uri,
          caption: content.text ? markdownToWhatsApp(content.text) : undefined,
        }
        : {
          id: content.file.uri,
          caption: content.text ? markdownToWhatsApp(content.text) : undefined,
        };
      return {
        ...baseMessage,
        type: "image",
        image: mediaRef,
      };
    }
    case "video": {
      const mediaRef = isExternalUri(content.file.uri)
        ? {
          link: content.file.uri,
          caption: content.text ? markdownToWhatsApp(content.text) : undefined,
        }
        : {
          id: content.file.uri,
          caption: content.text ? markdownToWhatsApp(content.text) : undefined,
        };
      return {
        ...baseMessage,
        type: "video",
        video: mediaRef,
      };
    }
    case "sticker": {
      const mediaRef = isExternalUri(content.file.uri)
        ? { link: content.file.uri }
        : { id: content.file.uri };
      return {
        ...baseMessage,
        type: "sticker",
        sticker: mediaRef,
      };
    }
    case "document": {
      const mediaRef = isExternalUri(content.file.uri)
        ? {
          link: content.file.uri,
          caption: content.text ? markdownToWhatsApp(content.text) : undefined,
          filename: content.file.name,
        }
        : {
          id: content.file.uri,
          caption: content.text ? markdownToWhatsApp(content.text) : undefined,
          filename: content.file.name,
        };
      return {
        ...baseMessage,
        type: "document",
        document: mediaRef,
      };
    }
    case "contacts": {
      return {
        ...baseMessage,
        type: "contacts",
        contacts: content.data,
      };
    }
    case "location": {
      return {
        ...baseMessage,
        type: "location",
        location: content.data,
      };
    }
    case "template": {
      return {
        ...baseMessage,
        type: "template",
        template: content.data,
      };
    }
    case "interactive": {
      return {
        ...baseMessage,
        type: "interactive",
        interactive: content.data,
      };
    }
    default: {
      throw new Error(
        `Cannot convert outgoing message of type ${content.type} and kind ${content.kind}`,
      );
    }
  }
}

Deno.serve(async (req) => {
  const authHeader = req.headers.get("Authorization");
  const token = authHeader?.replace("Bearer ", "");

  if (token !== SERVICE_ROLE_KEY) {
    return new Response("Unauthorized", { status: 401 });
  }

  const client = createUnsecureClient();

  const message = ((await req.json()) as WebhookPayload<MessageRow>).record!;

  log.info(`Dispatching message ${message.id}`, message);

  if (!message.contact_address) {
    throw new Error(
      `Cannot dispatch message with id ${message.id} because contact_address is missing`,
    );
  }

  const { data: account } = await client
    .from("organizations_addresses")
    .select("extra->>access_token")
    .eq("organization_id", message.organization_id)
    .eq("address", message.organization_address)
    .single()
    .throwOnError();

  const access_token = account.access_token || DEFAULT_ACCESS_TOKEN;

  const { to, recipient } = await resolveWhatsAppRecipient({
    client,
    organizationId: message.organization_id,
    contactAddress: message.contact_address,
  });

  if (message.direction === "outgoing") {
    try {
      const patchedMessage = await uploadMediaItem({
        message,
        access_token,
        client,
      });

      const payload = await outgoingMessageToEndpointMessage({
        content: patchedMessage.content as OutgoingMessage,
        to,
        recipient,
      });

      const response = await postPayloadToWhatsAppEndpoint({
        payload,
        phoneNumberId: message.organization_address,
        accessToken: access_token,
      });

      await commitDispatchedMessage({
        client,
        messageId: message.id,
        externalId: response.messages[0].id,
        status: {
          [response.messages[0].message_status || "accepted"]: new Date()
            .toISOString(),
        },
      });
    } catch (error) {
      const { errorDetail, errorMessage, isRetryable, metaCode } =
        getWhatsAppErrorDetails(error);

      if (isRetryable) {
        // Transient: record the error for user visibility but keep retryable (no "failed" key).
        // The merge_update trigger overwrites the errors array on each retry.
        log.warn("Dispatch failed (transient, will retry)", {
          message_id: message.id,
          code: metaCode,
          error: errorMessage,
        });

        await client
          .from("messages")
          .update({ status: { errors: [errorDetail] } })
          .eq("id", message.id)
          .throwOnError();

        // Rethrow so the function returns 500 and the cron retries.
        throw error;
      }

      // Permanent: mark as failed to stop retries.
      log.error("Dispatch failed (permanent)", {
        message_id: message.id,
        code: metaCode,
        error: errorMessage,
      });

      await client
        .from("messages")
        .update({
          status: {
            failed: new Date().toISOString(),
            errors: [errorDetail],
          },
        })
        .eq("id", message.id)
        .throwOnError();
    }
  } else if (message.direction === "incoming") {
    let readReceipt = false;
    let typingIndicator = false;

    if (
      message.status.read &&
      Date.now() - +new Date(message.status.read) <= 60 * 1000
    ) {
      readReceipt = true;
    }

    if (
      message.status.typing &&
      Date.now() - +new Date(message.status.typing) <= 60 * 1000
    ) {
      typingIndicator = true;
    }

    log.info(
      `read receipt: ${readReceipt}, typing indicator: ${typingIndicator}`,
    );

    if (!readReceipt && !typingIndicator) {
      return new Response();
    }

    if (!message.external_id) {
      throw new Error(
        `Cannot mark message with id ${message.id} as read because its external_id is missing.`,
      );
    }

    const payload: EndpointStatus = {
      messaging_product: "whatsapp",
      status: "read",
      message_id: message.external_id,
      ...(typingIndicator && {
        typing_indicator: {
          type: "text",
        },
      }),
    };

    await postPayloadToWhatsAppEndpoint({
      payload,
      phoneNumberId: message.organization_address,
      accessToken: access_token,
    });
  } else {
    throw new Error(
      `Cannot dispatch message with id ${message.id} because its direction is not 'outgoing' nor 'incoming'.`,
    );
  }

  return new Response();
});
