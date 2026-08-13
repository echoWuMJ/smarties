foreach(required ORCHESTRATOR FAKE_PROBE)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "orchestration fixture requires ${required}")
  endif()
endforeach()

set(root "${CMAKE_CURRENT_BINARY_DIR}/eel-mpi-consistency-orchestration")
file(REMOVE_RECURSE "${root}")
file(MAKE_DIRECTORY "${root}/source")
foreach(name input2d eel2d.vertex task.conf)
  file(WRITE "${root}/source/${name}" "fixture ${name}\n")
endforeach()

file(WRITE "${root}/poison-comparator.cmake"
  "message(FATAL_ERROR \"physics comparator must not run after an operational timeout\")\n")

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
