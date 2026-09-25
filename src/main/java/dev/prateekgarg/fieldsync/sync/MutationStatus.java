package dev.prateekgarg.fieldsync.sync;

public enum MutationStatus {
	/** The client was up to date; the change was applied as-is. */
	APPLIED,
	/** The server had moved on, but on other fields; both sides were kept. */
	MERGED,
	/** At least one field changed on both sides; the server value was kept. */
	CONFLICT,
	/** The mutation was invalid for the record's current state. */
	REJECTED
}
