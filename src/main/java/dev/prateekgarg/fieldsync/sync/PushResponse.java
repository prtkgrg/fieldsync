package dev.prateekgarg.fieldsync.sync;

import java.util.List;

public record PushResponse(List<MutationResult> results) {
}
