package dev.prateekgarg.fieldsync.sync;

import java.util.List;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;

public record PushRequest(
		@NotBlank @Size(max = 100) String deviceId,
		@NotEmpty @Size(max = 500) List<@Valid Mutation> mutations) {
}
