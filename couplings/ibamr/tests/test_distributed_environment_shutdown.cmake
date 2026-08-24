cmake_minimum_required(VERSION 3.5)

foreach(required MPIEXEC_EXECUTABLE MPIEXEC_NUMPROC_FLAG TEST_EXECUTABLE
                 SETTINGS_FILE RUN_ROOT)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "distributed shutdown test is missing ${required}")
  endif()
endforeach()

file(REMOVE_RECURSE "${RUN_ROOT}")
file(MAKE_DIRECTORY "${RUN_ROOT}")
configure_file("${SETTINGS_FILE}" "${RUN_ROOT}/settings.json" COPYONLY)

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 3
          ${MPIEXEC_PREFLAGS} "${TEST_EXECUTABLE}"
          --nMasters 1 --nThreads 1 --nEnvironments 1
          --workerProcessesPerEnv 2 --learnersOnWorkers 0
          --nTrainSteps 1 --nTrainUpdates 0
          --randSeed 11 --restart none --setupFolder .
          --redirectAppStdoutToFile 0 ${MPIEXEC_POSTFLAGS}
  WORKING_DIRECTORY "${RUN_ROOT}"
  RESULT_VARIABLE status
  OUTPUT_VARIABLE stdout
  ERROR_VARIABLE stderr
  TIMEOUT 20)
string(CONCAT combined "${stdout}" "\n" "${stderr}")

if(NOT status EQUAL 0)
  message(FATAL_ERROR
    "distributed environment did not shut down cleanly (status ${status}):\n"
    "${combined}")
endif()

foreach(marker IN ITEMS
    "DISTRIBUTED_ENVIRONMENT_CALLBACK_RETURNED ranks=2"
    "COUPLING_DRIVER_RETURNED_MPI_ACTIVE"
    "COUPLING_DRIVER_DESTROYED_MPI_FINALIZED")
  if(NOT combined MATCHES "${marker}")
    message(FATAL_ERROR "distributed shutdown is missing ${marker}:\n${combined}")
  endif()
endforeach()

message(STATUS "SMARTIES_DISTRIBUTED_ENVIRONMENT_SHUTDOWN status=PASS")
