if(NOT DEFINED PROBE_EXECUTABLE OR NOT EXISTS "${PROBE_EXECUTABLE}")
  message(FATAL_ERROR "network audit comparator requires PROBE_EXECUTABLE")
endif()

foreach(required
    REPEAT_A_FILE REPEAT_B_FILE THREADED_FILE LONG_FILE CHECKPOINT_FILE
    RESUMED_FILE CONTINUOUS_FILE)
  if(NOT DEFINED ${required} OR NOT EXISTS "${${required}}")
    message(FATAL_ERROR "network audit comparator requires ${required}")
  endif()
endforeach()

execute_process(
  COMMAND "${PROBE_EXECUTABLE}" --compare
    "${REPEAT_A_FILE}"
    "${REPEAT_B_FILE}"
    "${THREADED_FILE}"
    "${LONG_FILE}"
    "${CHECKPOINT_FILE}"
    "${RESUMED_FILE}"
    "${CONTINUOUS_FILE}"
  RESULT_VARIABLE compare_status
  OUTPUT_VARIABLE compare_stdout
  ERROR_VARIABLE compare_stderr)

message(STATUS "${compare_stdout}")
if(NOT compare_status EQUAL 0)
  message(FATAL_ERROR
    "network update comparison failed: status=${compare_status}\n"
    "${compare_stdout}${compare_stderr}")
endif()

if(NOT compare_stdout MATCHES "(^|[\r\n])PASS([\r\n]|$)")
  message(FATAL_ERROR "network update comparator did not emit PASS")
endif()
