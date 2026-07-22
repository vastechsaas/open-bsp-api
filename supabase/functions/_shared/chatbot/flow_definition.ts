import { z } from "zod";

export const CHATBOT_TEXT_MAX_LENGTH = 4096;
export const CHATBOT_INPUT_MAX_LENGTH = 4096;

const stableIdSchema = z.string().min(1).max(128).regex(
  /^[A-Za-z0-9][A-Za-z0-9_-]*$/,
  "Must start with an alphanumeric character and contain only alphanumeric characters, underscores, or hyphens",
);

const variableKeySchema = z.string().min(1).max(64).regex(
  /^[a-z][a-z0-9_]*$/,
  "Must be a lowercase snake_case key",
);

const nonblankTextSchema = z.string().min(1).max(CHATBOT_TEXT_MAX_LENGTH)
  .refine((value) => value.trim().length > 0, "Must not be blank");

const emptyConfigSchema = z.object({}).strict();

const startNodeSchema = z.object({
  id: stableIdSchema,
  type: z.literal("start"),
  config: emptyConfigSchema,
}).strict();

const sendMessageNodeSchema = z.object({
  id: stableIdSchema,
  type: z.literal("send_message"),
  config: z.object({
    text: nonblankTextSchema,
  }).strict(),
}).strict();

const inputLengthSchema = z.number().int().min(0).max(
  CHATBOT_INPUT_MAX_LENGTH,
);

const collectInputConfigSchema = z.object({
  prompt: nonblankTextSchema,
  variable: variableKeySchema,
  required: z.boolean(),
  min_length: inputLengthSchema.optional(),
  max_length: inputLengthSchema.optional(),
}).strict().superRefine((config, context) => {
  if (
    config.min_length !== undefined && config.max_length !== undefined &&
    config.min_length > config.max_length
  ) {
    context.addIssue({
      code: "custom",
      path: ["max_length"],
      message: "Must be greater than or equal to min_length",
    });
  }
});

const collectInputNodeSchema = z.object({
  id: stableIdSchema,
  type: z.literal("collect_input"),
  config: collectInputConfigSchema,
}).strict();

const conditionNodeSchema = z.object({
  id: stableIdSchema,
  type: z.literal("condition"),
  config: z.object({
    variable: variableKeySchema,
  }).strict(),
}).strict();

const endNodeSchema = z.object({
  id: stableIdSchema,
  type: z.literal("end"),
  config: emptyConfigSchema,
}).strict();

export const flowNodeV1Schema = z.discriminatedUnion("type", [
  startNodeSchema,
  sendMessageNodeSchema,
  collectInputNodeSchema,
  conditionNodeSchema,
  endNodeSchema,
]);

export const conditionOperatorV1Schema = z.enum([
  "equals",
  "not_equals",
  "contains",
  "starts_with",
  "ends_with",
]);

const defaultEdgeSchema = z.object({
  id: stableIdSchema,
  source: stableIdSchema,
  target: stableIdSchema,
  kind: z.literal("default"),
}).strict();

const conditionEdgeSchema = z.object({
  id: stableIdSchema,
  source: stableIdSchema,
  target: stableIdSchema,
  kind: z.literal("condition"),
  operator: conditionOperatorV1Schema,
  value: z.string(),
}).strict();

export const flowEdgeV1Schema = z.discriminatedUnion("kind", [
  defaultEdgeSchema,
  conditionEdgeSchema,
]);

export const flowDefinitionV1Schema = z.object({
  schema_version: z.literal(1),
  start_node_id: stableIdSchema,
  nodes: z.array(flowNodeV1Schema).min(1),
  edges: z.array(flowEdgeV1Schema),
}).strict();

export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [key: string]: JsonValue };

export const jsonValueSchema: z.ZodType<JsonValue> = z.lazy(() =>
  z.union([
    z.null(),
    z.boolean(),
    z.number(),
    z.string(),
    z.array(jsonValueSchema),
    z.record(z.string(), jsonValueSchema),
  ])
);

export const executionContextV1Schema = z.object({
  variables: z.record(variableKeySchema, jsonValueSchema),
  free_text_input: z.string().optional(),
}).strict();

const defaultRouteSchema = z.object({
  kind: z.literal("default"),
}).strict();

const conditionRouteSchema = z.object({
  kind: z.literal("condition"),
  value: z.string(),
}).strict();

const routeSchema = z.discriminatedUnion("kind", [
  defaultRouteSchema,
  conditionRouteSchema,
]);

const variableUpdatesSchema = z.record(variableKeySchema, jsonValueSchema);

const advanceResultSchema = z.object({
  type: z.literal("advance"),
  route: routeSchema,
  variable_updates: variableUpdatesSchema.optional(),
}).strict();

const emitMessageResultSchema = z.object({
  type: z.literal("emit_message"),
  message: z.object({
    type: z.literal("text"),
    text: nonblankTextSchema,
  }).strict(),
  route: defaultRouteSchema,
}).strict();

const waitForInputResultSchema = z.object({
  type: z.literal("wait_for_input"),
  prompt: nonblankTextSchema,
  expectation: z.object({
    kind: z.literal("free_text"),
    variable: variableKeySchema,
    required: z.boolean(),
    min_length: inputLengthSchema.optional(),
    max_length: inputLengthSchema.optional(),
  }).strict().superRefine((expectation, context) => {
    if (
      expectation.min_length !== undefined &&
      expectation.max_length !== undefined &&
      expectation.min_length > expectation.max_length
    ) {
      context.addIssue({
        code: "custom",
        path: ["max_length"],
        message: "Must be greater than or equal to min_length",
      });
    }
  }),
}).strict();

const completeResultSchema = z.object({
  type: z.literal("complete"),
}).strict();

const failResultSchema = z.object({
  type: z.literal("fail"),
  code: stableIdSchema,
  message: nonblankTextSchema,
  details: z.record(z.string(), jsonValueSchema).optional(),
}).strict();

export const nodeResultV1Schema = z.discriminatedUnion("type", [
  advanceResultSchema,
  emitMessageResultSchema,
  waitForInputResultSchema,
  completeResultSchema,
  failResultSchema,
]);

export type FlowNodeV1 = z.infer<typeof flowNodeV1Schema>;
export type StartNodeV1 = z.infer<typeof startNodeSchema>;
export type SendMessageNodeV1 = z.infer<typeof sendMessageNodeSchema>;
export type CollectInputNodeV1 = z.infer<typeof collectInputNodeSchema>;
export type ConditionNodeV1 = z.infer<typeof conditionNodeSchema>;
export type EndNodeV1 = z.infer<typeof endNodeSchema>;
export type FlowEdgeV1 = z.infer<typeof flowEdgeV1Schema>;
export type ConditionOperatorV1 = z.infer<typeof conditionOperatorV1Schema>;
export type FlowDefinitionV1 = z.infer<typeof flowDefinitionV1Schema>;
export interface ExecutionContextV1 {
  readonly variables: Readonly<Record<string, JsonValue>>;
  readonly free_text_input?: string;
}
export type NodeResultV1 = z.infer<typeof nodeResultV1Schema>;

export interface NodeStrategy<TNode extends FlowNodeV1 = FlowNodeV1> {
  execute(
    node: Readonly<TNode>,
    context: ExecutionContextV1,
  ): Promise<NodeResultV1>;
}
