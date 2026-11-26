#ifndef METABRAIN_REFERENCE_DNS_H
#define METABRAIN_REFERENCE_DNS_H

#include <stddef.h>

enum mb_reference_dns_status {
    MB_REFERENCE_ADDRESS_RESOLVED,
    MB_REFERENCE_ADDRESS_UNAVAILABLE,
    MB_REFERENCE_ADDRESS_BLOCKED
};

/// Return a numeric public address for an HTTP connection pinned to this resolution.
enum mb_reference_dns_status mb_reference_resolve_public(const char *host, char *result, size_t size);

#endif
