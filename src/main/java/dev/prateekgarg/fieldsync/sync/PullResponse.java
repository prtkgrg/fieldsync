package dev.prateekgarg.fieldsync.sync;

import java.util.List;

/**
 * @param nextCursor pass as {@code cursor} on the next pull
 * @param hasMore    true if more changes are waiting; keep pulling until false
 */
public record PullResponse(List<SyncRecord> records, long nextCursor, boolean hasMore) {
}
