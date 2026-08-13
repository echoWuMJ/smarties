foreach(required PROBE_EXECUTABLE INPUT_FILE VERTEX_FILE TASK_FILE COMPARE_MODULE RUN_ROOT)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "eel MPI consistency orchestrator requires ${required}")
  endif()
endforeach()
foreach(path PROBE_EXECUTABLE INPUT_FILE VERTEX_FILE TASK_FILE COMPARE_MODULE)
  if(NOT EXISTS "${${path}}")
    message(FATAL_ERROR "eel MPI consistency ${path} does not exist: ${${path}}")
  endif()
endforeach()
if(NOT DRY_FIXTURE_MODE)
  foreach(required MPIEXEC_EXECUTABLE MPIEXEC_NUMPROC_FLAG CHILD_TIMEOUT_SECONDS)
    if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
      message(FATAL_ERROR "eel MPI consistency orchestrator requires ${required}")
    endif()
  endforeach()
  if(NOT CHILD_TIMEOUT_SECONDS MATCHES "^[0-9]+([.][0-9]+)?$" OR
     NOT CHILD_TIMEOUT_SECONDS GREATER 0)
    message(FATAL_ERROR "CHILD_TIMEOUT_SECONDS must be positive")
  endif()
endif()

file(REMOVE_RECURSE "${RUN_ROOT}")
file(MAKE_DIRECTORY "${RUN_ROOT}/rank-1" "${RUN_ROOT}/rank-2")
foreach(rank 1 2)
  file(WRITE "${RUN_ROOT}/rank-${rank}/stdout.log" "")
  file(WRITE "${RUN_ROOT}/rank-${rank}/stderr.log" "")
  file(WRITE "${RUN_ROOT}/rank-${rank}/status.txt" "NOT_RUN\n")
endforeach()

function(eel_run_fixed_action_child rank run_directory status_out classification_out)
  file(COPY "${INPUT_FILE}" DESTINATION "${run_directory}")
  file(COPY "${VERTEX_FILE}" DESTINATION "${run_directory}")
  file(COPY "${TASK_FILE}" DESTINATION "${run_directory}")
  get_filename_component(input_name "${INPUT_FILE}" NAME)
  get_filename_component(vertex_name "${VERTEX_FILE}" NAME)
  get_filename_component(task_name "${TASK_FILE}" NAME)
  if(NOT input_name STREQUAL "input2d" OR
     NOT vertex_name STREQUAL "eel2d.vertex" OR
     NOT task_name STREQUAL "task.conf")
    message(FATAL_ERROR
      "eel MPI consistency inputs must be named input2d, eel2d.vertex, and task.conf")
  endif()

  if(DRY_FIXTURE_MODE AND FAKE_TIMEOUT_RANK STREQUAL "${rank}")
    file(WRITE "${run_directory}/stdout.log" "")
    file(WRITE "${run_directory}/stderr.log"
      "fake launcher classification: operational timeout\n")
    file(WRITE "${run_directory}/status.txt" "OPERATIONAL_TIMEOUT\n")
    set(${status_out} "OPERATIONAL_TIMEOUT" PARENT_SCOPE)
    set(${classification_out} "TIMEOUT" PARENT_SCOPE)
    return()
  endif()

  if(DRY_FIXTURE_MODE)
    set(child_command
      "${CMAKE_COMMAND}"
      "-DFAKE_RANK=${rank}"
      "-DINPUT_FILE=input2d"
      "-DTASK_FILE=task.conf"
      "-DACTION=1.0"
      "-DDECISIONS=2")
    if(FAKE_MUTATE_COM)
      list(APPEND child_command "-DFAKE_MUTATE_COM=ON")
    endif()
    list(APPEND child_command -P "${PROBE_EXECUTABLE}")
  else()
    set(child_command
      "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" "${rank}"
      ${MPIEXEC_PREFLAGS} "${PROBE_EXECUTABLE}"
      --input-file input2d
      --task-file task.conf
      --action 1.0
      --decisions 2
      ${MPIEXEC_POSTFLAGS})
  endif()

  execute_process(
    COMMAND ${child_command}
    WORKING_DIRECTORY "${run_directory}"
    RESULT_VARIABLE child_status
    OUTPUT_FILE "${run_directory}/stdout.log"
    ERROR_FILE "${run_directory}/stderr.log"
    TIMEOUT "${CHILD_TIMEOUT_SECONDS}")
  file(WRITE "${run_directory}/status.txt" "${child_status}\n")
  set(${status_out} "${child_status}" PARENT_SCOPE)
  if(child_status MATCHES "[Tt]imeout")
    set(${classification_out} "TIMEOUT" PARENT_SCOPE)
  else()
    set(${classification_out} "EXIT" PARENT_SCOPE)
  endif()
endfunction()

function(eel_write_report verdict detail)
  file(WRITE "${RUN_ROOT}/report.txt" "${verdict}\n${detail}\n")
endfunction()

eel_run_fixed_action_child(1 "${RUN_ROOT}/rank-1" rank_one_status rank_one_classification)
if(rank_one_classification STREQUAL "TIMEOUT")
  eel_write_report("INCONCLUSIVE_OPERATIONAL_TIMEOUT"
    "rank=1 child_status=${rank_one_status}; physics comparator not run")
  message(FATAL_ERROR "eel MPI consistency is inconclusive: rank 1 operational timeout")
elseif(NOT rank_one_status EQUAL 0)
  eel_write_report("MALFORMED" "rank=1 child_status=${rank_one_status}")
  message(FATAL_ERROR "eel MPI consistency rank 1 failed with ${rank_one_status}")
endif()

eel_run_fixed_action_child(2 "${RUN_ROOT}/rank-2" rank_two_status rank_two_classification)
if(rank_two_classification STREQUAL "TIMEOUT")
  eel_write_report("INCONCLUSIVE_OPERATIONAL_TIMEOUT"
    "rank=2 child_status=${rank_two_status}; physics comparator not run")
  message(FATAL_ERROR "eel MPI consistency is inconclusive: rank 2 operational timeout")
elseif(NOT rank_two_status EQUAL 0)
  eel_write_report("MALFORMED" "rank=2 child_status=${rank_two_status}")
  message(FATAL_ERROR "eel MPI consistency rank 2 failed with ${rank_two_status}")
endif()

file(READ "${RUN_ROOT}/rank-1/stdout.log" rank_one_stream)
file(READ "${RUN_ROOT}/rank-2/stdout.log" rank_two_stream)
include("${COMPARE_MODULE}")
compare_eel_consistency_streams(
  ONE_STREAM "${rank_one_stream}"
  TWO_STREAM "${rank_two_stream}"
  EXPECTED_DECISIONS 2
  OUT_VERDICT verdict
  OUT_REPORT comparison_report)
eel_write_report("${verdict}" "${comparison_report}")
if(NOT verdict STREQUAL "PASS")
  message(FATAL_ERROR "eel MPI consistency ${verdict}: ${comparison_report}")
endif()
message(STATUS "eel MPI consistency PASS: ${comparison_report}")
