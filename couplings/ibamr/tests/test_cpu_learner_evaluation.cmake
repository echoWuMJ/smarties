cmake_minimum_required(VERSION 3.5)

function(evaluation_failure message_text)
  message(FATAL_ERROR "CPU learner evaluation protocol failed: ${message_text}")
endfunction()

foreach(required MPIEXEC_EXECUTABLE MPIEXEC_NUMPROC_FLAG PROBE_EXECUTABLE
                 SETTINGS_FILE RUN_ROOT)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    evaluation_failure("missing ${required}")
  endif()
endforeach()
if(NOT EXISTS "${PROBE_EXECUTABLE}" OR NOT EXISTS "${SETTINGS_FILE}")
  evaluation_failure("probe executable or settings file does not exist")
endif()

file(REMOVE_RECURSE "${RUN_ROOT}")
file(MAKE_DIRECTORY "${RUN_ROOT}/training/audit"
                    "${RUN_ROOT}/evaluation/audit")
configure_file("${SETTINGS_FILE}" "${RUN_ROOT}/training/settings.json" COPYONLY)
configure_file("${SETTINGS_FILE}" "${RUN_ROOT}/evaluation/settings.json" COPYONLY)

set(common_args
  --nMasters 1 --nThreads 1 --nEnvironments 1
  --workerProcessesPerEnv 1 --learnersOnWorkers 0
  --randSeed 11 --redirectAppStdoutToFile 0 --syntheticProtocolCheck)

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 2
          ${MPIEXEC_PREFLAGS} "${PROBE_EXECUTABLE}" ${common_args}
          --nTrainUpdates 2
          --learnerAuditDir "${RUN_ROOT}/training/audit"
          --restart none ${MPIEXEC_POSTFLAGS}
  WORKING_DIRECTORY "${RUN_ROOT}/training"
  RESULT_VARIABLE training_status
  OUTPUT_FILE "${RUN_ROOT}/training/stdout.log"
  ERROR_FILE "${RUN_ROOT}/training/stderr.log"
  TIMEOUT 60)
if(NOT training_status EQUAL 0)
  evaluation_failure("checkpoint training status is ${training_status}")
endif()

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 2
          ${MPIEXEC_PREFLAGS} "${PROBE_EXECUTABLE}" ${common_args}
          --nTrainSteps 0 --nEvalEpisodes 2
          --learnerAuditDir "${RUN_ROOT}/evaluation/audit"
          --restart "${RUN_ROOT}/training/audit/final" ${MPIEXEC_POSTFLAGS}
  WORKING_DIRECTORY "${RUN_ROOT}/evaluation"
  RESULT_VARIABLE evaluation_status
  OUTPUT_FILE "${RUN_ROOT}/evaluation/stdout.log"
  ERROR_FILE "${RUN_ROOT}/evaluation/stderr.log"
  TIMEOUT 8)
if(NOT evaluation_status EQUAL 0)
  evaluation_failure("evaluation child status is ${evaluation_status}")
endif()

set(stdout_path "${RUN_ROOT}/evaluation/stdout.log")
# Smarties progress messages use carriage returns, so the first transition
# after a progress update may not begin at column zero in the captured file.
file(STRINGS "${stdout_path}" decisions REGEX "SMARTIES_SYNTHETIC_STEP ")
file(STRINGS "${stdout_path}" episodes REGEX "SMARTIES_SYNTHETIC_EPISODE ")
file(STRINGS "${stdout_path}" summaries REGEX "SMARTIES_SYNTHETIC_SUMMARY ")
list(LENGTH decisions decision_count)
list(LENGTH episodes episode_count)
list(LENGTH summaries summary_count)
if(NOT decision_count EQUAL 64 OR NOT episode_count EQUAL 2 OR
   NOT summary_count EQUAL 1)
  evaluation_failure("observed decisions=${decision_count}, episodes=${episode_count}, summaries=${summary_count}")
endif()
list(GET summaries 0 summary)
if(NOT summary MATCHES "(^| )episodes=2( |$)" OR
   NOT summary MATCHES "(^| )decisions=64( |$)" OR
   NOT summary MATCHES "(^| )finite=1( |$)")
  evaluation_failure("malformed evaluation summary: ${summary}")
endif()

set(audit_path "${RUN_ROOT}/evaluation/audit/learner_audit.log")
if(NOT EXISTS "${audit_path}")
  evaluation_failure("missing evaluation audit log")
endif()
file(STRINGS "${audit_path}" updates
     REGEX "^SMARTIES_NETWORK_AUDIT .*stage=update ")
if(updates)
  evaluation_failure("frozen evaluation performed an optimizer update")
endif()

message(STATUS "SMARTIES_CPU_EVALUATION status=PASS episodes=2 decisions=64 updates=0")
