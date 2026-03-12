#define _POSIX_C_SOURCE 200112L

#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_HTTP_PORT "80"
#define READ_BUFFER_SIZE 4096
#define RESPONSE_LIMIT 65536
#define SERVER_URL "http://slop-engine.de:4567"

struct parsed_url {
    char host[256];
    char port[16];
};

struct http_response {
    int status_code;
    char *headers;
    char *body;
    char *raw;
};

static int parse_base_url(const char *url, struct parsed_url *result) {
    const char *cursor = url;
    const char *host_start;
    const char *path_start;
    const char *port_sep;
    size_t host_len;
    size_t port_len;

    if (strncmp(cursor, "http://", 7) == 0) {
        cursor += 7;
    } else {
        fprintf(stderr, "Only http:// URLs are supported.\n");
        return -1;
    }

    host_start = cursor;
    path_start = strchr(cursor, '/');
    if (path_start != NULL && path_start[1] != '\0') {
        fprintf(stderr, "Base URL should not include a path. Example: http://127.0.0.1:4567\n");
        return -1;
    }
    if (path_start == NULL) {
        path_start = cursor + strlen(cursor);
    }

    port_sep = memchr(host_start, ':', (size_t)(path_start - host_start));
    if (port_sep != NULL) {
        host_len = (size_t)(port_sep - host_start);
        port_len = (size_t)(path_start - port_sep - 1);
        if (port_len == 0 || port_len >= sizeof(result->port)) {
            fprintf(stderr, "Invalid port in URL.\n");
            return -1;
        }
        memcpy(result->port, port_sep + 1, port_len);
        result->port[port_len] = '\0';
    } else {
        host_len = (size_t)(path_start - host_start);
        snprintf(result->port, sizeof(result->port), "%s", DEFAULT_HTTP_PORT);
    }

    if (host_len == 0 || host_len >= sizeof(result->host)) {
        fprintf(stderr, "Invalid host in URL.\n");
        return -1;
    }

    memcpy(result->host, host_start, host_len);
    result->host[host_len] = '\0';

    return 0;
}

static int connect_to_host(const struct parsed_url *url) {
    struct addrinfo hints;
    struct addrinfo *addresses;
    struct addrinfo *address;
    int socket_fd = -1;
    int status;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    status = getaddrinfo(url->host, url->port, &hints, &addresses);
    if (status != 0) {
        fprintf(stderr, "getaddrinfo failed: %s\n", gai_strerror(status));
        return -1;
    }

    for (address = addresses; address != NULL; address = address->ai_next) {
        socket_fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socket_fd == -1) {
            continue;
        }

        if (connect(socket_fd, address->ai_addr, address->ai_addrlen) == 0) {
            break;
        }

        close(socket_fd);
        socket_fd = -1;
    }

    freeaddrinfo(addresses);

    if (socket_fd == -1) {
        fprintf(stderr, "Unable to connect to %s:%s\n", url->host, url->port);
    }

    return socket_fd;
}

static void free_response(struct http_response *response) {
    free(response->raw);
    response->raw = NULL;
    response->headers = NULL;
    response->body = NULL;
}

static int send_all(int socket_fd, const char *buffer, size_t length) {
    size_t total_sent = 0;

    while (total_sent < length) {
        ssize_t sent = send(socket_fd, buffer + total_sent, length - total_sent, 0);
        if (sent < 0) {
            perror("send");
            return -1;
        }
        total_sent += (size_t)sent;
    }

    return 0;
}

