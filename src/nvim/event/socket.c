#include <assert.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <uv.h>

#include "nvim/ascii_defs.h"
#include "nvim/charset.h"
#include "nvim/event/defs.h"
#include "nvim/event/loop.h"
#include "nvim/event/multiqueue.h"
#include "nvim/event/socket.h"
#include "nvim/event/stream.h"
#include "nvim/gettext_defs.h"
#include "nvim/log.h"
#include "nvim/main.h"
#include "nvim/memory.h"
#include "nvim/os/fs.h"
#include "nvim/os/os_defs.h"
#include "nvim/path.h"
#include "nvim/types_defs.h"

#include "event/socket.c.generated.h"

/// Checks if an address string looks like a TCP endpoint, and returns the end of the host part.
///
/// @param address Address string
/// @return pointer to the end of the host part of the address, or NULL if it is not a TCP address
char *socket_address_tcp_host_end(const char *address)
{
  if (address == NULL) {
    return NULL;
  }

  // Windows drive letter path: "X:/..." is a local path, not TCP.
  if (ASCII_ISALPHA((uint8_t)address[0]) && address[1] == ':' && address[2] == '/') {
    return NULL;
  }

  char *colon = strrchr((char *)address, ':');
  return colon != NULL && colon != address ? colon : NULL;
}

int socket_watcher_init(Loop *loop, SocketWatcher *watcher, const char *endpoint)
  FUNC_ATTR_NONNULL_ALL
{
  xstrlcpy(watcher->addr, endpoint, sizeof(watcher->addr));
  char *addr = watcher->addr;
  char *host_end = socket_address_tcp_host_end(addr);

  if (host_end) {
    // wgvim: TCP (and therefore DNS) support was removed; only pipes/Unix sockets.
    ELOG("TCP addresses are not supported: %s", endpoint);
    return UV_EINVAL;
  }

  uv_pipe_init(&loop->uv, &watcher->uv.pipe.handle, 0);
  watcher->stream = (uv_stream_t *)(&watcher->uv.pipe.handle);

  watcher->stream->data = watcher;
  watcher->cb = NULL;
  watcher->close_cb = NULL;
  watcher->events = NULL;
  watcher->data = NULL;

  return 0;
}

/// Callback after closing a Stream initialized by socket_connect().
static void connect_close_cb(Stream *stream, void *data)
{
  bool *closed = data;
  *closed = true;
}

/// Check if a socket is alive by attempting to connect to it.
/// @param loop Event loop
/// @param addr Socket address to probe
/// @return true if socket is alive (connection succeeded), false otherwise
static bool socket_alive(Loop *loop, const char *addr)
{
  RStream stream = { 0 };
  const char *error = NULL;

  // Try to connect with a 500ms timeout (fast failure for dead sockets)
  bool connected = socket_connect(loop, &stream, false, addr, 500, &error);
  if (!connected) {
    return false;
  }

  // Connection succeeded - socket is alive. Close the probe connection properly.
  bool closed = false;
  stream.s.internal_close_cb = connect_close_cb;
  stream.s.internal_data = &closed;
  stream_may_close(&stream.s);
  LOOP_PROCESS_EVENTS_UNTIL(&main_loop, NULL, -1, closed);

  return true;
}

static void early_server_close_cb(uv_handle_t *handle)
{
  bool *closed = handle->data;
  *closed = true;
}

