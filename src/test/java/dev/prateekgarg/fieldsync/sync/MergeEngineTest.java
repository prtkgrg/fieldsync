package dev.prateekgarg.fieldsync.sync;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.JsonNodeFactory;

import static org.assertj.core.api.Assertions.assertThat;

class MergeEngineTest {

	private static final JsonNodeFactory NODES = JsonNodeFactory.instance;

	private static final Instant NOW = Instant.parse("2026-09-26T10:00:00Z");

	private static final UUID RECORD = UUID.fromString("00000000-0000-0000-0000-000000000001");

	private final MergeEngine engine = new MergeEngine();

	private final AtomicLong seq = new AtomicLong(100);

	@Test
	void createsUnknownRecord() {
		var outcome = merge(null, upsert(null, Map.of("name", text("Asha"), "village", text("Rampur"))));

		assertThat(outcome.result().status()).isEqualTo(MutationStatus.APPLIED);
		assertThat(outcome.write().version()).isEqualTo(101);
		assertThat(outcome.write().fields()).containsEntry("name", text("Asha"));
		assertThat(outcome.write().fieldVersions()).containsEntry("name", 101L).containsEntry("village", 101L);
	}

	@Test
	void appliesWhenDeviceWasUpToDate() {
		var current = stored(Map.of("name", text("Asha")), Map.of("name", 5L), 5);

		var outcome = merge(current, upsert(5L, Map.of("name", text("Asha Devi"))));

		assertThat(outcome.result().status()).isEqualTo(MutationStatus.APPLIED);
		assertThat(outcome.write().fields()).containsEntry("name", text("Asha Devi"));
		assertThat(outcome.write().fieldVersions()).containsEntry("name", 101L);
	}

	@Test
	void mergesConcurrentEditsToDifferentFields() {
		// Server changed "village" at v7; the device, based on v5, changed "name".
		var current = stored(Map.of("name", text("Asha"), "village", text("Sonpur")), Map.of("name", 5L, "village", 7L), 7);

		var outcome = merge(current, upsert(5L, Map.of("name", text("Asha Devi"))));

		assertThat(outcome.result().status()).isEqualTo(MutationStatus.MERGED);
		assertThat(outcome.result().conflicts()).isEmpty();
		assertThat(outcome.write().fields()).containsEntry("name", text("Asha Devi")).containsEntry("village", text("Sonpur"));
	}

	@Test
	void serverWinsWhenBothChangedTheSameField() {
		var current = stored(Map.of("name", text("Asha K")), Map.of("name", 7L), 7);

		var outcome = merge(current, upsert(5L, Map.of("name", text("Asha Devi"))));

		assertThat(outcome.result().status()).isEqualTo(MutationStatus.CONFLICT);
		assertThat(outcome.write()).as("nothing left to apply").isNull();
		assertThat(outcome.result().version()).isEqualTo(7);
		assertThat(outcome.result().conflicts()).singleElement().satisfies(c -> {
			assertThat(c.field()).isEqualTo("name");
			assertThat(c.clientValue()).isEqualTo(text("Asha Devi"));
			assertThat(c.serverValue()).isEqualTo(text("Asha K"));
		});
	}

	@Test
	void appliesNonConflictingFieldsAlongsideAConflict() {
		var current = stored(Map.of("name", text("Asha K"), "age", NODES.numberNode(30)), Map.of("name", 7L, "age", 5L), 7);

		var outcome = merge(current, upsert(5L, Map.of("name", text("Asha Devi"), "age", NODES.numberNode(31))));

		assertThat(outcome.result().status()).isEqualTo(MutationStatus.CONFLICT);
		assertThat(outcome.write().fields()).containsEntry("name", text("Asha K")).containsEntry("age", NODES.numberNode(31));
		assertThat(outcome.result().conflicts()).extracting(FieldConflict::field).containsExactly("name");
	}

	@Test
	void identicalConcurrentEditsAreNotAConflict() {
		var current = stored(Map.of("name", text("Asha Devi")), Map.of("name", 7L), 7);

		var outcome = merge(current, upsert(5L, Map.of("name", text("Asha Devi"))));

		assertThat(outcome.result().conflicts()).isEmpty();
		assertThat(outcome.write()).as("nothing changed").isNull();
	}

	@Test
	void jsonNullClearsAField() {
		var current = stored(Map.of("phone", text("98765")), Map.of("phone", 5L), 5);
		Map<String, JsonNode> fields = new HashMap<>();
		fields.put("phone", NODES.nullNode());

		var outcome = merge(current, upsert(5L, fields));

		assertThat(outcome.write().fields().get("phone").isNull()).isTrue();
	}

	@Test
	void deleteWinsOverConcurrentEdits() {
		var current = stored(Map.of("name", text("Asha K")), Map.of("name", 7L), 7);

		var outcome = merge(current, delete(5L));

		assertThat(outcome.result().status()).isEqualTo(MutationStatus.APPLIED);
		assertThat(outcome.write().deleted()).isTrue();
		assertThat(outcome.write().version()).isEqualTo(101);
	}

	@Test
	void editingADeletedRecordIsAConflict() {
		var current = new SyncRecord(RECORD, "visit", Map.of(), Map.of(), 9, true, "phone-a", NOW);

		var outcome = merge(current, upsert(5L, Map.of("name", text("Asha"))));

		assertThat(outcome.result().status()).isEqualTo(MutationStatus.CONFLICT);
		assertThat(outcome.write()).isNull();
	}

	@Test
	void deletingAnUnknownRecordLeavesATombstone() {
		var outcome = merge(null, delete(null));

		assertThat(outcome.write().deleted()).isTrue();
		assertThat(outcome.write().fields()).isEmpty();
	}

	@Test
	void deletingTwiceDoesNotWriteAgain() {
		var current = new SyncRecord(RECORD, "visit", Map.of(), Map.of(), 9, true, "phone-a", NOW);

		var outcome = merge(current, delete(9L));

		assertThat(outcome.write()).isNull();
		assertThat(outcome.result().version()).isEqualTo(9);
	}

	@Test
	void rejectsTypeChange() {
		var current = stored(Map.of("name", text("Asha")), Map.of("name", 5L), 5);
		var m = new Mutation(UUID.randomUUID(), RECORD, "household", Operation.UPSERT, 5L, Map.of("name", text("x")));

		var outcome = merge(current, m);

		assertThat(outcome.result().status()).isEqualTo(MutationStatus.REJECTED);
		assertThat(outcome.write()).isNull();
	}

	@Test
	void rejectsUpsertWithoutFields() {
		var outcome = merge(null, upsert(null, Map.of()));

		assertThat(outcome.result().status()).isEqualTo(MutationStatus.REJECTED);
		assertThat(seq.get()).as("no version consumed").isEqualTo(100);
	}

	private MergeEngine.Outcome merge(SyncRecord current, Mutation m) {
		return engine.merge(current, m, "phone-b", seq::incrementAndGet, NOW);
	}

	private static SyncRecord stored(Map<String, JsonNode> fields, Map<String, Long> fieldVersions, long version) {
		return new SyncRecord(RECORD, "visit", fields, fieldVersions, version, false, "phone-a", NOW);
	}

	private static Mutation upsert(Long base, Map<String, JsonNode> fields) {
		return new Mutation(UUID.randomUUID(), RECORD, "visit", Operation.UPSERT, base, fields);
	}

	private static Mutation delete(Long base) {
		return new Mutation(UUID.randomUUID(), RECORD, "visit", Operation.DELETE, base, null);
	}

	private static JsonNode text(String s) {
		return NODES.stringNode(s);
	}

}
