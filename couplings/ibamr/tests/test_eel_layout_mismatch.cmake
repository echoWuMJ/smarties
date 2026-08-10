foreach(required IN ITEMS TEST_EXECUTABLE MPIEXEC_EXECUTABLE INPUT_FILE)
  if(NOT DEFINED ${required} OR NOT EXISTS "${${required}}")
    message(FATAL_ERROR "${required} is missing: ${${required}}")
  endif()
endforeach()

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 1
          ${MPIEXEC_PREFLAGS} "${TEST_EXECUTABLE}" "${INPUT_FILE}"
          ${MPIEXEC_POSTFLAGS}
  RESULT_VARIABLE status
  OUTPUT_VARIABLE stdout
  ERROR_VARIABLE stderr
  TIMEOUT 300)
string(CONCAT combined "${stdout}" "\n" "${stderr}")
if(status EQUAL 0)
  message(FATAL_ERROR "invalid coarse layout advanced instead of failing")
endif()
if(NOT combined MATCHES
   "layout point count 76 does not match Lagrangian vertex count 2932")
  message(FATAL_ERROR "missing layout mismatch diagnostic:\n${combined}")
endif()
