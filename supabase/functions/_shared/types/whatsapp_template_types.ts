import type {
  OutgoingDocument,
  OutgoingImage,
  OutgoingVideo,
} from "./whatsapp_endpoint_types.ts";

// TEMPLATE

// Template data, used to create or update a template message

export type TemplateCategory = "AUTHENTICATION" | "MARKETING" | "UTILITY";

export type TemplateStatus =
  | "APPROVED"
  | "IN_APPEAL"
  | "PENDING"
  | "REJECTED"
  | "PENDING_DELETION"
  | "DELETED"
  | "DISABLED"
  | "PAUSED"
  | "LIMIT_EXCEEDED";

export type TemplateData = {
  id: string;
  name: string;
  status: TemplateStatus;
  category: TemplateCategory;
  language: string;
  components: TemplateComponent[];
  sub_category?: "CUSTOM";
  rejected_reason?: string;
};

export type TemplateDraftInput = Pick<
  TemplateData,
  "name" | "language" | "category" | "components"
>;

export type TextHeaderComponent = {
  type: "HEADER";
  text: string;
  format: "TEXT";
  example?: {
    header_text: [string];
  };
};

export type MediaHeaderFormat = "IMAGE" | "VIDEO" | "DOCUMENT";

export type MediaHeaderComponent = {
  type: "HEADER";
  format: MediaHeaderFormat;
  example?: {
    header_handle: [string];
  };
};

export type HeaderComponent = TextHeaderComponent | MediaHeaderComponent;

export type BodyComponent = {
  type: "BODY";
  text: string;
  example?: {
    body_text: [string[]];
  };
};

export type FooterComponent = {
  type: "FOOTER";
  text: string;
};

export type ButtonsComponent = {
  type: "BUTTONS";
  buttons: TemplateButtonDefinition[];
};

export type QuickReply = {
  type: "QUICK_REPLY";
  text: string;
};

export type UrlButton = {
  type: "URL";
  text: string;
  url: string;
  example?: [string];
};

export type PhoneNumberButton = {
  type: "PHONE_NUMBER";
  text: string;
  phone_number: string;
};

export type TemplateButtonDefinition =
  | QuickReply
  | UrlButton
  | PhoneNumberButton;

export type TemplateComponent =
  | BodyComponent
  | HeaderComponent
  | FooterComponent
  | ButtonsComponent;

// Template message, used to send a template message

type CurrencyParameter = {
  type: "currency";
  currency: {
    fallback_value: string;
    code: string; // ISO 4217
    amount_1000: number;
  };
};

type DateTimeParameter = {
  type: "date_time";
  date_time: {
    fallback_value: string;
    // localization is not attempted by Cloud API, fallback_value is always used
  };
};

type TextParameter = {
  type: "text";
  text: string;
};

type TemplateParameter =
  | CurrencyParameter
  | DateTimeParameter
  | TextParameter
  | OutgoingImage
  | OutgoingVideo
  | OutgoingDocument;

type TemplateHeader = {
  type: "header";
  parameters?: TemplateParameter[];
};

type TemplateBody = {
  type: "body";
  parameters?: TemplateParameter[];
};

type TemplateButton =
  & {
    type: "button";
    index: string; // 0-9
  }
  & (
    | {
      sub_type: "quick_reply";
      parameters: {
        type: "payload";
        payload: string;
      }[];
    }
    | {
      sub_type: "url";
      parameters: {
        type: "text";
        text: string;
      }[];
    }
  );

export type Template = {
  components?: (TemplateHeader | TemplateBody | TemplateButton)[];
  language: {
    code: string; // es, es_AR, etc
    policy: "deterministic";
  };
  name: string;
};

export type TemplateMessage = {
  type: "template";
  template: Template;
};

// TODO: InteractiveMessage