static int read_response(int socket_fd, struct http_response *response) {
    char chunk[READ_BUFFER_SIZE];
    char *raw = malloc(RESPONSE_LIMIT);
    size_t used = 0;
    ssize_t bytes_read;
    char *header_end;

    if (raw == NULL) {
        fprintf(stderr, "Out of memory.\n");
        return -1;
    }

    while ((bytes_read = recv(socket_fd, chunk, sizeof(chunk), 0)) > 0) {
        if (used + (size_t)bytes_read + 1 > RESPONSE_LIMIT) {
            fprintf(stderr, "Response exceeded buffer limit.\n");
            free(raw);
            return -1;
        }
        memcpy(raw + used, chunk, (size_t)bytes_read);
        used += (size_t)bytes_read;
    }

    if (bytes_read < 0) {
        perror("recv");
        free(raw);
        return -1;
    }

    raw[used] = '\0';
    header_end = strstr(raw, "\r\n\r\n");
    if (header_end == NULL) {
        fprintf(stderr, "Malformed HTTP response.\n");
        free(raw);
        return -1;
    }

    *header_end = '\0';
    response->raw = raw;
    response->headers = raw;
    response->body = header_end + 4;
    if (sscanf(raw, "HTTP/%*s %d", &response->status_code) != 1) {
        fprintf(stderr, "Failed to parse status code.\n");
        free_response(response);
        return -1;
    }

    return 0;
}

static int perform_request(
    const struct parsed_url *url,
    const char *method,
    const char *path,
    const char *extra_headers,
    const char *body,
    struct http_response *response
) {
    int socket_fd;
    char request[4096];
    int body_length = body == NULL ? 0 : (int)strlen(body);
    int request_len;

    socket_fd = connect_to_host(url);
    if (socket_fd == -1) {
        return -1;
    }

    request_len = snprintf(
        request,
        sizeof(request),
        "%s %s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Connection: close\r\n"
        "User-Agent: handshake-c-client/1.0\r\n"
        "%s"
        "Content-Length: %d\r\n"
        "\r\n"
        "%s",
        method,
        path,
        url->host,
        extra_headers == NULL ? "" : extra_headers,
        body_length,
        body == NULL ? "" : body
    );

    if (request_len < 0 || request_len >= (int)sizeof(request)) {
        fprintf(stderr, "Request buffer overflow.\n");
        close(socket_fd);
        return -1;
    }

    if (send_all(socket_fd, request, (size_t)request_len) != 0) {
        close(socket_fd);
        return -1;
    }

    memset(response, 0, sizeof(*response));
    if (read_response(socket_fd, response) != 0) {
        close(socket_fd);
        return -1;
    }

    close(socket_fd);
    return 0;
}

static int extract_token(const char *body, char *token, size_t token_size) {
    const char *prefix = "token=";
    const char *start = strstr(body, prefix);
    const char *end;
    size_t length;

    if (start == NULL) {
        return -1;
    }

    start += strlen(prefix);
    end = strpbrk(start, "\r\n");
    if (end == NULL) {
        end = start + strlen(start);
    }

    length = (size_t)(end - start);
    if (length == 0 || length >= token_size) {
        return -1;
    }

    memcpy(token, start, length);
    token[length] = '\0';
    return 0;
}

int main(int argc, char *argv[]) {
    struct parsed_url url;
    struct http_response register_response;
    struct http_response data_response;
    char register_body[256];
    char auth_headers[512];
    char token[128];
    const char *client_id;

    if (argc > 2) {
        fprintf(stderr, "Usage: %s [client-id]\n", argv[0]);
        return 1;
    }

    client_id = argc == 2 ? argv[1] : "c-client-01";

    if (parse_base_url(SERVER_URL, &url) != 0) {
        return 1;
    }

    snprintf(register_body, sizeof(register_body), "client_id=%s", client_id);
    if (perform_request(
            &url,
            "POST",
            "/register",
            "Content-Type: application/x-www-form-urlencoded\r\n",
            register_body,
            &register_response) != 0) {
        return 1;
    }

    if (register_response.status_code != 200 || extract_token(register_response.body, token, sizeof(token)) != 0) {
        fprintf(stderr, "Registration failed or token missing.\n");
        free_response(&register_response);
        return 1;
    }

    snprintf(auth_headers, sizeof(auth_headers), "Authorization: Bearer %s\r\n", token);
    if (perform_request(&url, "GET", "/data", auth_headers, NULL, &data_response) != 0) {
        free_response(&register_response);
        return 1;
    }

    if (data_response.status_code != 200) {
        fprintf(stderr, "Authenticated request failed.\n");
        free_response(&register_response);
        free_response(&data_response);
        return 1;
    }

    fputs(data_response.body, stdout);

    free_response(&register_response);
    free_response(&data_response);
    return 0;
}
