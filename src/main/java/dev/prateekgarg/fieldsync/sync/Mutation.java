package dev.prateekgarg.fieldsync.sync;

import java.util.Map;
import java.util.UUID;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import tools.jackson.databind.JsonNode;

/**
 * One offline change recorded on a device.
 *
 * @param mutationId  generated on the device; makes retries idempotent
 * @param recordId    generated on the device, so records can be created offline
 * @param baseVersion the record version the device last saw, or null if it never saw the record
 * @param fields      the fields the device changed (UPSERT only); a JSON null clears a field
 */
public record Mutation(
		@NotNull UUID mutationId,
		@NotNull UUID recordId,
		@NotBlank String type,
		@NotNull Operation op,
		@PositiveOrZero Long baseVersion,
		Map<String, JsonNode> fields) {

	public Map<String, JsonNode> fieldsOrEmpty() {
		return fields == null ? Map.of() : fields;
	}
}
