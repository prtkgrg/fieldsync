package dev.prateekgarg.fieldsync.sync;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.assertj.MockMvcTester;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.JsonNodeFactory;

import dev.prateekgarg.fieldsync.TestcontainersConfiguration;

import static org.assertj.core.api.Assertions.assertThat;

/** End to end against a real PostgreSQL (Testcontainers), through the HTTP API. */
@SpringBootTest
@AutoConfigureMockMvc
@Import(TestcontainersConfiguration.class)
class SyncApiIntegrationTest {

	private static final JsonNodeFactory NODES = JsonNodeFactory.instance;

	@Autowired
	MockMvcTester mvc;

	@Autowired
	JsonMapper json;

	@Autowired
	SyncService sync;

	@Test
	void recordCreatedOfflineReachesAnotherDevice() {
		long cursor = pull(0, 1000).nextCursor();
		UUID id = UUID.randomUUID();

		MutationResult created = push("phone-a", upsert(id, null, Map.of("name", text("Asha")))).results().getFirst();

		assertThat(created.status()).isEqualTo(MutationStatus.APPLIED);
		PullResponse pulled = pull(cursor, 1000);
		assertThat(pulled.records()).extracting(SyncRecord::id).contains(id);
		assertThat(pulled.nextCursor()).isEqualTo(created.version());
	}

	@Test
	void retriedPushIsNotAppliedTwice() {
		UUID id = UUID.randomUUID();
		Mutation m = upsert(id, null, Map.of("name", text("Asha")));

		MutationResult first = push("phone-a", m).results().getFirst();
		MutationResult retry = push("phone-a", m).results().getFirst();

		assertThat(retry).isEqualTo(first);
		assertThat(pull(first.version() - 1, 1000).records()).filteredOn(r -> r.id().equals(id)).hasSize(1);
	}

	@Test
	void concurrentEditsToDifferentFieldsBothSurvive() {
		UUID id = UUID.randomUUID();
		long v1 = push("phone-a", upsert(id, null, Map.of("name", text("Asha"), "village", text("Rampur"))))
			.results().getFirst().version();

		push("phone-a", upsert(id, v1, Map.of("village", text("Sonpur"))));
		MutationResult fromB = push("phone-b", upsert(id, v1, Map.of("name", text("Asha Devi")))).results().getFirst();

		assertThat(fromB.status()).isEqualTo(MutationStatus.MERGED);
		SyncRecord merged = latest(id);
		assertThat(merged.fields()).containsEntry("name", text("Asha Devi")).containsEntry("village", text("Sonpur"));
	}

	@Test
	void sameFieldConflictKeepsServerValueAndReportsIt() {
		UUID id = UUID.randomUUID();
		long v1 = push("phone-a", upsert(id, null, Map.of("name", text("Asha")))).results().getFirst().version();

		push("phone-a", upsert(id, v1, Map.of("name", text("Asha K"))));
		MutationResult fromB = push("phone-b", upsert(id, v1, Map.of("name", text("Asha Devi")))).results().getFirst();

		assertThat(fromB.status()).isEqualTo(MutationStatus.CONFLICT);
		assertThat(fromB.conflicts()).singleElement().satisfies(c -> assertThat(c.serverValue()).isEqualTo(text("Asha K")));
		assertThat(latest(id).fields()).containsEntry("name", text("Asha K"));
	}

	@Test
	void deletesSyncAsTombstones() {
		UUID id = UUID.randomUUID();
		long v1 = push("phone-a", upsert(id, null, Map.of("name", text("Asha")))).results().getFirst().version();

		push("phone-a", new Mutation(UUID.randomUUID(), id, "visit", Operation.DELETE, v1, null));

		assertThat(latest(id).deleted()).isTrue();
	}

	@Test
	void pagingWalksEveryChangeExactlyOnce() {
		long start = pull(0, 1000).nextCursor();
		List<UUID> ids = new ArrayList<>();
		for (int i = 0; i < 7; i++) {
			UUID id = UUID.randomUUID();
			ids.add(id);
			push("phone-a", upsert(id, null, Map.of("n", NODES.numberNode(i))));
		}

		List<UUID> seen = new ArrayList<>();
		long cursor = start;
		PullResponse page;
		do {
			page = pull(cursor, 3);
			page.records().forEach(r -> seen.add(r.id()));
			cursor = page.nextCursor();
		}
		while (page.hasMore());

		assertThat(seen).containsExactlyElementsOf(ids);
	}

	/**
	 * Devices pull while others push. Because pushes are serialized, a version is only ever visible
	 * after all lower versions are, so no pull can skip past a change.
	 */
	@Test
	void pullingDuringConcurrentPushesMissesNothing() throws Exception {
		long start = pull(0, 1000).nextCursor();
		int writers = 8;
		int perWriter = 25;
		Set<UUID> written = java.util.concurrent.ConcurrentHashMap.newKeySet();
		Set<UUID> seen = new HashSet<>();

		try (ExecutorService pool = Executors.newFixedThreadPool(writers)) {
			List<Future<?>> tasks = new ArrayList<>();
			for (int w = 0; w < writers; w++) {
				tasks.add(pool.submit(() -> {
					for (int i = 0; i < perWriter; i++) {
						UUID id = UUID.randomUUID();
						sync.push(new PushRequest("phone-" + Thread.currentThread().getId(),
								List.of(upsert(id, null, Map.of("i", NODES.numberNode(i))))));
						written.add(id);
					}
				}));
			}
			long cursor = start;
			while (tasks.stream().anyMatch(t -> !t.isDone())) {
				PullResponse page = sync.pull(cursor, 50);
				page.records().forEach(r -> seen.add(r.id()));
				cursor = page.nextCursor();
			}
			for (Future<?> t : tasks) {
				t.get();
			}
			PullResponse page;
			do {
				page = sync.pull(cursor, 50);
				page.records().forEach(r -> seen.add(r.id()));
				cursor = page.nextCursor();
			}
			while (page.hasMore());
		}

		assertThat(seen).containsAll(written).hasSizeGreaterThanOrEqualTo(writers * perWriter);
	}

	@Test
	void invalidRequestIsA400ProblemDetail() {
		assertThat(mvc.post().uri("/api/v1/sync/push").contentType(MediaType.APPLICATION_JSON)
			.content("{\"deviceId\":\"\",\"mutations\":[]}"))
			.hasStatus(400)
			.hasContentType(MediaType.APPLICATION_PROBLEM_JSON);
	}

	private PushResponse push(String deviceId, Mutation... mutations) {
		var result = mvc.post().uri("/api/v1/sync/push").contentType(MediaType.APPLICATION_JSON)
			.content(json.writeValueAsString(new PushRequest(deviceId, List.of(mutations))))
			.exchange();
		assertThat(result).hasStatusOk();
		return json.readValue(result.getResponse().getContentAsByteArray(), PushResponse.class);
	}

	private PullResponse pull(long cursor, int limit) {
		var result = mvc.get().uri("/api/v1/sync/pull?cursor={c}&limit={l}", cursor, limit).exchange();
		assertThat(result).hasStatusOk();
		return json.readValue(result.getResponse().getContentAsByteArray(), PullResponse.class);
	}

	private SyncRecord latest(UUID id) {
		return pull(0, 1000).records().stream().filter(r -> r.id().equals(id)).findFirst().orElseThrow();
	}

	private static Mutation upsert(UUID id, Long base, Map<String, JsonNode> fields) {
		return new Mutation(UUID.randomUUID(), id, "visit", Operation.UPSERT, base, fields);
	}

	private static JsonNode text(String s) {
		return NODES.stringNode(s);
	}

}
