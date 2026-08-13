foreach(required ORCHESTRATOR FAKE_PROBE REGISTRATION_FILE)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "orchestration fixture requires ${required}")
  endif()
endforeach()

get_filename_component(actual_registration "${REGISTRATION_FILE}" REALPATH)
get_filename_component(expected_registration "${CMAKE_CURRENT_LIST_DIR}/CMakeLists.txt" REALPATH)
if(NOT actual_registration STREQUAL expected_registration)
  message(FATAL_ERROR
    "REGISTRATION_FILE must point to tests/CMakeLists.txt; got '${actual_registration}'")
endif()

file(READ "${REGISTRATION_FILE}" registration)
function(read_test_registration test_name next_test_name output)
  string(FIND "${registration}" "add_test(\n    NAME ${test_name}" start)
  string(FIND "${registration}" "add_test(\n    NAME ${next_test_name}" finish)
  if(start EQUAL -1 OR finish EQUAL -1 OR NOT finish GREATER start)
    message(FATAL_ERROR "cannot isolate ${test_name} CTest registration")
  endif()
  math(EXPR length "${finish} - ${start}")
  string(SUBSTRING "${registration}" ${start} ${length} block)
  set(${output} "${block}" PARENT_SCOPE)
endfunction()

read_test_registration(eel_layout_mismatch_guard frequency_response_probe layout_registration)
read_test_registration(eel_mpi_consistency eel_smoke_protocol consistency_registration)
string(REGEX MATCHALL "-DCHILD_TIMEOUT_SECONDS=900" layout_timeouts "${layout_registration}")
string(REGEX MATCHALL "-DCHILD_TIMEOUT_SECONDS=900" consistency_timeouts "${consistency_registration}")
list(LENGTH layout_timeouts layout_timeout_count)
list(LENGTH consistency_timeouts consistency_timeout_count)
if(NOT layout_timeout_count EQUAL 0 OR NOT consistency_timeout_count EQUAL 1)
  message(FATAL_ERROR
    "CHILD_TIMEOUT_SECONDS registration must occur once on eel_mpi_consistency and never on eel_layout_mismatch_guard; got consistency=${consistency_timeout_count} layout=${layout_timeout_count}")
endif()

string(FIND "${registration}" "add_test(\n  NAME eel_mpi_consistency_orchestration" orchestration_start)
string(FIND "${registration}" "\nif(UNIX)" orchestration_finish)
if(orchestration_start EQUAL -1 OR orchestration_finish EQUAL -1 OR
   NOT orchestration_finish GREATER orchestration_start)
  message(FATAL_ERROR "cannot isolate eel_mpi_consistency_orchestration CTest registration")
endif()
math(EXPR orchestration_length "${orchestration_finish} - ${orchestration_start}")
string(SUBSTRING "${registration}" ${orchestration_start} ${orchestration_length}
  orchestration_registration)
string(REGEX MATCHALL "-DREGISTRATION_FILE=" registration_arguments
  "${orchestration_registration}")
list(LENGTH registration_arguments registration_argument_count)
string(FIND "${orchestration_registration}"
  [=["-DREGISTRATION_FILE=${CMAKE_CURRENT_LIST_FILE}"]=]
  registration_value_match)
if(NOT registration_argument_count EQUAL 1 OR registration_value_match EQUAL -1)
  message(FATAL_ERROR
    "eel_mpi_consistency_orchestration must pass REGISTRATION_FILE exactly once as tests/CMakeLists.txt")
endif()

set(root "${CMAKE_CURRENT_BINARY_DIR}/eel-mpi-consistency-orchestration")
file(REMOVE_RECURSE "${root}")
file(MAKE_DIRECTORY "${root}/source")
foreach(name input2d eel2d.vertex task.conf)
  file(WRITE "${root}/source/${name}" "fixture ${name}\n")
endforeach()

file(WRITE "${root}/poison-comparator.cmake"
  "message(FATAL_ERROR \"physics comparator must not run after an operational timeout\")\n")

if(WIN32)
  set(fake_launcher "${root}/fake-mpiexec.cmd")
  file(WRITE "${fake_launcher}" "@echo off\r\n\"${CMAKE_COMMAND}\" \"-DFAKE_RANK=%2\" -DINPUT_FILE=input2d -DTASK_FILE=task.conf -DACTION=1.0 -DDECISIONS=2 -DFAKE_SLEEP_SECONDS=2 -P \"%~3\"\r\nexit /b %ERRORLEVEL%\r\n")
