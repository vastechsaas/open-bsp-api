import { z } from "zod";

export const CHATBOT_TEXT_MAX_LENGTH = 4096;
export const CHATBOT_INPUT_MAX_LENGTH = 4096;
export const CHATBOT_INTERACTIVE_BODY_MAX_LENGTH = 1024;
export const CHATBOT_REPLY_BUTTON_MAX_COUNT = 3;
export const CHATBOT_REPLY_BUTTON_TITLE_MAX_LENGTH = 20;
export const CHATBOT_LIST_BUTTON_TEXT_MAX_LENGTH = 20;
export const CHATBOT_LIST_MAX_ROWS = 10;
export const CHATBOT_LIST_SECTION_TITLE_MAX_LENGTH = 24;
export const CHATBOT_LIST_ROW_TITLE_MAX_LENGTH = 24;
export const CHATBOT_LIST_ROW_DESCRIPTION_MAX_LENGTH = 72;

const stableIdSchema = z.string().min(1).max(128).regex(
  /^[A-Za-z0-9][A-Za-z0-9_-]*$/,
  "Must start with an alphanumeric character and contain only alphanumeric characters, underscores, or hyphens",
);

const variableKeySchema = z.string().min(1).max(64).regex(
  /^[a-z][a-z0-9_]*$/,
  "Must be a lowercase snake_case key",
);

const agentIdSchema = z.string().uuid();

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

const interactiveBodySchema = z.string().min(1).max(
  CHATBOT_INTERACTIVE_BODY_MAX_LENGTH,
).refine((value) => value.trim().length > 0, "Must not be blank");

const replyButtonSchema = z.object({
  id: stableIdSchema,
  title: z.string().min(1).max(CHATBOT_REPLY_BUTTON_TITLE_MAX_LENGTH)
    .refine((value) => value.trim().length > 0, "Must not be blank"),
}).strict();

const interactiveButtonsNodeSchema = z.object({
  id: stableIdSchema,
  type: z.literal("interactive_buttons"),
  config: z.object({
    body: interactiveBodySchema,
    buttons: z.array(replyButtonSchema).min(1).max(
      CHATBOT_REPLY_BUTTON_MAX_COUNT,
    ),
  }).strict(),
}).strict();

const listRowSchema = z.object({
  id: stableIdSchema,
  title: z.string().min(1).max(CHATBOT_LIST_ROW_TITLE_MAX_LENGTH)
    .refine((value) => value.trim().length > 0, "Must not be blank"),
  description: z.string().max(CHATBOT_LIST_ROW_DESCRIPTION_MAX_LENGTH)
    .optional(),
}).strict();

const listSectionSchema = z.object({
  id: stableIdSchema,
  title: z.string().min(1).max(CHATBOT_LIST_SECTION_TITLE_MAX_LENGTH)
    .refine((value) => value.trim().length > 0, "Must not be blank"),
  rows: z.array(listRowSchema).min(1),
}).strict();

