set(NVIM_VERSION
    "v${NVIM_VERSION_MAJOR}.${NVIM_VERSION_MINOR}.${NVIM_VERSION_PATCH}${NVIM_VERSION_PRERELEASE}")

# wgvim: the build is identified by its wgvim commit, "1a2b3c4" or "1a2b3c4-dirty"; tags are
# ignored (--exclude='*'), since wgvim's own release tags (v1.0.0, ...) are not Neovim versions.
execute_process(
  COMMAND git --git-dir=${NVIM_SOURCE_DIR}/.git --work-tree=${NVIM_SOURCE_DIR} describe --always --dirty --abbrev=7 --exclude=*
  OUTPUT_VARIABLE GIT_TAG
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET
  RESULT_VARIABLE RES)
# wgvim: no .git (a source tree from "git archive"): use the commit that git archive wrote into
# cmake.config/source-commit.txt (export-subst in .gitattributes). Outside an archive the file
# still holds the unexpanded "$Format:...$" and is ignored.
if(RES AND EXISTS "${NVIM_SOURCE_DIR}/cmake.config/source-commit.txt")
  file(STRINGS "${NVIM_SOURCE_DIR}/cmake.config/source-commit.txt" ARCHIVE_COMMIT LIMIT_COUNT 1)
  if(ARCHIVE_COMMIT MATCHES "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+$")
    set(GIT_TAG "${ARCHIVE_COMMIT}")
    set(RES 0)
  endif()
endif()
if(RES)
  message(STATUS "Using NVIM_VERSION: ${NVIM_VERSION}")
  file(WRITE "${OUTPUT}" "")
  return()
endif()

# The commit (wgvim --version, vim.version().build).
set(NVIM_VERSION_BUILD "${GIT_TAG}")
# Neovim's dev version names the build too: "v0.13.0-dev-1a2b3c4".
if(NVIM_VERSION_PRERELEASE)
  set(NVIM_VERSION "${NVIM_VERSION}-${GIT_TAG}")
endif()

set(NVIM_VERSION_STRING "#define NVIM_VERSION_MEDIUM \"${NVIM_VERSION}\"\n#define NVIM_VERSION_BUILD \"${NVIM_VERSION_BUILD}\"\n")

string(SHA1 CURRENT_VERSION_HASH "${NVIM_VERSION_STRING}")
if(EXISTS ${OUTPUT})
  file(SHA1 "${OUTPUT}" NVIM_VERSION_HASH)
endif()

if(NOT "${NVIM_VERSION_HASH}" STREQUAL "${CURRENT_VERSION_HASH}")
  message(STATUS "Using NVIM_VERSION: ${NVIM_VERSION}")
  file(WRITE "${OUTPUT}" "${NVIM_VERSION_STRING}")
  if(WIN32)
    configure_file("${OUTPUT}" "${OUTPUT}" NEWLINE_STYLE UNIX)
  endif()
endif()
