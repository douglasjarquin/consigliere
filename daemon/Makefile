# Builds the CS_HOME fcntl lock NIF and a probe helper used by tests.

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts/erts-~ts/include/\", [code:root_dir(), erlang:system_info(version)])." -s init stop)

PREFIX ?= $(MIX_APP_PATH)/priv
BUILD ?= $(MIX_APP_PATH)/obj
NIF = $(PREFIX)/cs_home_lock.so
PROC_NIF = $(PREFIX)/cs_proc.so
PROBE = $(PREFIX)/cs_lock_probe

KERNEL_NAME := $(shell uname -s)

CFLAGS ?= -O2
CFLAGS += -I"$(ERTS_INCLUDE_DIR)" -fPIC -Wall -Wextra -Werror
LDFLAGS ?=

ifeq ($(KERNEL_NAME), Darwin)
	NIF_LDFLAGS = -dynamiclib -undefined dynamic_lookup
else
	NIF_LDFLAGS = -shared
endif

.PHONY: all clean

all: $(NIF) $(PROC_NIF) $(PROBE)

$(PREFIX):
	mkdir -p $(PREFIX)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/cs_home_lock.o: c_src/cs_home_lock.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/cs_lock_probe.o: c_src/cs_lock_probe.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(NIF): $(BUILD)/cs_home_lock.o | $(PREFIX)
	$(CC) $(NIF_LDFLAGS) -o $@ $<

$(BUILD)/cs_proc.o: c_src/cs_proc.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(PROC_NIF): $(BUILD)/cs_proc.o | $(PREFIX)
	$(CC) $(NIF_LDFLAGS) -o $@ $<

$(PROBE): $(BUILD)/cs_lock_probe.o | $(PREFIX)
	$(CC) -o $@ $<

clean:
	rm -f $(NIF) $(PROC_NIF) $(PROBE) $(BUILD)/cs_home_lock.o $(BUILD)/cs_proc.o $(BUILD)/cs_lock_probe.o
