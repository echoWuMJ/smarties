if(NOT DEFINED PROBE_EXECUTABLE OR NOT EXISTS "${PROBE_EXECUTABLE}")
  message(FATAL_ERROR "frequency-response probe executable does not exist")
endif()
if(NOT DEFINED MPIEXEC_EXECUTABLE OR NOT EXISTS "${MPIEXEC_EXECUTABLE}")
  message(FATAL_ERROR "MPI launcher does not exist")
endif()
if(NOT DEFINED INPUT_FILE OR NOT EXISTS "${INPUT_FILE}")
  message(FATAL_ERROR "rendered eel input does not exist")
endif()

find_program(AWK_EXECUTABLE awk REQUIRED)

function(read_probe_value line key output)
  string(REGEX MATCH "(^| )${key}=([^ ]+)" match "${line}")
  if(NOT match)
    message(FATAL_ERROR "probe output is missing ${key}: ${line}")
  endif()
  set(${output} "${CMAKE_MATCH_2}" PARENT_SCOPE)
endfunction()

foreach(ratio IN ITEMS 0.5 1.0 1.5)
  execute_process(
    COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 1
            ${MPIEXEC_PREFLAGS}
            "${PROBE_EXECUTABLE}"
            --input-file "${INPUT_FILE}"
            --ratio "${ratio}"
            --decisions 2
            --direction-x 1.0
            --direction-y 0.0
            ${MPIEXEC_POSTFLAGS}
    RESULT_VARIABLE probe_status
    OUTPUT_VARIABLE probe_stdout
    ERROR_VARIABLE probe_stderr
    TIMEOUT 300)
  if(NOT probe_status EQUAL 0)
    message(FATAL_ERROR
      "frequency probe ratio ${ratio} failed with ${probe_status}\n"
      "stdout:\n${probe_stdout}\nstderr:\n${probe_stderr}")
  endif()

  string(REGEX MATCH "EEL_FREQUENCY_PROBE[^\r\n]*" probe_line
         "${probe_stdout}")
  if(NOT probe_line)
    message(FATAL_ERROR "frequency probe emitted no result line")
  endif()

  foreach(key IN ITEMS ratio decisions ibamr_steps elapsed_time
                       displacement_x displacement_y forward_displacement
                       mean_forward_velocity phase_start phase_end)
    read_probe_value("${probe_line}" "${key}" "value_${key}")
    if(NOT value_${key} MATCHES
       "^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$")
      message(FATAL_ERROR "${key} is not finite numeric output: ${value_${key}}")
    endif()
  endforeach()

  if(NOT value_decisions EQUAL 2)
    message(FATAL_ERROR "probe did not complete two decisions")
  endif()
  if(value_ibamr_steps LESS 2)
    message(FATAL_ERROR "probe did not advance at least one IBAMR step per decision")
  endif()
  if(NOT value_elapsed_time GREATER 0)
    message(FATAL_ERROR "probe elapsed time is not positive")
  endif()

  execute_process(
    COMMAND "${AWK_EXECUTABLE}"
      -v "actual_ratio=${value_ratio}"
      -v "requested_ratio=${ratio}"
      -v "phase_start=${value_phase_start}"
      -v "phase_end=${value_phase_end}"
      -v "elapsed=${value_elapsed_time}"
      "BEGIN {
         ratio_error = actual_ratio - requested_ratio;
         if (ratio_error < 0) ratio_error = -ratio_error;
         phase_error = (phase_end - phase_start) - 6.28 * requested_ratio * elapsed;
         if (phase_error < 0) phase_error = -phase_error;
         exit ! (ratio_error <= 1e-12 && phase_error <= 1e-10);
       }"
    RESULT_VARIABLE physics_status)
  if(NOT physics_status EQUAL 0)
    message(FATAL_ERROR
      "ratio or phase advance is inconsistent for requested ratio ${ratio}: "
      "${probe_line}")
  endif()
endforeach()
