/** Configuration diagnostics expose locations and numeric limits, never raw values. */
export interface SchemaIssue {
  readonly code: string;
  readonly path: ReadonlyArray<PropertyKey>;
  readonly message: string;
  readonly maximum?: number | bigint;
  readonly minimum?: number | bigint;
  readonly params?: Record<string, unknown>;
  readonly errors?: ReadonlyArray<ReadonlyArray<SchemaIssue>>;
}

function record(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function at(value: unknown, path: ReadonlyArray<PropertyKey>): unknown {
  for (const key of path) {
    value = Array.isArray(value) && typeof key === "number"
      ? value[key]
      : record(value)[String(key)];
  }
  return value;
}

/** A handoff union has alternative destinations, not two required destinations. */
export function selectedSchemaIssues(
  issues: ReadonlyArray<SchemaIssue>,
  candidate: unknown,
): SchemaIssue[] {
  return issues.flatMap((issue) => {
    if (
      record(candidate).type !== "assign_agent" ||
      issue.code !== "invalid_union" || !issue.errors
    ) return [issue];
    const config = record(record(candidate).config);
    const noDestination = !("agent_id" in config) &&
      !("routing_queue_id" in config);
    const branch = issue.errors["agent_id" in config ? 0 : 1] ?? [];
    return branch.map((child) => ({
      ...child,
      path: noDestination && child.path[0] === "routing_queue_id"
        ? issue.path
        : [...issue.path, ...child.path],
    }));
  });
}

export function nodeConfigurationIssue(
  nodeType: unknown,
  issue: SchemaIssue,
  candidate: unknown,
) {
  const path = issue.path.map((part) =>
    typeof part === "symbol" ? String(part) : part
  );
  const relative = path[0] === "config" ? path.slice(1) : path;
  const field = typeof relative[0] === "string" ? relative[0] : undefined;
  const leaf = relative.at(-1);
  const value = at(candidate, issue.path);
  const missing = value === undefined || value === null ||
    (typeof value === "string" && !value.trim()) ||
    (Array.isArray(value) && !value.length);
  const params: Record<string, number> = {};
  const config = record(record(candidate).config);
  const rowIndex = relative.indexOf("rows");
  const optionIndex = rowIndex >= 0 ? relative[rowIndex + 1] : relative[1];
  const isOption = ["buttons", "options"].includes(field ?? "") ||
    rowIndex >= 0;
  if (isOption && typeof optionIndex === "number") {
    let offset = 0;
    if (rowIndex >= 0 && Array.isArray(config.sections)) {
      offset = config.sections.slice(0, Number(relative[1])).reduce(
        (sum, section) =>
          sum +
          (Array.isArray(record(section).rows)
            ? (record(section).rows as unknown[]).length
            : 0),
        0,
      );
    }
    params.option = optionIndex + offset + 1;
  }
  const make = (code: string, message: string, fieldPath = relative) => ({
    code,
    message,
    ...(fieldPath.length ? { field_path: fieldPath } : {}),
    ...(field ? { field } : {}),
    category: "configuration" as const,
    ...(Object.keys(params).length ? { params } : {}),
  });
  const optionCollection =
    (["buttons", "options", "sections"].includes(field ?? "") &&
      relative.length === 1) || leaf === "rows";
  if (optionCollection && !Array.isArray(value)) {
    return make(
      value == null ? "options_required" : "options_invalid",
      value == null
        ? "Add at least one option"
        : "Options must be a list of valid items",
    );
  }
  if (issue.message === "System variables are read-only") {
    return make("system_variable_read_only", issue.message);
  }
  if (issue.code === "unrecognized_keys") {
    return make("field_invalid", "Remove unsupported configuration fields");
  }
  if (field === "id" || field === "type") {
    return make(`node_${field}_invalid`, `Node ${field} is invalid`);
  }
  if (
    nodeType === "assign_agent" &&
    (!field || field === "agent_id" || field === "routing_queue_id")
  ) {
    const destination = field === "agent_id" ? "agent_id" : "routing_queue_id";
    const absent = !field || missing;
    return {
      ...make(
        destination === "agent_id"
          ? "handoff_agent_invalid"
          : absent
          ? "handoff_queue_required"
          : "handoff_queue_invalid",
        destination === "agent_id"
          ? "Destination agent is invalid"
          : absent
          ? "Destination queue is required"
          : "Destination queue is invalid",
        [destination],
      ),
      field: destination,
    };
  }
  if (issue.params?.rule === "duplicate_option_value") {
    return make("option_value_duplicate", "Option values must be unique");
  }
  if (issue.params?.rule === "duplicate_option_id") {
    return make("option_id_duplicate", "Option IDs must be unique");
  }
  if (issue.params?.rule === "input_length_range") {
    return make(
      "input_length_range_invalid",
      "Maximum length must be at least the minimum length",
    );
  }
  if (issue.params?.rule === "protected_header") {
    return make(
      "webhook_credential_required",
      "Use a protected credential for this header",
      [...relative, "name"],
    );
  }
  if (
    issue.code === "too_big" || issue.params?.rule === "button_title_limit" ||
    issue.params?.rule === "option_count_limit"
  ) {
    params.limit = Number(issue.params?.limit ?? issue.maximum);
    if (!Number.isFinite(params.limit)) delete params.limit;
    params.actual = typeof value === "string" || Array.isArray(value)
      ? value.length
      : typeof value === "number"
      ? value
      : 0;
    if (issue.params?.rule === "option_count_limit") {
      params.actual = Number(issue.params.actual);
    }
    if (isOption && leaf === "title") {
      const buttons = nodeType === "interactive_buttons" ||
        config.render_as_buttons === true;
      // A button-rendered list may also exceed the ordinary list limit. Report the stricter rule once.
      if (buttons) params.limit = 20;
      return make(
        buttons ? "button_title_too_long" : "list_title_too_long",
        `Option ${params.option}: ${
          buttons ? "button" : "list"
        } title exceeds ${params.limit} characters (currently ${params.actual}).`,
      );
    }
    if (Array.isArray(value)) {
      return make(
        "option_count_exceeded",
        `Maximum ${params.limit} items (currently ${params.actual})`,
      );
    }
    return make(
      typeof value === "number" ? "field_above_maximum" : "field_too_long",
      typeof value === "number"
        ? `Value must be at most ${params.limit}`
        : `Maximum ${params.limit} characters (currently ${params.actual})`,
    );
  }
  if (
    (["buttons", "options", "sections"].includes(field ?? "") &&
      relative.length === 1) || leaf === "rows"
  ) {
    return make(
      missing ? "options_required" : "options_invalid",
      missing
        ? "Add at least one option"
        : "Options must be a list of valid items",
    );
  }
  if (isOption && leaf === "id") {
    return make("option_id_invalid", "Enter a valid option ID");
  }
  if (isOption && (leaf === "title" || leaf === "label")) {
    return make(
      missing ? "option_title_required" : "option_title_invalid",
      missing ? "Option title is required" : "Option title must be text",
    );
  }
  if (isOption && leaf === "value") {
    return make(
      missing ? "option_value_required" : "option_value_invalid",
      missing ? "Option value is required" : "Option value must be text",
    );
  }
  if (leaf === "variable") {
    if (nodeType === "condition") {
      return make(
        missing ? "condition_variable_required" : "condition_variable_invalid",
        missing
          ? "Condition variable is required"
          : "Condition variable is invalid",
      );
    }
    return make(
      "input_variable_invalid",
      "Enter a valid writable variable name",
    );
  }
  if (nodeType === "webhook" && field === "url") {
    return make("webhook_url_invalid", "Enter a valid HTTPS URL");
  }
  if (nodeType === "webhook" && field === "secret_id") {
    return make(
      "webhook_credential_invalid",
      "Select a valid webhook credential",
    );
  }
  if (
    nodeType === "webhook" && field === "response_mappings" &&
    relative.includes("format")
  ) {
    return make(
      "webhook_response_format_invalid",
      "Check the list template, separators, empty text and item limit",
    );
  }
  if (missing) {
    if (nodeType === "send_message" && field === "text") {
      return make("message_text_required", "Message text is required");
    }
    if (nodeType === "collect_input" && field === "prompt") {
      return make("input_prompt_required", "Input prompt is required");
    }
    return make("field_required", "This field is required");
  }
  if (issue.code === "too_small" && typeof value === "number") {
    params.limit = Number(issue.minimum);
    return make(
      "field_below_minimum",
      `Value must be at least ${params.limit}`,
    );
  }
  // Do not expose schema messages: custom validators can contain sensitive values.
  return make("field_invalid", "Check this field's value and format");
}
