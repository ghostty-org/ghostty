#include <os/log.h>
#include <os/signpost.h>

// A wrapper so we can use the os_log_with_type macro.
void zig_os_log_with_type(
    os_log_t log,
    os_log_type_t type,
    const char *message
) {
    os_log_with_type(log, type, "%{public}s", message);
}
