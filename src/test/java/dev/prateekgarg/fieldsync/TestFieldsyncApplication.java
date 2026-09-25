package dev.prateekgarg.fieldsync;

import org.springframework.boot.SpringApplication;

public class TestFieldsyncApplication {

	public static void main(String[] args) {
		SpringApplication.from(FieldsyncApplication::main).with(TestcontainersConfiguration.class).run(args);
	}

}
