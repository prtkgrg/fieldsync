package dev.prateekgarg.fieldsync.sync;

import java.time.Clock;
import java.util.ArrayList;
import java.util.List;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class SyncService {

	private final SyncStore store;

	private final MergeEngine merge;

	private final Clock clock;

	public SyncService(SyncStore store, MergeEngine merge, Clock clock) {
		this.store = store;
		this.merge = merge;
		this.clock = clock;
	}

	/**
	 * Applies a batch of offline changes in order, in one transaction. Mutations already applied
	 * (a retried request) return their original result instead of being applied twice.
	 */
	@Transactional
	public PushResponse push(PushRequest request) {
		store.lockForPush();
		List<MutationResult> results = new ArrayList<>(request.mutations().size());
		for (Mutation m : request.mutations()) {
			results.add(store.findAppliedMutation(m.mutationId()).orElseGet(() -> apply(request.deviceId(), m)));
		}
		return new PushResponse(results);
	}

	private MutationResult apply(String deviceId, Mutation m) {
		SyncRecord current = store.find(m.recordId()).orElse(null);
		MergeEngine.Outcome outcome = merge.merge(current, m, deviceId, store::nextVersion, clock.instant());
		if (outcome.write() != null) {
			store.save(outcome.write());
		}
		MutationResult result = outcome.result();
		result.conflicts().forEach(c -> store.recordConflict(deviceId, result, c));
		store.recordAppliedMutation(deviceId, result);
		return result;
	}

	/** Changes after {@code cursor}, oldest first, including tombstones. */
	@Transactional(readOnly = true)
	public PullResponse pull(long cursor, int limit) {
		List<SyncRecord> rows = store.changesSince(cursor, limit);
		boolean hasMore = rows.size() > limit;
		List<SyncRecord> page = hasMore ? rows.subList(0, limit) : rows;
		long nextCursor = page.isEmpty() ? cursor : page.getLast().version();
		return new PullResponse(List.copyOf(page), nextCursor, hasMore);
	}

}
