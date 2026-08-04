import type {
  ContactsMessage,
  LocationMessage,
} from "./whatsapp_webhook_message_types.ts";
import type { TemplateMessage } from "./whatsapp_template_types.ts";

//===================================
// Outgoing message components, as sent to the WhatsApp Cloud API
//===================================

export type OutgoingContextInfo = {
  context?: { message_id: string };
};

// Text based

export type OutgoingText = {
  type: "text";
  text: {
    body: string;
    preview_url?: boolean;
  };
};

export type OutgoingReaction = {
  type: "reaction";
  reaction: {
    emoji: string;
    message_id: string;
  };
};

export type OutgoingInteractiveHeader =
  | { type: "text"; text: string }
  | { type: "image"; image: { id: string } | { link: string } }
  | { type: "video"; video: { id: string } | { link: string } }
  | {
    type: "document";
    document: ({ id: string } | { link: string }) & { filename?: string };
  };

export type OutgoingInteractiveBody = { text: string };

export type OutgoingInteractiveFooter = { text: string };

export type WhatsAppJsonValue =
  | null
  | boolean
  | number
  | string
  | WhatsAppJsonValue[]
  | { [key: string]: WhatsAppJsonValue | undefined };

type OutgoingInteractiveCommon = {
  header?: OutgoingInteractiveHeader;
  body?: OutgoingInteractiveBody;
  footer?: OutgoingInteractiveFooter;
};

type OutgoingInteractiveFlowIdentity =
  | { flow_id: string; flow_name?: never }
  | { flow_id?: never; flow_name: string };

export type OutgoingInteractive = {
  type: "interactive";
  interactive:
    | OutgoingInteractiveCommon & {
      type: "button";
      body: OutgoingInteractiveBody;
      action: {
        buttons: Array<{
          type: "reply";
          reply: { id: string; title: string };
        }>;
      };
    }
    | Omit<OutgoingInteractiveCommon, "header"> & {
      type: "list";
      header?: Extract<OutgoingInteractiveHeader, { type: "text" }>;
      body: OutgoingInteractiveBody;
      action: {
        button: string;
        sections: Array<{
          title: string;
          rows: Array<{
            id: string;
            title: string;
            description?: string;
          }>;
        }>;
      };
    }
    | Omit<OutgoingInteractiveCommon, "header"> & {
      type: "product";
      action: {
        catalog_id: string;
        product_retailer_id: string;
      };
    }
    | Omit<OutgoingInteractiveCommon, "header"> & {
      type: "product_list";
      header: Extract<OutgoingInteractiveHeader, { type: "text" }>;
      body: OutgoingInteractiveBody;
      action: {
        catalog_id: string;
        sections: Array<{
          title: string;
          product_items: Array<{ product_retailer_id: string }>;
        }>;
      };
    }
    | Omit<OutgoingInteractiveCommon, "header"> & {
      type: "catalog_message";
      body: OutgoingInteractiveBody;
      action: {
        name: "catalog_message";
        parameters?: { thumbnail_product_retailer_id?: string };
      };
    }
    | Omit<OutgoingInteractiveCommon, "header" | "footer"> & {
      type: "location_request_message";
      body: OutgoingInteractiveBody;
      action: { name: "send_location" };
    }
    | OutgoingInteractiveCommon & {
      type: "flow";
      body: OutgoingInteractiveBody;
      action: {
        name: "flow";
        parameters:
          & OutgoingInteractiveFlowIdentity
          & {
            flow_message_version: string;
            flow_token: string;
            flow_cta: string;
            flow_action?: "navigate" | "data_exchange";
            flow_action_payload?: {
              screen?: string;
              data?: { [key: string]: WhatsAppJsonValue | undefined };
            };
          };
      };
    };
};

// File based

export type OutgoingAudio = {
  type: "audio";
  audio: ({ id: string } | { link: string }) & { voice?: boolean };
};

export type OutgoingImage = {
  type: "image";
  image: ({ id: string } | { link: string }) & { caption?: string };
};

export type OutgoingVideo = {
  type: "video";
  video: ({ id: string } | { link: string }) & { caption?: string };
};

export type OutgoingDocument = {
  type: "document";
  document: ({ id: string } | { link: string }) & {
    caption?: string;
    filename?: string;
  };
};

export type OutgoingSticker = {
  type: "sticker";
  sticker: { id: string } | { link: string };
};

//===================================
// Endpoint message, as sent to the WhatsApp endpoint
//===================================

// Message format sent to the WhatsApp endpoint
// https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages
export type EndpointMessage =
  & {
    biz_opaque_callback_data?: string;
    messaging_product: "whatsapp";
    recipient_type?: "individual";
    to?: string; // phone number; omitted when messaging a BSUID only
    recipient?: string; // BSUID (or parent BSUID); takes a back seat to `to`
  }
  & OutgoingContextInfo
  & (
    | OutgoingAudio
    | ContactsMessage
    | OutgoingDocument
    | OutgoingImage
    | OutgoingInteractive
    | LocationMessage
    | OutgoingReaction
    | OutgoingSticker
    | TemplateMessage
    | OutgoingText
    | OutgoingVideo
  );

export type EndpointMessageResponse = {
  messaging_product: "whatsapp";
  contacts: [
    {
      input: string;
      wa_id: string;
    },
  ];
  messages: [
    {
      id: string;
      group_id?: string;
      message_status?: "accepted" | "held_for_quality_assessment";
    },
  ];
};
