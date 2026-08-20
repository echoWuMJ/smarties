cmake_minimum_required(VERSION 3.5)

function(exact_failure message_text)
  message(FATAL_ERROR "exact training update protocol failed: ${message_text}")
endfunction()

function(extract_step line output)
  if("${line}" MATCHES "(^| )step=([0-9]+)( |$)")
    set(${output} "${CMAKE_MATCH_2}" PARENT_SCOPE)
  else()
    exact_failure("audit record has no integer step: ${line}")
  endif()
endfunction()

function(require_updates path expected_count expected_first expected_last)
  if(NOT EXISTS "${path}")
    exact_failure("missing audit log ${path}")
  endif()
  file(STRINGS "${path}" updates
       REGEX "^SMARTIES_NETWORK_AUDIT .*stage=update ")
  list(LENGTH updates update_count)
  if(NOT update_count EQUAL expected_count)
    exact_failure("expected ${expected_count} updates, observed ${update_count}")
  endif()
  list(GET updates 0 first_record)
  list(GET updates -1 last_record)
  extract_step("${first_record}" first_step)
  extract_step("${last_record}" last_step)
  if(NOT first_step EQUAL expected_first OR NOT last_step EQUAL expected_last)
    exact_failure("update step range is ${first_step}..${last_step}, expected ${expected_first}..${expected_last}")
  endif()
  foreach(record IN LISTS updates)
    if(NOT record MATCHES "(^| )finite=1( |$)")
      exact_failure("non-finite update record: ${record}")
    endif()
  endforeach()
endfunction()

foreach(required MPIEXEC_EXECUTABLE MPIEXEC_NUMPROC_FLAG PROBE_EXECUTABLE
                 SETTINGS_FILE RUN_ROOT)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    exact_failure("missing ${required}")
  endif()
endforeach()
if(NOT EXISTS "${PROBE_EXECUTABLE}" OR NOT EXISTS "${SETTINGS_FILE}")
  exact_failure("probe executable or settings file does not exist")
endif()

file(REMOVE_RECURSE "${RUN_ROOT}")
file(MAKE_DIRECTORY "${RUN_ROOT}/fresh/audit" "${RUN_ROOT}/restart/audit")
configure_file("${SETTINGS_FILE}" "${RUN_ROOT}/fresh/settings.json" COPYONLY)
configure_file("${SETTINGS_FILE}" "${RUN_ROOT}/restart/settings.json" COPYONLY)

set(common_args
  --nMasters 1 --nThreads 1 --nEnvironments 1
  --workerProcessesPerEnv 1 --learnersOnWorkers 0
  --nTrainUpdates 2 --randSeed 11 --redirectAppStdoutToFile 0)

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 2
          ${MPIEXEC_PREFLAGS} "${PROBE_EXECUTABLE}" ${common_args}
          --learnerAuditDir "${RUN_ROOT}/fresh/audit"
          --restart none --syntheticProtocolCheck ${MPIEXEC_POSTFLAGS}
  WORKING_DIRECTORY "${RUN_ROOT}/fresh"
  RESULT_VARIABLE fresh_status
  OUTPUT_FILE "${RUN_ROOT}/fresh/stdout.log"
  ERROR_FILE "${RUN_ROOT}/fresh/stderr.log"
  TIMEOUT 60)
if(NOT fresh_status EQUAL 0)
  exact_failure("fresh child status is ${fresh_status}")
endif()
require_updates("${RUN_ROOT}/fresh/audit/learner_audit.log" 2 1 2)

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 2
          ${MPIEXEC_PREFLAGS} "${PROBE_EXECUTABLE}" ${common_args}
          --learnerAuditDir "${RUN_ROOT}/restart/audit"
          --restart "${RUN_ROOT}/fresh/audit/final" ${MPIEXEC_POSTFLAGS}
  WORKING_DIRECTORY "${RUN_ROOT}/restart"
  RESULT_VARIABLE restart_status
  OUTPUT_FILE "${RUN_ROOT}/restart/stdout.log"
  ERROR_FILE "${RUN_ROOT}/restart/stderr.log"
  TIMEOUT 60)
if(NOT restart_status EQUAL 0)
  exact_failure("restart child status is ${restart_status}")
endif()

set(restart_audit "${RUN_ROOT}/restart/audit/learner_audit.log")
file(STRINGS "${restart_audit}" restart_records
     REGEX "^SMARTIES_NETWORK_AUDIT .*stage=restart ")
file(STRINGS "${restart_audit}" final_records
     REGEX "^SMARTIES_NETWORK_AUDIT .*stage=final ")
if(NOT restart_records OR NOT final_records)
  exact_failure("restart or final audit record is missing")
endif()
list(GET restart_records -1 restart_record)
list(GET final_records -1 final_record)
extract_step("${restart_record}" restart_step)
extract_step("${final_record}" final_step)
math(EXPR expected_first "${restart_step} + 1")
math(EXPR expected_final "${restart_step} + 2")
require_updates("${restart_audit}" 2 "${expected_first}" "${expected_final}")
if(NOT final_step EQUAL expected_final)
  exact_failure("restart performed ${final_step}-${restart_step}, expected two additional updates")
endif()

message(STATUS "SMARTIES_EXACT_TRAIN_UPDATES status=PASS fresh=2 restart_additional=2")
