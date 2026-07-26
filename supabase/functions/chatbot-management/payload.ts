import { z } from "zod";

const uuidSchema = z.string().uuid();
const timestampSchema = z.string().datetime({ offset: true });

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

export const publishDraftPayloadSchema = organizationPayloadSchema.extend({
  version_id: uuidSchema,
  expected_updated_at: timestampSchema,
});

export type EditorGraph = z.infer<typeof editorGraphSchema>;
