package dev.prateekgarg.fieldsync.sync;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * Plain SQL through {@link JdbcClient}. Sync needs exact control over locking, ordering and JSONB,
 * which an ORM would hide.
 */
@Repository
public class SyncStore {

	/** Arbitrary constant identifying the push lock among advisory locks. */
	private static final long PUSH_LOCK_KEY = 7_318_001L;

	private static final TypeReference<Map<String, JsonNode>> FIELDS = new TypeReference<>() {
	};

	private static final TypeReference<Map<String, Long>> FIELD_VERSIONS = new TypeReference<>() {
	};

	private final JdbcClient jdbc;

	private final JsonMapper json;

	public SyncStore(JdbcClient jdbc, JsonMapper json) {
		this.jdbc = jdbc;
		this.json = json;
	}

	/**
	 * Serializes pushes until the transaction ends. Versions are then taken and committed in the same order,
	 * so a reader that has seen version N has also seen every version below N.
	 */
	public void lockForPush() {
		jdbc.sql("SELECT pg_advisory_xact_lock(:key)").param("key", PUSH_LOCK_KEY).query((rs, i) -> 1).single();
	}

	public long nextVersion() {
		return jdbc.sql("SELECT nextval('change_seq')").query(Long.class).single();
	}

	public Optional<SyncRecord> find(UUID id) {
		return jdbc.sql("SELECT * FROM records WHERE id = :id").param("id", id).query(this::mapRecord).optional();
	}

	public void save(SyncRecord r) {
		jdbc.sql("""
				INSERT INTO records (id, type, fields, field_versions, version, deleted, updated_by, updated_at)
				VALUES (:id, :type, CAST(:fields AS jsonb), CAST(:fieldVersions AS jsonb), :version, :deleted, :updatedBy, :updatedAt)
				ON CONFLICT (id) DO UPDATE SET
				    fields = EXCLUDED.fields,
				    field_versions = EXCLUDED.field_versions,
				    version = EXCLUDED.version,
				    deleted = EXCLUDED.deleted,
				    updated_by = EXCLUDED.updated_by,
				    updated_at = EXCLUDED.updated_at
				""")
			.param("id", r.id())
			.param("type", r.type())
			.param("fields", json.writeValueAsString(r.fields()))
			.param("fieldVersions", json.writeValueAsString(r.fieldVersions()))
			.param("version", r.version())
			.param("deleted", r.deleted())
			.param("updatedBy", r.updatedBy())
			.param("updatedAt", Timestamp.from(r.updatedAt()))
			.update();
	}

	/** Returns up to {@code limit + 1} changes after {@code cursor}; the extra row tells the caller there is more. */
	public List<SyncRecord> changesSince(long cursor, int limit) {
		return jdbc.sql("SELECT * FROM records WHERE version > :cursor ORDER BY version LIMIT :limit")
			.param("cursor", cursor)
			.param("limit", limit + 1)
			.query(this::mapRecord)
			.list();
	}

	public Optional<MutationResult> findAppliedMutation(UUID mutationId) {
		return jdbc.sql("SELECT result FROM applied_mutations WHERE mutation_id = :id")
			.param("id", mutationId)
			.query((rs, i) -> json.readValue(rs.getString("result"), MutationResult.class))
			.optional();
	}

	public void recordAppliedMutation(String deviceId, MutationResult result) {
		jdbc.sql("""
				INSERT INTO applied_mutations (mutation_id, device_id, record_id, result)
				VALUES (:mutationId, :deviceId, :recordId, CAST(:result AS jsonb))
				""")
			.param("mutationId", result.mutationId())
			.param("deviceId", deviceId)
			.param("recordId", result.recordId())
			.param("result", json.writeValueAsString(result))
			.update();
	}

	public void recordConflict(String deviceId, MutationResult result, FieldConflict conflict) {
		jdbc.sql("""
				INSERT INTO sync_conflicts (mutation_id, record_id, device_id, field, client_value, server_value, reason)
				VALUES (:mutationId, :recordId, :deviceId, :field, CAST(:clientValue AS jsonb), CAST(:serverValue AS jsonb), :reason)
				""")
			.param("mutationId", result.mutationId())
			.param("recordId", result.recordId())
			.param("deviceId", deviceId)
			.param("field", conflict.field())
			.param("clientValue", toJsonOrNull(conflict.clientValue()))
			.param("serverValue", toJsonOrNull(conflict.serverValue()))
			.param("reason", conflict.reason())
			.update();
	}

	private String toJsonOrNull(JsonNode node) {
		return node == null ? null : json.writeValueAsString(node);
	}

	private SyncRecord mapRecord(ResultSet rs, int rowNum) throws SQLException {
		return new SyncRecord(
				rs.getObject("id", UUID.class),
				rs.getString("type"),
				json.readValue(rs.getString("fields"), FIELDS),
				json.readValue(rs.getString("field_versions"), FIELD_VERSIONS),
				rs.getLong("version"),
				rs.getBoolean("deleted"),
				rs.getString("updated_by"),
				rs.getTimestamp("updated_at").toInstant());
	}

}