int socket_watcher_start(SocketWatcher *watcher, int backlog, socket_cb cb)
  FUNC_ATTR_NONNULL_ALL
{
  watcher->cb = cb;
  int result = UV_EINVAL;

  result = uv_pipe_bind2(&watcher->uv.pipe.handle, watcher->addr, strlen(watcher->addr),
                         UV_PIPE_NO_TRUNCATE);

  // If bind failed with EACCES/EADDRINUSE, check if socket is stale
  if (result == UV_EACCES || result == UV_EADDRINUSE) {
    Loop *loop = watcher->stream->loop->data;

    if (!socket_alive(loop, watcher->addr)) {
      // Socket exists but is dead - remove it
      ILOG("Removing stale socket: %s", watcher->addr);
      int rm_result = os_remove(watcher->addr);

      if (rm_result != 0) {
        WLOG("Failed to remove stale socket %s: %s",
             watcher->addr, uv_strerror(rm_result));
      } else {
        // Close and reinit the pipe handle before retrying bind
        uv_loop_t *uv_loop = watcher->uv.pipe.handle.loop;
        bool closed = false;
        watcher->uv.pipe.handle.data = &closed;
        uv_close((uv_handle_t *)&watcher->uv.pipe.handle, early_server_close_cb);
        LOOP_PROCESS_EVENTS_UNTIL(&main_loop, NULL, -1, closed);

        uv_pipe_init(uv_loop, &watcher->uv.pipe.handle, 0);
        watcher->stream = (uv_stream_t *)(&watcher->uv.pipe.handle);
        watcher->stream->data = watcher;

        // Retry bind with fresh handle
        result = uv_pipe_bind2(&watcher->uv.pipe.handle, watcher->addr, strlen(watcher->addr),
                               UV_PIPE_NO_TRUNCATE);
      }
    } else {
      // Socket is alive - this is a real error
      ELOG("Socket already in use by another wgvim instance: %s", watcher->addr);
    }
  }

  if (result == 0) {
    result = uv_listen(watcher->stream, backlog, connection_cb);
  }


  assert(result <= 0);  // libuv should return negative error code or zero.
  if (result < 0) {
    if (result == UV_EACCES) {
      // Libuv converts ENOENT to EACCES for Windows compatibility, but if
      // the parent directory does not exist, ENOENT would be more accurate.
      *path_tail(watcher->addr) = NUL;
      if (!os_path_exists(watcher->addr)) {
        result = UV_ENOENT;
      }
    }
    return result;
  }

  return 0;
}

int socket_watcher_accept(SocketWatcher *watcher, RStream *stream)
  FUNC_ATTR_NONNULL_ARG(1) FUNC_ATTR_NONNULL_ARG(2)
{
  uv_stream_t *client = (uv_stream_t *)&stream->s.uv.pipe;
  uv_pipe_init(watcher->uv.pipe.handle.loop, (uv_pipe_t *)client, 0);

  int result = uv_accept(watcher->stream, client);

  if (result) {
    uv_close((uv_handle_t *)client, NULL);
    return result;
  }

  stream_init(NULL, &stream->s, -1, client);
  return 0;
}

void socket_watcher_close(SocketWatcher *watcher, socket_close_cb cb)
  FUNC_ATTR_NONNULL_ARG(1)
{
  watcher->close_cb = cb;
  uv_close((uv_handle_t *)watcher->stream, close_cb);
}

static void connection_event(void **argv)
{
  SocketWatcher *watcher = argv[0];
  int status = (int)(uintptr_t)(argv[1]);
  watcher->cb(watcher, status, watcher->data);
}

static void connection_cb(uv_stream_t *handle, int status)
{
  SocketWatcher *watcher = handle->data;
  CREATE_EVENT(watcher->events, connection_event, watcher, (void *)(uintptr_t)status);
}

static void close_cb(uv_handle_t *handle)
{
  SocketWatcher *watcher = handle->data;
  if (watcher->close_cb) {
    watcher->close_cb(watcher, watcher->data);
  }
}

static void connect_cb(uv_connect_t *req, int status)
{
  int *ret_status = req->data;
  *ret_status = status;
  uv_handle_t *handle = (uv_handle_t *)req->handle;
  if (status != 0) {
    stream_may_close(handle->data);
  }
}

bool socket_connect(Loop *loop, RStream *stream, bool is_tcp, const char *address, int timeout,
                    const char **error)
{
  if (is_tcp) {
    // wgvim: TCP (and therefore DNS) support was removed; only pipes/Unix sockets.
    *error = _("TCP connections are not supported");
    return false;
  }

  bool success = false;
  bool closed;
  int status;
  uv_connect_t req;
  req.data = &status;

  uv_pipe_t *pipe = &stream->s.uv.pipe;
  uv_pipe_init(&loop->uv, pipe, 0);
  uv_pipe_connect(&req, pipe, address, connect_cb);
  stream_init(NULL, &stream->s, -1, (uv_stream_t *)pipe);
  stream->s.internal_close_cb = connect_close_cb;
  stream->s.internal_data = &closed;
  closed = false;
  status = 1;
  LOOP_PROCESS_EVENTS_UNTIL(&main_loop, NULL, timeout, status != 1);
  if (status == 0) {
    success = true;
  } else {
    stream_may_close(&stream->s);
    // Wait for the close callback to arrive before returning, otherwise it may
    // lead to a hang or stack-use-after-return.
    LOOP_PROCESS_EVENTS_UNTIL(&main_loop, NULL, -1, closed);
    *error = _("connection refused");
  }

  stream->s.internal_close_cb = NULL;
  stream->s.internal_data = NULL;
  return success;
}