const listMessageNodeSchema = z.object({
  id: stableIdSchema,
  type: z.literal("list_message"),
  config: z.object({
    body: interactiveBodySchema,
    button_text: z.string().min(1).max(CHATBOT_LIST_BUTTON_TEXT_MAX_LENGTH)
      .refine((value) => value.trim().length > 0, "Must not be blank"),
    sections: z.array(listSectionSchema).min(1).max(CHATBOT_LIST_MAX_ROWS),
  }).strict().superRefine((config, context) => {
    const rowCount = config.sections.reduce(
      (total, section) => total + section.rows.length,
      0,
    );
    if (rowCount > CHATBOT_LIST_MAX_ROWS) {
      context.addIssue({
        code: "custom",
        path: ["sections"],
        message: `Must contain no more than ${CHATBOT_LIST_MAX_ROWS} rows`,
      });
    }
  }),
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

const assignAgentNodeSchema = z.object({
  id: stableIdSchema,
  type: z.literal("assign_agent"),
  config: z.object({
    agent_id: agentIdSchema,
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
  interactiveButtonsNodeSchema,
  listMessageNodeSchema,
  collectInputNodeSchema,
  conditionNodeSchema,
  assignAgentNodeSchema,
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

const optionEdgeSchema = z.object({
  id: stableIdSchema,
  source: stableIdSchema,
  target: stableIdSchema,
  kind: z.literal("option"),
  option_id: stableIdSchema,
}).strict();

export const flowEdgeV1Schema = z.discriminatedUnion("kind", [
  defaultEdgeSchema,
  conditionEdgeSchema,
  optionEdgeSchema,
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
  option_input: z.object({
    kind: z.enum(["button", "list_selection"]),
    id: stableIdSchema,
  }).strict().optional(),
}).strict();

const defaultRouteSchema = z.object({
  kind: z.literal("default"),
}).strict();

const conditionRouteSchema = z.object({
  kind: z.literal("condition"),
  value: z.string(),
}).strict();

const optionRouteSchema = z.object({
  kind: z.literal("option"),
  option_id: stableIdSchema,
}).strict();

const routeSchema = z.discriminatedUnion("kind", [
  defaultRouteSchema,
  conditionRouteSchema,
  optionRouteSchema,
]);

const variableUpdatesSchema = z.record(variableKeySchema, jsonValueSchema);

const advanceResultSchema = z.object({
  type: z.literal("advance"),
  route: routeSchema,
  variable_updates: variableUpdatesSchema.optional(),
}).strict();

const outgoingTextMessageSchema = z.object({
  type: z.literal("text"),
  text: nonblankTextSchema,
}).strict();

const outgoingInteractiveMessageSchema = z.object({
  type: z.literal("interactive"),
  interactive: z.discriminatedUnion("type", [
    z.object({
      type: z.literal("button"),
      body: z.object({ text: interactiveBodySchema }).strict(),
      action: z.object({
        buttons: z.array(
          z.object({
            type: z.literal("reply"),
            reply: replyButtonSchema,
          }).strict(),
        ).min(1).max(CHATBOT_REPLY_BUTTON_MAX_COUNT),
      }).strict(),
    }).strict(),
    z.object({
      type: z.literal("list"),
      body: z.object({ text: interactiveBodySchema }).strict(),
      action: z.object({
        button: z.string().min(1).max(CHATBOT_LIST_BUTTON_TEXT_MAX_LENGTH),
        sections: z.array(
          z.object({
            title: z.string().min(1).max(
              CHATBOT_LIST_SECTION_TITLE_MAX_LENGTH,
            ),
            rows: z.array(
              z.object({
                id: stableIdSchema,
                title: z.string().min(1).max(CHATBOT_LIST_ROW_TITLE_MAX_LENGTH),
                description: z.string().max(
                  CHATBOT_LIST_ROW_DESCRIPTION_MAX_LENGTH,
                ).optional(),
              }).strict(),
            ).min(1),
          }).strict(),
        ).min(1).max(CHATBOT_LIST_MAX_ROWS),
      }).strict(),
    }).strict(),
  ]),
}).strict();

export const chatbotOutgoingMessageV1Schema = z.discriminatedUnion("type", [
  outgoingTextMessageSchema,
  outgoingInteractiveMessageSchema,
]);

const emitMessageResultSchema = z.object({
  type: z.literal("emit_message"),
  message: chatbotOutgoingMessageV1Schema,
  route: defaultRouteSchema,
}).strict();

const waitForInputResultSchema = z.object({
  type: z.literal("wait_for_input"),
  prompt: nonblankTextSchema.optional(),
  message: outgoingInteractiveMessageSchema.optional(),
  expectation: z.discriminatedUnion("kind", [
    z.object({
      kind: z.literal("free_text"),
      variable: variableKeySchema,
      required: z.boolean(),
      min_length: inputLengthSchema.optional(),
      max_length: inputLengthSchema.optional(),
    }).strict(),
    z.object({
      kind: z.enum(["button", "list_selection"]),
      option_ids: z.array(stableIdSchema).min(1),
    }).strict(),
  ]),
}).strict().superRefine((result, context) => {
  const freeText = result.expectation.kind === "free_text";
  if (result.expectation.kind === "free_text") {
    const expectation = result.expectation;
    if (
      expectation.min_length !== undefined &&
      expectation.max_length !== undefined &&
      expectation.min_length > expectation.max_length
    ) {
      context.addIssue({
        code: "custom",
        path: ["expectation", "max_length"],
        message: "Must be greater than or equal to min_length",
      });
    }
  }
  if (freeText && !result.prompt) {
    context.addIssue({
      code: "custom",
      path: ["prompt"],
      message: "Free-text input requires a prompt",
    });
  }
  if (!freeText && !result.message) {
    context.addIssue({
      code: "custom",
      path: ["message"],
      message: "Option input requires an interactive message",
    });
  }
});

const completeResultSchema = z.object({
  type: z.literal("complete"),
}).strict();

const handoffResultSchema = z.object({
  type: z.literal("handoff"),
  agent_id: agentIdSchema,
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
  handoffResultSchema,
  failResultSchema,
]);

export type FlowNodeV1 = z.infer<typeof flowNodeV1Schema>;
export type StartNodeV1 = z.infer<typeof startNodeSchema>;
export type SendMessageNodeV1 = z.infer<typeof sendMessageNodeSchema>;
export type InteractiveButtonsNodeV1 = z.infer<
  typeof interactiveButtonsNodeSchema
>;
export type ListMessageNodeV1 = z.infer<typeof listMessageNodeSchema>;
export type CollectInputNodeV1 = z.infer<typeof collectInputNodeSchema>;
export type ConditionNodeV1 = z.infer<typeof conditionNodeSchema>;
export type AssignAgentNodeV1 = z.infer<typeof assignAgentNodeSchema>;
export type EndNodeV1 = z.infer<typeof endNodeSchema>;
export type FlowEdgeV1 = z.infer<typeof flowEdgeV1Schema>;
export type ConditionOperatorV1 = z.infer<typeof conditionOperatorV1Schema>;
export type FlowDefinitionV1 = z.infer<typeof flowDefinitionV1Schema>;
export interface ExecutionContextV1 {
  readonly variables: Readonly<Record<string, JsonValue>>;
  readonly free_text_input?: string;
  readonly option_input?: {
    readonly kind: "button" | "list_selection";
    readonly id: string;
  };
}
export type NodeResultV1 = z.infer<typeof nodeResultV1Schema>;
export type ChatbotOutgoingMessageV1 = z.infer<
  typeof chatbotOutgoingMessageV1Schema
>;

export interface NodeStrategy<TNode extends FlowNodeV1 = FlowNodeV1> {
  execute(
    node: Readonly<TNode>,
    context: ExecutionContextV1,
  ): Promise<NodeResultV1>;
}
