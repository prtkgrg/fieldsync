package dev.prateekgarg.fieldsync.sync;

import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.LongSupplier;

import org.springframework.stereotype.Component;
import tools.jackson.databind.JsonNode;

/**
 * Decides what a mutation does to a record. Pure logic: no I/O, so every rule is unit-tested.
 *
 * <p>Rules:
 * <ul>
 * <li>Per-field merge. A field conflicts only if the server changed it after the device's base version
 * <em>and</em> the device changed it to a different value. Everything else merges.</li>
 * <li>On conflict the server value wins, and the conflict is reported back to the device.</li>
 * <li>Delete wins. Deleting a record beats concurrent edits, and editing a deleted record is a conflict.</li>
 * <li>A record's type never changes.</li>
 * </ul>
 */
@Component
public class MergeEngine {

	/**
	 * @param write  the record to store, or null if nothing changed
	 * @param result what to tell the device
	 */
	public record Outcome(SyncRecord write, MutationResult result) {
	}

	/**
	 * @param current     the stored record, or null if the server has never seen it
	 * @param nextVersion called once, only if the record is written
	 */
	public Outcome merge(SyncRecord current, Mutation m, String deviceId, LongSupplier nextVersion, Instant now) {
		if (current != null && !current.type().equals(m.type())) {
			return noWrite(m, current, MutationStatus.REJECTED, List.of(),
					"Record " + m.recordId() + " is a '" + current.type() + "', not a '" + m.type() + "'");
		}
		return switch (m.op()) {
			case DELETE -> delete(current, m, deviceId, nextVersion, now);
			case UPSERT -> upsert(current, m, deviceId, nextVersion, now);
		};
	}

	private Outcome delete(SyncRecord current, Mutation m, String deviceId, LongSupplier nextVersion, Instant now) {
		if (current != null && current.deleted()) {
			return noWrite(m, current, MutationStatus.APPLIED, List.of(), "Already deleted");
		}
		// Unknown records still get a tombstone: other offline devices may hold a copy.
		long version = nextVersion.getAsLong();
		Map<String, JsonNode> fields = current == null ? Map.of() : current.fields();
		Map<String, Long> fieldVersions = current == null ? Map.of() : current.fieldVersions();
		SyncRecord tombstone = new SyncRecord(m.recordId(), m.type(), fields, fieldVersions, version, true,
				deviceId, now);
		return new Outcome(tombstone, result(m, MutationStatus.APPLIED, version, List.of(), null));
	}

	private Outcome upsert(SyncRecord current, Mutation m, String deviceId, LongSupplier nextVersion, Instant now) {
		if (m.fieldsOrEmpty().isEmpty()) {
			long version = current == null ? 0 : current.version();
			return new Outcome(null, result(m, MutationStatus.REJECTED, version, List.of(), "UPSERT needs at least one field"));
		}
		if (current == null) {
			long version = nextVersion.getAsLong();
			Map<String, Long> fieldVersions = new HashMap<>();
			m.fieldsOrEmpty().keySet().forEach(f -> fieldVersions.put(f, version));
			SyncRecord created = new SyncRecord(m.recordId(), m.type(), Map.copyOf(m.fieldsOrEmpty()), fieldVersions,
					version, false, deviceId, now);
			return new Outcome(created, result(m, MutationStatus.APPLIED, version, List.of(), null));
		}
		if (current.deleted()) {
			var conflict = new FieldConflict(null, null, null, "Record was deleted on the server");
			return noWrite(m, current, MutationStatus.CONFLICT, List.of(conflict), null);
		}

		long base = m.baseVersion() == null ? 0 : m.baseVersion();
		Map<String, JsonNode> fields = new HashMap<>(current.fields());
		Map<String, Long> fieldVersions = new HashMap<>(current.fieldVersions());
		List<String> toApply = new ArrayList<>();
		List<FieldConflict> conflicts = new ArrayList<>();

		m.fieldsOrEmpty().forEach((field, clientValue) -> {
			JsonNode serverValue = current.fields().get(field);
			boolean serverChanged = current.fieldVersions().getOrDefault(field, 0L) > base;
			if (Objects.equals(normalize(serverValue), normalize(clientValue))) {
				return; // both sides already agree
			}
			if (serverChanged) {
				conflicts.add(new FieldConflict(field, clientValue, serverValue, "Changed on the server since version " + base));
			}
			else {
				toApply.add(field);
			}
		});

		MutationStatus status = !conflicts.isEmpty() ? MutationStatus.CONFLICT
				: current.version() > base ? MutationStatus.MERGED : MutationStatus.APPLIED;
		if (toApply.isEmpty()) {
			return noWrite(m, current, status, conflicts, null);
		}

		long version = nextVersion.getAsLong();
		for (String field : toApply) {
			fields.put(field, m.fieldsOrEmpty().get(field));
			fieldVersions.put(field, version);
		}
		SyncRecord updated = new SyncRecord(current.id(), current.type(), fields, fieldVersions, version, false,
				deviceId, now);
		return new Outcome(updated, result(m, status, version, conflicts, null));
	}

	/** Treats a missing field and an explicit JSON null as the same value. */
	private static JsonNode normalize(JsonNode value) {
		return value == null || value.isNull() ? null : value;
	}

	private static Outcome noWrite(Mutation m, SyncRecord current, MutationStatus status, List<FieldConflict> conflicts,
			String message) {
		return new Outcome(null, result(m, status, current.version(), conflicts, message));
	}

	private static MutationResult result(Mutation m, MutationStatus status, long version, List<FieldConflict> conflicts,
			String message) {
		return new MutationResult(m.mutationId(), m.recordId(), status, version, List.copyOf(conflicts), message);
	}

}
