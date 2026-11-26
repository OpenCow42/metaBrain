#include "MetaBrainReferenceDNS.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#endif

static bool is_public_ipv4(const struct sockaddr_in *address) {
    uint32_t ip = ntohl(address->sin_addr.s_addr);
    return (ip >> 24) != 0 && (ip >> 24) != 10 && (ip >> 24) != 127 && (ip >> 24) < 224
        && (ip >> 22) != (0x64400000 >> 22)   /* shared address space */
        && (ip >> 20) != (0xac100000 >> 20)
        && (ip >> 16) != 0xa9fe && (ip >> 16) != 0xc0a8
        && (ip >> 17) != (0xc6120000 >> 17)   /* benchmarking */
        && (ip >> 8) != 0xc00000 && (ip >> 8) != 0xc00002 && (ip >> 8) != 0xc05863
        && (ip >> 8) != 0xc63364 && (ip >> 8) != 0xcb0071;
}

static bool is_public_ipv6(const struct sockaddr_in6 *address) {
    const unsigned char *ip = address->sin6_addr.s6_addr;
    return (ip[0] & 0xe0) == 0x20
        && !(ip[0] == 0x20 && ip[1] == 0x01 && (ip[2] <= 1 || (ip[2] == 0x0d && ip[3] == 0xb8)))
        && !(ip[0] == 0x20 && ip[1] == 0x02)  /* 6to4 */
        && !(ip[0] == 0x3f && ip[1] == 0xff && (ip[2] & 0xf0) == 0);  /* documentation */
}

static enum mb_reference_dns_status resolve_public(const char *host, char *result, size_t size) {
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, NULL, &hints, &addresses) != 0) {
        return MB_REFERENCE_ADDRESS_UNAVAILABLE;
    }

    enum mb_reference_dns_status status = MB_REFERENCE_ADDRESS_UNAVAILABLE;
    const struct addrinfo *selected = NULL;
    for (const struct addrinfo *info = addresses; info != NULL; info = info->ai_next) {
        bool public_address;
        if (info->ai_family == AF_INET) {
            public_address = is_public_ipv4((const struct sockaddr_in *)info->ai_addr);
        } else if (info->ai_family == AF_INET6) {
            public_address = is_public_ipv6((const struct sockaddr_in6 *)info->ai_addr);
        } else {
            continue;
        }
        if (!public_address) {
            status = MB_REFERENCE_ADDRESS_BLOCKED;
            selected = NULL;
            break;
        }
        if (selected == NULL || (selected->ai_family == AF_INET6 && info->ai_family == AF_INET)) {
            selected = info;
        }
    }
    if (selected != NULL && getnameinfo(selected->ai_addr, (int)selected->ai_addrlen,
                                       result, (int)size, NULL, 0, NI_NUMERICHOST) == 0) {
        status = MB_REFERENCE_ADDRESS_RESOLVED;
    }
    freeaddrinfo(addresses);
    return status;
}

enum mb_reference_dns_status mb_reference_resolve_public(const char *host, char *result, size_t size) {
#ifdef _WIN32
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        return MB_REFERENCE_ADDRESS_UNAVAILABLE;
    }
#endif
    enum mb_reference_dns_status status = resolve_public(host, result, size);
#ifdef _WIN32
    WSACleanup();
#endif
    return status;
}
