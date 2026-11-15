# wgvim: tablefmt, a post-processor for clang-format that aligns runs of similar lines into
# tables (:help wgvim-tablefmt). Built when a C++20 compiler is available, into bin/ next to
# the wgvim executable, and installed with it.
add_executable(tablefmt tablefmt.cpp)
set_target_properties(tablefmt PROPERTIES
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  CXX_EXTENSIONS OFF
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
target_compile_options(tablefmt PRIVATE -Wall -Wextra -Wpedantic)
install(TARGETS tablefmt RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")

# The same hardening as the editor (src/nvim/CMakeLists.txt), checked against the C++ compiler,
# plus libstdc++'s bounds checks (_GLIBCXX_ASSERTIONS), as distributions build C++ programs.
if(WGVIM_HARDENING)
  include(CheckCXXCompilerFlag)
  include(CheckCXXSourceCompiles)
  include(CheckPIESupported)
  check_pie_supported(OUTPUT_VARIABLE TABLEFMT_PIE_OUTPUT LANGUAGES CXX)
  set_property(TARGET tablefmt PROPERTY POSITION_INDEPENDENT_CODE ON)
  # _FORTIFY_SOURCE=3 needs __builtin_dynamic_object_size (GCC 12+, Clang 9+); else 2.
  check_cxx_source_compiles("
    int main() { char b[4]; return (int)__builtin_dynamic_object_size(b, 0); }"
    HAS_CXX_BUILTIN_DYNAMIC_OBJECT_SIZE)
  if(HAS_CXX_BUILTIN_DYNAMIC_OBJECT_SIZE)
    set(TABLEFMT_FORTIFY_LEVEL 3)
  else()
    set(TABLEFMT_FORTIFY_LEVEL 2)
  endif()
  # -U before -D, in one list, so the order on the command line is kept.
  target_compile_options(tablefmt PRIVATE
    "$<$<NOT:$<CONFIG:Debug>>:-U_FORTIFY_SOURCE;-D_FORTIFY_SOURCE=${TABLEFMT_FORTIFY_LEVEL}>")
  target_compile_definitions(tablefmt PRIVATE _GLIBCXX_ASSERTIONS)
  foreach(flag
      -fstack-protector-strong -fstack-clash-protection -fcf-protection=full
      -mbranch-protection=standard -ftrivial-auto-var-init=zero -fno-strict-overflow)
    string(MAKE_C_IDENTIFIER "HAS_CXX${flag}" var)
    check_cxx_compiler_flag(${flag} ${var})
    if(${var})
      target_compile_options(tablefmt PRIVATE ${flag})
    endif()
  endforeach()
  foreach(lflag -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,separate-code)
    string(MAKE_C_IDENTIFIER "HAS_CXX_LINK${lflag}" var)
    set(CMAKE_REQUIRED_LINK_OPTIONS ${lflag})
    check_cxx_source_compiles("int main() { return 0; }" ${var})
    unset(CMAKE_REQUIRED_LINK_OPTIONS)
    if(${var})
      target_link_options(tablefmt PRIVATE ${lflag})
    endif()
  endforeach()
endif()

# libFuzzer harness (test/fuzz/tablefmt_fuzzer.cpp), in the WGVIM_FUZZ build (clang).
if(WGVIM_FUZZ)
  add_executable(tablefmt_fuzzer EXCLUDE_FROM_ALL ${PROJECT_SOURCE_DIR}/test/fuzz/tablefmt_fuzzer.cpp)
  set_target_properties(tablefmt_fuzzer PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
  target_compile_definitions(tablefmt_fuzzer PRIVATE TABLEFMT_FUZZ)
  target_compile_options(tablefmt_fuzzer PRIVATE -fsanitize=fuzzer,address,undefined
    -fno-sanitize-recover=undefined -fno-omit-frame-pointer -g)
  target_link_options(tablefmt_fuzzer PRIVATE -fsanitize=fuzzer,address,undefined)
  add_dependencies(fuzzers tablefmt_fuzzer)
endif()
