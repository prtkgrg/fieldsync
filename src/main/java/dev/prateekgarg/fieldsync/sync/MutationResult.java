package dev.prateekgarg.fieldsync.sync;

import java.util.List;
import java.util.UUID;

/**
 * @param version the record's version after this mutation; the device stores it as its new base version
 */
public record MutationResult(
		UUID mutationId,
		UUID recordId,
		MutationStatus status,
		long version,
		List<FieldConflict> conflicts,
		String message) {
}