else()
  set(fake_launcher "${root}/fake-mpiexec")
  file(WRITE "${fake_launcher}" "#!/bin/sh\nexec \"${CMAKE_COMMAND}\" \"-DFAKE_RANK=$2\" -DINPUT_FILE=input2d -DTASK_FILE=task.conf -DACTION=1.0 -DDECISIONS=2 -DFAKE_SLEEP_SECONDS=2 -P \"$3\"\n")
  file(CHMOD "${fake_launcher}"
    PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
endif()

function(run_case name expected_status expected_verdict)
  set(case_root "${root}/${name}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DPROBE_EXECUTABLE=${FAKE_PROBE}"
      "-DDRY_FIXTURE_MODE=ON"
      "-DINPUT_FILE=${root}/source/input2d"
      "-DVERTEX_FILE=${root}/source/eel2d.vertex"
      "-DTASK_FILE=${root}/source/task.conf"
      "-DCOMPARE_MODULE=${CMAKE_CURRENT_LIST_DIR}/EelConsistencyCompare.cmake"
      "-DRUN_ROOT=${case_root}"
      ${ARGN}
      -P "${ORCHESTRATOR}"
    RESULT_VARIABLE status OUTPUT_VARIABLE stdout ERROR_VARIABLE stderr)
  if(NOT status EQUAL expected_status)
    message(FATAL_ERROR
      "${name}: expected status ${expected_status}, got ${status}\n${stdout}\n${stderr}")
  endif()
  file(READ "${case_root}/report.txt" report)
  if(NOT report MATCHES "^${expected_verdict}")
    message(FATAL_ERROR "${name}: unexpected report '${report}'")
  endif()
  foreach(rank 1 2)
    foreach(file stdout.log stderr.log status.txt)
      if(NOT EXISTS "${case_root}/rank-${rank}/${file}")
        message(FATAL_ERROR "${name}: rank-${rank}/${file} was not captured")
      endif()
    endforeach()
    if(NOT expected_verdict STREQUAL "INCONCLUSIVE_OPERATIONAL_TIMEOUT")
      foreach(file input2d eel2d.vertex task.conf)
        if(NOT EXISTS "${case_root}/rank-${rank}/${file}")
          message(FATAL_ERROR "${name}: rank-${rank}/${file} was not isolated")
        endif()
      endforeach()
      file(READ "${case_root}/rank-${rank}/stdout.log" child_stdout)
      if(NOT child_stdout MATCHES
         "FAKE_PROBE_INVOCATION rank=${rank} input-file=input2d task-file=task.conf action=1.0 decisions=2")
        message(FATAL_ERROR
          "${name}: rank ${rank} did not receive the fixed invocation contract:\n${child_stdout}")
      endif()
    endif()
  endforeach()
endfunction()

run_case(matching 0 PASS)
run_case(mutation 1 PHYSICAL_MISMATCH -DFAKE_MUTATE_COM=ON)
run_case(timeout 1 INCONCLUSIVE_OPERATIONAL_TIMEOUT
  -DFAKE_TIMEOUT_RANK=1
  "-DCOMPARE_MODULE=${root}/poison-comparator.cmake")
file(READ "${root}/timeout/rank-2/status.txt" timeout_rank_two)
if(NOT timeout_rank_two STREQUAL "NOT_RUN\n")
  message(FATAL_ERROR "rank 2 ran after rank 1 timeout: '${timeout_rank_two}'")
endif()

set(real_timeout_root "${root}/real-timeout")
execute_process(
  COMMAND "${CMAKE_COMMAND}"
    "-DPROBE_EXECUTABLE=${FAKE_PROBE}"
    "-DMPIEXEC_EXECUTABLE=${fake_launcher}"
    "-DMPIEXEC_NUMPROC_FLAG=-n"
    "-DCHILD_TIMEOUT_SECONDS=0.1"
    "-DINPUT_FILE=${root}/source/input2d"
    "-DVERTEX_FILE=${root}/source/eel2d.vertex"
    "-DTASK_FILE=${root}/source/task.conf"
    "-DCOMPARE_MODULE=${root}/poison-comparator.cmake"
    "-DRUN_ROOT=${real_timeout_root}"
    -P "${ORCHESTRATOR}"
  RESULT_VARIABLE real_timeout_status
  OUTPUT_VARIABLE real_timeout_stdout
  ERROR_VARIABLE real_timeout_stderr)
if(real_timeout_status EQUAL 0)
  message(FATAL_ERROR "real sleep probe incorrectly passed its child timeout")
endif()
file(READ "${real_timeout_root}/report.txt" real_timeout_report)
if(NOT real_timeout_report MATCHES "^INCONCLUSIVE_OPERATIONAL_TIMEOUT")
  message(FATAL_ERROR
    "real child timeout was not classified inconclusive: '${real_timeout_report}'\n${real_timeout_stdout}\n${real_timeout_stderr}")
endif()
file(READ "${real_timeout_root}/rank-2/status.txt" real_timeout_rank_two)
if(NOT real_timeout_rank_two STREQUAL "NOT_RUN\n")
  message(FATAL_ERROR
    "rank 2 ran after a real child timeout: '${real_timeout_rank_two}'")
endif()
