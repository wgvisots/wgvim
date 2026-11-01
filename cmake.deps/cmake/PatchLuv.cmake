# wgvim: remove the network API from luv, the library behind `vim.uv` / `vim.loop`.
#
# Lua plugins could otherwise open TCP/UDP sockets and resolve host names. This runs as
# the PATCH_COMMAND of the luv ExternalProject, so the vendored tarball stays
# byte-for-byte what its SHA256 in deps.txt says.
#
# It removes the registrations of new_tcp / tcp_*, new_udp / udp_* and getaddrinfo /
# getnameinfo from the function table in src/luv.c. The build FAILS if any block is not
# found, so this cannot silently stop working after a luv upgrade.
#
# Usage: cmake -D LUV_SRC=<luv source dir> -P PatchLuv.cmake
#
# Not removed, and not removable from here: LuaJIT's `ffi` library lets Lua call libc
# directly. See SECURITY-AUDIT.md.

if(NOT LUV_SRC)
  message(FATAL_ERROR "PatchLuv.cmake: LUV_SRC is not set")
endif()
set(luv_c "${LUV_SRC}/src/luv.c")
file(READ "${luv_c}" content)

set(tcp_block [=[
  // tcp.c
  {"new_tcp", luv_new_tcp},
  {"tcp_open", luv_tcp_open},
  {"tcp_nodelay", luv_tcp_nodelay},
  {"tcp_keepalive", luv_tcp_keepalive},
  {"tcp_simultaneous_accepts", luv_tcp_simultaneous_accepts},
  {"tcp_bind", luv_tcp_bind},
  {"tcp_getpeername", luv_tcp_getpeername},
  {"tcp_getsockname", luv_tcp_getsockname},
  {"tcp_connect", luv_tcp_connect},
  {"tcp_write_queue_size", luv_write_queue_size},
#if LUV_UV_VERSION_GEQ(1, 32, 0)
  {"tcp_close_reset", luv_tcp_close_reset},
#endif
]=])

set(udp_block [=[
  // udp.c
  {"new_udp", luv_new_udp},
  {"udp_get_send_queue_size", luv_udp_get_send_queue_size},
  {"udp_get_send_queue_count", luv_udp_get_send_queue_count},
  {"udp_open", luv_udp_open},
  {"udp_bind", luv_udp_bind},
  {"udp_getsockname", luv_udp_getsockname},
  {"udp_set_membership", luv_udp_set_membership},
#if LUV_UV_VERSION_GEQ(1, 32, 0)
  {"udp_set_source_membership", luv_udp_set_source_membership},
#endif
  {"udp_set_multicast_loop", luv_udp_set_multicast_loop},
  {"udp_set_multicast_ttl", luv_udp_set_multicast_ttl},
  {"udp_set_multicast_interface", luv_udp_set_multicast_interface},
  {"udp_set_broadcast", luv_udp_set_broadcast},
  {"udp_set_ttl", luv_udp_set_ttl},
  {"udp_send", luv_udp_send},
  {"udp_try_send", luv_udp_try_send},
#if LUV_UV_VERSION_GEQ(1, 50, 0)
  {"udp_try_send2", luv_udp_try_send2},
#endif
  {"udp_recv_start", luv_udp_recv_start},
  {"udp_recv_stop", luv_udp_recv_stop},
#if LUV_UV_VERSION_GEQ(1, 27, 0)
  {"udp_connect", luv_udp_connect},
  {"udp_getpeername", luv_udp_getpeername},
#endif
]=])

set(dns_block [=[
  // dns.c
  {"getaddrinfo", luv_getaddrinfo},
  {"getnameinfo", luv_getnameinfo},
]=])

foreach(block tcp_block udp_block dns_block)
  string(FIND "${content}" "${${block}}" pos)
  if(pos EQUAL -1)
    message(FATAL_ERROR
      "PatchLuv.cmake: expected ${block} not found in ${luv_c}. The vendored luv "
      "changed; update cmake.deps/cmake/PatchLuv.cmake so the network API is still removed.")
  endif()
  string(REPLACE "${${block}}" "" content "${content}")
endforeach()

# Fail closed: nothing network-related may remain in the function table.
string(REGEX MATCH "\\{\"(new_tcp|new_udp|tcp_[a-z_]+|udp_[a-z_]+|getaddrinfo|getnameinfo)\"" leftover "${content}")
if(leftover)
  message(FATAL_ERROR "PatchLuv.cmake: network function still registered: ${leftover}")
endif()

file(WRITE "${luv_c}" "${content}")
message(STATUS "PatchLuv: removed tcp/udp/dns functions from ${luv_c}")
