cmake_minimum_required(VERSION 3.16)

foreach(required PROBE_EXECUTABLE COMPARE_MODULE RUN_ROOT)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "network update fixture requires ${required}")
  endif()
endforeach()

if(NOT EXISTS "${PROBE_EXECUTABLE}")
  message(FATAL_ERROR "network update probe does not exist: ${PROBE_EXECUTABLE}")
endif()
if(NOT EXISTS "${COMPARE_MODULE}")
  message(FATAL_ERROR "network update comparator does not exist: ${COMPARE_MODULE}")
endif()

file(REMOVE_RECURSE "${RUN_ROOT}")
file(MAKE_DIRECTORY "${RUN_ROOT}")

function(run_probe label threads updates)
  set(audit "${RUN_ROOT}/${label}.audit")
  execute_process(
    COMMAND "${PROBE_EXECUTABLE}"
      --threads "${threads}"
      --updates "${updates}"
      --seed 11
      --audit-file "${audit}"
      ${ARGN}
    WORKING_DIRECTORY "${RUN_ROOT}"
    RESULT_VARIABLE status
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr)
  file(WRITE "${RUN_ROOT}/${label}.stdout" "${stdout}")
  file(WRITE "${RUN_ROOT}/${label}.stderr" "${stderr}")
  if(NOT status EQUAL 0)
    message(FATAL_ERROR
      "network update probe ${label} failed: status=${status}\n${stderr}")
  endif()
  if(NOT EXISTS "${audit}")
    message(FATAL_ERROR "network update probe ${label} produced no audit")
  endif()
endfunction()

run_probe(repeat_a 1 1)
run_probe(repeat_b 1 1)
run_probe(threaded 4 1)
run_probe(long 1 200)

set(checkpoint_dir "${RUN_ROOT}/checkpoint")
file(MAKE_DIRECTORY "${checkpoint_dir}")
run_probe(checkpoint7 1 7 --checkpoint-dir "${checkpoint_dir}")
run_probe(resumed8 1 1 --restart-dir "${checkpoint_dir}")
run_probe(continuous8 1 8)

set(REPEAT_A_FILE "${RUN_ROOT}/repeat_a.audit")
set(REPEAT_B_FILE "${RUN_ROOT}/repeat_b.audit")
set(THREADED_FILE "${RUN_ROOT}/threaded.audit")
set(LONG_FILE "${RUN_ROOT}/long.audit")
set(CHECKPOINT_FILE "${RUN_ROOT}/checkpoint7.audit")
set(RESUMED_FILE "${RUN_ROOT}/resumed8.audit")
set(CONTINUOUS_FILE "${RUN_ROOT}/continuous8.audit")
include("${COMPARE_MODULE}")
