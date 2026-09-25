package dev.prateekgarg.fieldsync.sync;

import tools.jackson.databind.JsonNode;

/** A field both sides changed. {@code field} is null when the whole record conflicted (e.g. edit after delete). */
public record FieldConflict(String field, JsonNode clientValue, JsonNode serverValue, String reason) {
}
