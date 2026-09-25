package dev.prateekgarg.fieldsync.sync;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

import com.fasterxml.jackson.annotation.JsonIgnore;
import tools.jackson.databind.JsonNode;

/** A record as stored on the server. {@code fieldVersions} stays server-side; clients only need {@code version}. */
public record SyncRecord(
		UUID id,
		String type,
		Map<String, JsonNode> fields,
		@JsonIgnore Map<String, Long> fieldVersions,
		long version,
		boolean deleted,
		String updatedBy,
		Instant updatedAt) {
}
