package dev.prateekgarg.fieldsync.sync;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/sync")
@Validated
public class SyncController {

	private final SyncService sync;

	public SyncController(SyncService sync) {
		this.sync = sync;
	}

	/** Upload a batch of offline changes. Safe to retry: already-applied mutations are not applied twice. */
	@PostMapping("/push")
	public PushResponse push(@Valid @RequestBody PushRequest request) {
		return sync.push(request);
	}

	/** Download changes after {@code cursor}. Start at 0; repeat with {@code nextCursor} while {@code hasMore}. */
	@GetMapping("/pull")
	public PullResponse pull(@RequestParam(defaultValue = "0") @Min(0) long cursor,
			@RequestParam(defaultValue = "500") @Min(1) @Max(1000) int limit) {
		return sync.pull(cursor, limit);
	}

}
