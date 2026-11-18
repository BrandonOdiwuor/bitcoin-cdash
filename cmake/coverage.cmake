# LLVM source-based coverage for the "unit-coverage" CDash profile.
#
# Included by cdash.cmake. Follows doc/developer-notes.md in Bitcoin Core
# ("Compiling for test coverage" -> "Using LLVM/Clang toolchain"):
# build with -fprofile-instr-generate -fcoverage-mapping, run the unit tests
# with LLVM_PROFILE_FILE set, merge with llvm-profdata and report with llvm-cov.

# Captured at file scope: inside a function CMAKE_CURRENT_LIST_DIR is the
# directory of the calling script, not of this file.
set(_cdash_coverage_dir "${CMAKE_CURRENT_LIST_DIR}")

# Configure options for the unit-coverage profile, appended to <out_var>.
function(unit_coverage_configure_options out_var)
  # The flags contain spaces, so each -D argument is quoted for
  # CTEST_CONFIGURE_COMMAND, which is split like a shell command line.
  set(_cov_flags "-fprofile-instr-generate -fcoverage-mapping")
  set(_opts ${${out_var}})
  list(APPEND _opts
    "-DBUILD_TESTS=ON"
    "-DENABLE_WALLET=ON"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_CXX_COMPILER=clang++"
    "\"-DAPPEND_CFLAGS=${_cov_flags}\""
    "\"-DAPPEND_CXXFLAGS=${_cov_flags}\""
    "-DAPPEND_LDFLAGS=-fprofile-instr-generate"
  )
  set(${out_var} "${_opts}" PARENT_SCOPE)
endfunction()

