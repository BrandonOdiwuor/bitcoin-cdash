# Profiles: unit | unit-nowallet | unit-asan | unit-gcc | functional
cmake_minimum_required(VERSION 3.25)

if(NOT CTEST_SOURCE_DIRECTORY)
  set(CTEST_SOURCE_DIRECTORY "$ENV{BITCOIN_SOURCE_DIR}")
endif()
get_filename_component(CTEST_SOURCE_DIRECTORY "${CTEST_SOURCE_DIRECTORY}" ABSOLUTE)

if(NOT EXISTS "${CTEST_SOURCE_DIRECTORY}/CMakeLists.txt")
  message(FATAL_ERROR "Set BITCOIN_SOURCE_DIR to a Bitcoin Core tree")
endif()

if(NOT CDASH_PROFILE)
  set(CDASH_PROFILE "unit")
endif()
if(NOT CDASH_MODEL)
  set(CDASH_MODEL "Experimental")
endif()
if(NOT DEFINED CDASH_SUBMIT)
  set(CDASH_SUBMIT ON)
endif()

set(_profile_ok FALSE)
foreach(_p unit unit-nowallet unit-asan unit-gcc functional)
  if(CDASH_PROFILE STREQUAL _p)
    set(_profile_ok TRUE)
  endif()
endforeach()
if(NOT _profile_ok)
  message(FATAL_ERROR "CDASH_PROFILE must be unit, unit-nowallet, unit-asan, unit-gcc, or functional")
endif()

if(NOT CDASH_MODEL STREQUAL "Experimental" AND NOT CDASH_MODEL STREQUAL "Nightly")
  message(FATAL_ERROR "CDASH_MODEL must be Experimental or Nightly")
endif()

if(NOT CDASH_JOBS AND DEFINED ENV{CDASH_JOBS})
  set(CDASH_JOBS "$ENV{CDASH_JOBS}")
endif()
if(NOT CDASH_JOBS)
  include(ProcessorCount)
  ProcessorCount(CDASH_JOBS)
endif()
if(NOT CDASH_JOBS OR CDASH_JOBS EQUAL 0)
  set(CDASH_JOBS 1)
endif()

set(CTEST_BINARY_DIRECTORY "${CTEST_SOURCE_DIRECTORY}/build-${CDASH_PROFILE}")
set(CTEST_CMAKE_GENERATOR "Ninja")
set(CTEST_USE_LAUNCHERS ON)
set(CTEST_UPDATE_VERSION_ONLY ON)
find_program(CTEST_UPDATE_COMMAND git)
site_name(CTEST_SITE)

execute_process(
  COMMAND git -C "${CTEST_SOURCE_DIRECTORY}" describe --tags --always --dirty
  OUTPUT_VARIABLE _git_desc OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT _git_desc)
  set(_git_desc "unknown")
endif()
set(CTEST_BUILD_NAME "${CDASH_PROFILE}-${CMAKE_HOST_SYSTEM_NAME}-${_git_desc}")

set(_submit_url "${CTEST_SUBMIT_URL}")
if(NOT _submit_url)
  set(_submit_url "http://127.0.0.1:8080/submit.php?project=core")
endif()

function(cdash_submit_part part)
  if(NOT CDASH_SUBMIT)
    return()
  endif()
  ctest_submit(PARTS ${part} RETRY_COUNT 3 RETRY_DELAY 5)
endfunction()

get_filename_component(_launchers "${CMAKE_CURRENT_LIST_DIR}/enable_launchers.cmake" ABSOLUTE)

set(_opts
  "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
  "-DBUILD_GUI=OFF"
  "-DBUILD_GUI_TESTS=OFF"
  "-DBUILD_BENCH=OFF"
  "-DBUILD_FUZZ_BINARY=OFF"
  "-DENABLE_IPC=OFF"
  "-DCTEST_USE_LAUNCHERS=ON"
  "-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=${_launchers}"
)

if(CDASH_PROFILE STREQUAL "unit")
  list(APPEND _opts
    "-DBUILD_TESTS=ON"
    "-DENABLE_WALLET=ON"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_CXX_COMPILER=clang++"
  )
elseif(CDASH_PROFILE STREQUAL "unit-nowallet")
  list(APPEND _opts
    "-DBUILD_TESTS=ON"
    "-DENABLE_WALLET=OFF"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_CXX_COMPILER=clang++"
  )
