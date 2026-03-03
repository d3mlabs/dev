# Generic runtime dependency resolver via FetchContent.
# Consumes: deps.lock.cmake (what to fetch), deps.targets.cmake (how to use).
# Generated lockfile/targets via dev deps. Do not edit lockfile/targets by hand.
#
# Projects include this file and optionally a project-local DepsConfig.cmake for
# per-dep cache options (e.g. Boost, googletest build flags).
#
# cmake_target_prefix support: if deps.targets.cmake sets dep_<name>_cmake_target_prefix
# (e.g. "Boost::"), targets are prefixed automatically. This replaces hardcoded dep checks.

if(NOT EXISTS "${CMAKE_SOURCE_DIR}/deps.lock.cmake")
  message(FATAL_ERROR "deps.lock.cmake not found. Run: dev update-deps, commit the lockfile, then run dev up or build.")
endif()
include("${CMAKE_SOURCE_DIR}/deps.lock.cmake")

if(EXISTS "${CMAKE_SOURCE_DIR}/deps.targets.cmake")
  include("${CMAKE_SOURCE_DIR}/deps.targets.cmake")
endif()

# Project-specific cache options (per-dep build flags). Optional.
if(EXISTS "${CMAKE_SOURCE_DIR}/cmake/DepsConfig.cmake")
  include("${CMAKE_SOURCE_DIR}/cmake/DepsConfig.cmake")
endif()

set(PROJECT_CPM_DEPS "")
set(TEST_CPM_DEPS "")

# --- Helpers (require 3.25 for return(PROPAGATE)) ---
cmake_policy(SET CMP0140 NEW)

function(fetch_dep _dep)
  if(DEFINED dep_${_dep}_url)
    set(_url_args URL ${dep_${_dep}_url})
    if(DEFINED dep_${_dep}_hash AND NOT dep_${_dep}_hash STREQUAL "")
      list(APPEND _url_args URL_HASH ${dep_${_dep}_hash})
    endif()
    if(DEFINED dep_${_dep}_tag AND NOT dep_${_dep}_tag STREQUAL "")
      list(APPEND _url_args SOURCE_SUBDIR "${dep_${_dep}_tag}")
    endif()
    FetchContent_Declare(${_dep} ${_url_args})
  else()
    FetchContent_Declare(${_dep}
      GIT_REPOSITORY ${dep_${_dep}_repo}
      GIT_TAG ${dep_${_dep}_sha}
      GIT_SHALLOW FALSE
    )
  endif()
  FetchContent_MakeAvailable(${_dep})
  return(PROPAGATE "${_dep}_SOURCE_DIR" "${_dep}_BINARY_DIR" "${_dep}_POPULATED")
endfunction()

# Resolve one runtime dep to linkables (targets and/or headers shim).
#
# If dep_<name>_cmake_target_prefix is set (e.g. "Boost::"), each target name from
# dep_<name>_cmake_targets is prefixed (e.g. "stacktrace" -> "Boost::stacktrace").
# This generalizes what was previously a hardcoded boost check.
function(resolve_dep_to_linkables _dep _result_var)
  set(_linkables "")
  if(DEFINED dep_${_dep}_cmake_targets)
    # Determine prefix: use dep_<name>_cmake_target_prefix if set, else empty.
    set(_prefix "")
    if(DEFINED dep_${_dep}_cmake_target_prefix)
      set(_prefix "${dep_${_dep}_cmake_target_prefix}")
    endif()

    foreach(_t ${dep_${_dep}_cmake_targets})
      set(_link_t "${_prefix}${_t}")
      if(TARGET ${_link_t})
        list(APPEND _linkables ${_link_t})
      else()
        message(WARNING "Declared CMake target '${_link_t}' for runtime dep '${_dep}' not found; check its CMake config")
      endif()
    endforeach()

    # Headers shim: targets may not propagate SOURCE_DIR as include.
    set(_shim_target "dep_${_dep}_headers")
    if(NOT TARGET ${_shim_target})
      add_library(${_shim_target} INTERFACE)
      if(DEFINED dep_${_dep}_includes)
        foreach(_inc ${dep_${_dep}_includes})
          target_include_directories(${_shim_target} INTERFACE "${${_dep}_SOURCE_DIR}/${_inc}")
        endforeach()
      else()
        target_include_directories(${_shim_target} INTERFACE "${${_dep}_SOURCE_DIR}")
      endif()
    endif()
    list(APPEND _linkables ${_shim_target})
  elseif(DEFINED dep_${_dep}_includes)
    set(_shim_target "dep_${_dep}_headers")
    if(NOT TARGET ${_shim_target})
      add_library(${_shim_target} INTERFACE)
      foreach(_inc ${dep_${_dep}_includes})
        target_include_directories(${_shim_target} INTERFACE "${${_dep}_SOURCE_DIR}/${_inc}")
      endforeach()
    endif()
    list(APPEND _linkables ${_shim_target})
  else()
    list(APPEND _linkables ${_dep})
  endif()
  set(${_result_var} "${_linkables}" PARENT_SCOPE)
endfunction()

function(process_runtime_deps _deps_list _out_list_var)
  set(_accumulated ${${_out_list_var}})
  foreach(_dep ${_deps_list})
    fetch_dep(${_dep})
    resolve_dep_to_linkables(${_dep} _linkables)
    list(APPEND _accumulated ${_linkables})
  endforeach()
  set(${_out_list_var} "${_accumulated}" PARENT_SCOPE)
endfunction()

# --- Process deps ---
process_runtime_deps("${RUNTIME_DEPS_APP}" PROJECT_CPM_DEPS)
if(DEFINED RUNTIME_DEPS_TEST)
  process_runtime_deps("${RUNTIME_DEPS_TEST}" TEST_CPM_DEPS)
endif()