# Runs the unit tests with profiling enabled, produces the coverage reports
# and (with CDASH_COVERAGE_SUBMIT) submits Cobertura coverage to CDash.
# Sets test_result and coverage_result in the caller's scope.
function(run_unit_coverage)
  if(NOT DEFINED CDASH_COVERAGE_SUBMIT)
    set(CDASH_COVERAGE_SUBMIT ON)
  endif()

  # Each instrumented process writes its own raw profile (%m = binary
  # signature, %p = pid), so parallel test processes do not clobber each other.
  set(_cov_dir "${CTEST_BINARY_DIRECTORY}/raw_profile_data")
  file(REMOVE_RECURSE "${_cov_dir}")
  file(MAKE_DIRECTORY "${_cov_dir}")
  set(ENV{LLVM_PROFILE_FILE} "${_cov_dir}/%m_%p.profraw")
  ctest_test(PARALLEL_LEVEL ${CDASH_JOBS} RETURN_VALUE _test_result)
  set(test_result "${_test_result}" PARENT_SCOPE)
  cdash_submit_part(Test)
  unset(ENV{LLVM_PROFILE_FILE})

  set(coverage_result 1 PARENT_SCOPE)

  # Locate LLVM tools next to the compiler first, so the profile format
  # matches the clang that produced it.
  find_program(_clang clang)
  set(_llvm_hints "")
  if(_clang)
    get_filename_component(_clang_real "${_clang}" REALPATH)
    get_filename_component(_llvm_bin "${_clang_real}" DIRECTORY)
    list(APPEND _llvm_hints "${_llvm_bin}")
  endif()
  find_program(LLVM_PROFDATA NAMES llvm-profdata HINTS ${_llvm_hints} REQUIRED)
  find_program(LLVM_COV NAMES llvm-cov HINTS ${_llvm_hints} REQUIRED)
  if(CDASH_COVERAGE_SUBMIT)
    find_program(PYTHON3 NAMES python3 REQUIRED)
  endif()

  file(GLOB_RECURSE _profraw "${_cov_dir}/*.profraw")
  list(LENGTH _profraw _nprofraw)
  message(STATUS "Coverage: ${_nprofraw} .profraw files in ${_cov_dir}")
  if(_nprofraw EQUAL 0)
    return()
  endif()

  set(_test_bitcoin "${CTEST_BINARY_DIRECTORY}/bin/test_bitcoin")
  if(NOT EXISTS "${_test_bitcoin}")
    message(WARNING "Coverage: ${_test_bitcoin} not found")
    return()
  endif()

  string(REPLACE ";" "\n" _profraw_txt "${_profraw}")
  file(WRITE "${CTEST_BINARY_DIRECTORY}/raw_profile_data_files.txt" "${_profraw_txt}\n")
  # Not named *.profdata on purpose: CMake >= 4.x ctest_coverage() globs
  # the binary dir for *.profdata and then runs its own Clang handler, which
  # needs extra CTest configuration and crashed on this tree. The
  # Cobertura path below works the same on older CTest (e.g. 3.28 on CI).
  set(_profdata "${CTEST_BINARY_DIRECTORY}/coverage.profmerged")
  execute_process(
    COMMAND "${LLVM_PROFDATA}" merge -sparse
            -f "${CTEST_BINARY_DIRECTORY}/raw_profile_data_files.txt"
            -o "${_profdata}"
    RESULT_VARIABLE _merge_rc)

  set(_ignore "src/crc32c/|src/leveldb/|src/minisketch/|src/secp256k1/|src/test/")
  # Restrict reports to the Bitcoin Core tree (drops libstdc++/boost headers).
  set(_cov_sources "${CTEST_SOURCE_DIRECTORY}/src")
  set(_html "${CTEST_BINARY_DIRECTORY}/coverage_html")
  file(REMOVE_RECURSE "${_html}")
  set(_show_rc 1)
  set(_export_rc 1)
  set(_cob_rc "skipped")
  if(_merge_rc EQUAL 0)
    execute_process(
      COMMAND "${LLVM_COV}" show "${_test_bitcoin}"
              -instr-profile=${_profdata}
              -ignore-filename-regex=${_ignore}
              ${_cov_sources}
              -format=html -show-line-counts-or-regions -show-branches=count
              -show-expansions -output-dir=${_html}
      RESULT_VARIABLE _show_rc)
    execute_process(
      COMMAND "${LLVM_COV}" export "${_test_bitcoin}"
              -instr-profile=${_profdata}
              -ignore-filename-regex=${_ignore}
              ${_cov_sources}
              -format=lcov
      OUTPUT_FILE "${CTEST_BINARY_DIRECTORY}/coverage.lcov"
      RESULT_VARIABLE _export_rc)
    execute_process(
      COMMAND "${LLVM_COV}" report "${_test_bitcoin}"
              -instr-profile=${_profdata}
              -ignore-filename-regex=${_ignore}
              ${_cov_sources}
              -summary-only
      OUTPUT_FILE "${CTEST_BINARY_DIRECTORY}/coverage_summary.txt")
    # CTest cannot read LLVM profiles, but it reads Cobertura XML from
    # ${CTEST_BINARY_DIRECTORY}/coverage.xml in ctest_coverage().
    if(CDASH_COVERAGE_SUBMIT AND _export_rc EQUAL 0)
      execute_process(
        COMMAND "${PYTHON3}" "${_cdash_coverage_dir}/llvm_cov_to_cobertura.py"
                "${CTEST_BINARY_DIRECTORY}/coverage.lcov"
                "${CTEST_BINARY_DIRECTORY}/coverage.xml"
                "${CTEST_SOURCE_DIRECTORY}"
        RESULT_VARIABLE _cob_rc)
    endif()
  endif()
  message(STATUS "Coverage: merge=${_merge_rc} html=${_show_rc} lcov=${_export_rc} cobertura=${_cob_rc}")
  message(STATUS "Coverage HTML: ${_html}/index.html")

  if(NOT (_merge_rc EQUAL 0 AND _show_rc EQUAL 0))
    return()
  endif()
  if(NOT CDASH_COVERAGE_SUBMIT)
    message(STATUS "Coverage: CDASH_COVERAGE_SUBMIT=OFF, skipping Cobertura/ctest_coverage/submit")
    set(coverage_result 0 PARENT_SCOPE)
    return()
  endif()
  if(_cob_rc EQUAL 0)
    unset(ENV{COBERTURADIR})
    ctest_coverage(RETURN_VALUE _coverage_result)
    set(coverage_result "${_coverage_result}" PARENT_SCOPE)
    cdash_submit_part(Coverage)
  endif()
endfunction()