elseif(CDASH_PROFILE STREQUAL "unit-asan")
  list(APPEND _opts
    "-DBUILD_TESTS=ON"
    "-DENABLE_WALLET=ON"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_CXX_COMPILER=clang++"
    "-DSANITIZERS=address,undefined"
  )
elseif(CDASH_PROFILE STREQUAL "unit-gcc")
  list(APPEND _opts
    "-DBUILD_TESTS=ON"
    "-DENABLE_WALLET=ON"
    "-DCMAKE_C_COMPILER=gcc"
    "-DCMAKE_CXX_COMPILER=g++"
  )
elseif(CDASH_PROFILE STREQUAL "functional")
  list(APPEND _opts
    "-DBUILD_TESTS=OFF"
    "-DBUILD_FUNCTIONAL_TESTS=ON"
    "-DENABLE_WALLET=ON"
    "-DBUILD_DAEMON=ON"
    "-DBUILD_CLI=ON"
    "-DBUILD_BENCH=ON"
    "-DBUILD_UTIL=ON"
    "-DBUILD_UTIL_CHAINSTATE=ON"
    "-DBUILD_WALLET_TOOL=ON"
    "-DWITH_ZMQ=ON"
    "-DENABLE_IPC=ON"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_CXX_COMPILER=clang++"
  )
endif()

set(CTEST_CONFIGURE_COMMAND "${CMAKE_COMMAND} -S ${CTEST_SOURCE_DIRECTORY} -B ${CTEST_BINARY_DIRECTORY} -G Ninja")
foreach(_o IN LISTS _opts)
  string(APPEND CTEST_CONFIGURE_COMMAND " ${_o}")
endforeach()

message(STATUS "Model  : ${CDASH_MODEL}")
message(STATUS "Profile: ${CDASH_PROFILE}")
message(STATUS "Jobs   : ${CDASH_JOBS}")
message(STATUS "Source : ${CTEST_SOURCE_DIRECTORY}")
message(STATUS "Binary : ${CTEST_BINARY_DIRECTORY}")
message(STATUS "Name   : ${CTEST_BUILD_NAME}")
message(STATUS "Submit : ${_submit_url}")

file(MAKE_DIRECTORY "${CTEST_BINARY_DIRECTORY}")

ctest_start(${CDASH_MODEL})
set(CTEST_SUBMIT_URL "${_submit_url}")
cdash_submit_part(Start)

if(CTEST_UPDATE_COMMAND)
  ctest_update()
  cdash_submit_part(Update)
endif()

ctest_configure(RETURN_VALUE configure_result)
cdash_submit_part(Configure)

ctest_build(
  PARALLEL_LEVEL ${CDASH_JOBS}
  NUMBER_ERRORS build_errors
  NUMBER_WARNINGS build_warnings
  RETURN_VALUE build_result
)
cdash_submit_part(Build)

if(CDASH_PROFILE STREQUAL "unit-asan")
  set(CTEST_MEMORYCHECK_TYPE "AddressSanitizer")
  set(CTEST_MEMORYCHECK_SANITIZER_OPTIONS "detect_leaks=1:abort_on_error=1")
  ctest_memcheck(PARALLEL_LEVEL ${CDASH_JOBS} RETURN_VALUE test_result)
  cdash_submit_part(MemCheck)
elseif(CDASH_PROFILE STREQUAL "functional")
  ctest_test(
    INCLUDE_LABEL "functional"
    EXCLUDE_LABEL "extended"
    PARALLEL_LEVEL ${CDASH_JOBS}
    RETURN_VALUE test_result
  )
  cdash_submit_part(Test)
else()
  ctest_test(PARALLEL_LEVEL ${CDASH_JOBS} RETURN_VALUE test_result)
  cdash_submit_part(Test)
endif()

cdash_submit_part(Done)

if(NOT CDASH_SUBMIT)
  message(STATUS "Skipping submit")
endif()

message(STATUS "configure=${configure_result} build=${build_result} "
               "errors=${build_errors} warnings=${build_warnings} "
               "test=${test_result}")

if(configure_result OR build_result OR test_result)
  message(FATAL_ERROR "Dashboard failed")
endif()