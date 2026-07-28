import { z } from "zod";

const uuidSchema = z.string().uuid();
const timestampSchema = z.string().datetime({ offset: true });
const headerNameSchema = z.string().min(1).max(128).regex(
  /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/,
);
const blockedCredentialHeaders = new Set([
  "host",
  "content-length",
  "connection",
  "transfer-encoding",
  "upgrade",
  "proxy-authorization",
  "idempotency-key",
]);

export const editorGraphSchema = z.object({
  nodes: z.array(z.unknown()),
  edges: z.array(z.unknown()),
}).loose();

export const organizationPayloadSchema = z.object({
  organization_id: uuidSchema,
});

export const createFlowPayloadSchema = organizationPayloadSchema.extend({
  name: z.string().trim().min(1),
});

export const duplicateFlowPayloadSchema = createFlowPayloadSchema;

export const renameFlowPayloadSchema = createFlowPayloadSchema;

export const saveDraftPayloadSchema = organizationPayloadSchema.extend({
  version_id: uuidSchema,
  expected_updated_at: timestampSchema,
  editor_graph: editorGraphSchema,
});

export const validateDraftPayloadSchema = organizationPayloadSchema.extend({
  editor_graph: editorGraphSchema,
});

export const simulateFlowPayloadSchema = validateDraftPayloadSchema.extend({
  current_node_id: z.string().trim().min(1).optional(),
  variables: z.record(z.string(), z.unknown()).default({}),
  free_text_input: z.string().max(4096).optional(),
  option_input: z.object({
    kind: z.enum(["button", "list_selection"]),
    id: z.string().trim().min(1).max(128),
  }).strict().optional(),
  webhook_mocks: z.record(
    z.string().trim().min(1).max(128),
    z.object({
      outcome: z.enum(["success", "error"]),
      status_code: z.number().int().min(100).max(599).default(200),
      body: z.unknown().default({}),
    }).strict(),
  ).default({}),
});

export const publishDraftPayloadSchema = organizationPayloadSchema.extend({
  version_id: uuidSchema,
  expected_updated_at: timestampSchema,
});

export const deploymentPayloadSchema = organizationPayloadSchema.extend({
  organization_address: z.string().trim().min(1),
});

export const activateDeploymentPayloadSchema = deploymentPayloadSchema.extend({
  version_id: uuidSchema,
});

export const createWebhookCredentialPayloadSchema = organizationPayloadSchema
  .extend({
    name: z.string().trim().min(1).max(120),
    headers: z.record(headerNameSchema, z.string().max(4096))
      .refine((headers) => Object.keys(headers).length > 0, {
        message: "At least one credential header is required",
      })
      .refine((headers) => Object.keys(headers).length <= 20, {
        message: "No more than 20 credential headers are allowed",
      })
      .refine(
        (headers) =>
          Object.keys(headers).every((name) =>
            !blockedCredentialHeaders.has(name.toLowerCase())
          ),
        { message: "A credential header name is not allowed" },
      ),
  });

export type EditorGraph = z.infer<typeof editorGraphSchema>;
