/* Native implementation of the net module's extern symbols.
 * Linked into executables that `use net;`. IPv4 dotted quads only;
 * failures are values (fd < 0, -1, empty str), never traps. */
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>

long long net_connect(const char *host, long long host_len, long long port) {
    char buf[64];
    if (host_len <= 0 || host_len >= (long long)sizeof(buf)) return -1;
    memcpy(buf, host, (size_t)host_len);
    buf[host_len] = 0;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = inet_addr(buf);
    if (addr.sin_addr.s_addr == INADDR_NONE) return -1;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

long long net_send(long long fd, const char *data, long long len) {
    long long total = 0;
    while (total < len) {
        long long sent = send((int)fd, data + total, (size_t)(len - total), 0);
        if (sent <= 0) return -1;
        total += sent;
    }
    return total;
}

struct stacy_str {
    const char *ptr;
    long long len;
};

static char net_recv_buffer[65536];

struct stacy_str net_recv(long long fd) {
    long long n = recv((int)fd, net_recv_buffer, sizeof net_recv_buffer, 0);
    struct stacy_str s = { net_recv_buffer, n > 0 ? n : 0 };
    return s;
}

long long net_close(long long fd) {
    return close((int)fd) == 0 ? 0 : -1;
}
