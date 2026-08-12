foreach(required IN ITEMS TEST_EXECUTABLE MPIEXEC_EXECUTABLE INPUT_FILE)
  if(NOT DEFINED ${required} OR NOT EXISTS "${${required}}")
    message(FATAL_ERROR "${required} is missing: ${${required}}")
  endif()
endforeach()

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 3
          ${MPIEXEC_PREFLAGS} "${TEST_EXECUTABLE}"
          --nMasters 1
          --nThreads 1
          --nEnvironments 1
          --workerProcessesPerEnv 2
          --learnersOnWorkers 0
          --nTrainSteps 0
          --restart none
          --setupFolder .
          --input-file "${INPUT_FILE}"
          --smoke-steps 1
          --fault-after-initialize
          ${MPIEXEC_POSTFLAGS}
  RESULT_VARIABLE status
  OUTPUT_VARIABLE stdout
  ERROR_VARIABLE stderr)
string(CONCAT combined "${stdout}" "\n" "${stderr}")

if(status EQUAL 0)
  message(FATAL_ERROR
    "post-initialize failure injection exited zero:\n${combined}")
endif()

set(expected_diagnostic
  "eel2d environment fatal error: injected failure after IBAMR initialization")
if(NOT combined MATCHES "${expected_diagnostic}")
  message(FATAL_ERROR
    "missing exact post-initialize failure diagnostic (status ${status}):\n"
    "${combined}")
endif()
if(NOT combined MATCHES "MPI_ABORT was invoked on rank")
  message(FATAL_ERROR
    "missing Open MPI abort marker (status ${status}):\n${combined}")
endif()
if(NOT combined MATCHES "[Ee]rrorcode:? 98")
  message(FATAL_ERROR
    "missing injected MPI abort error code (status ${status}):\n${combined}")
endif()

foreach(forbidden IN ITEMS
    EEL_SMOKE_TERMINAL
    COUPLING_DRIVER_RETURNED_MPI_ACTIVE
    COUPLING_DRIVER_DESTROYED_MPI_FINALIZED)
  if(combined MATCHES "${forbidden}")
    message(FATAL_ERROR
      "post-initialize failure emitted normal marker ${forbidden}:\n${combined}")
  endif()
endforeach()
