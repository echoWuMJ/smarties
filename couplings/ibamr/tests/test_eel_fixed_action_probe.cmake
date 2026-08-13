foreach(required PROBE_EXECUTABLE MPIEXEC_EXECUTABLE INPUT_FILE TASK_FILE)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "eel fixed-action probe test requires ${required}")
  endif()
endforeach()
if(NOT EXISTS "${PROBE_EXECUTABLE}")
  message(FATAL_ERROR "eel fixed-action probe executable does not exist")
endif()
if(NOT EXISTS "${MPIEXEC_EXECUTABLE}")
  message(FATAL_ERROR "MPI launcher does not exist")
endif()
if(NOT EXISTS "${INPUT_FILE}")
  message(FATAL_ERROR "rendered eel input does not exist")
endif()
if(NOT EXISTS "${TASK_FILE}")
  message(FATAL_ERROR "eel task fixture does not exist")
endif()

find_program(AWK_EXECUTABLE NAMES awk gawk REQUIRED
  HINTS "C:/Program Files/Git/usr/bin")

function(read_field line key output)
  string(REGEX MATCH "(^| )${key}=([^ ]+)" match "${line}")
  if(NOT match)
    message(FATAL_ERROR "fixed-action record is missing ${key}: ${line}")
  endif()
  set(${output} "${CMAKE_MATCH_2}" PARENT_SCOPE)
endfunction()

function(require_finite value description)
  if(NOT "${value}" MATCHES
     "^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$")
    message(FATAL_ERROR "${description} is not finite numeric output: ${value}")
  endif()
endfunction()

function(expect_usage_failure name expected)
  execute_process(
    COMMAND "${PROBE_EXECUTABLE}" ${ARGN}
    RESULT_VARIABLE status OUTPUT_VARIABLE stdout ERROR_VARIABLE stderr)
  if(NOT status EQUAL 64)
    message(FATAL_ERROR
      "${name} must exit 64, got ${status}\nstdout:\n${stdout}\nstderr:\n${stderr}")
  endif()
  string(FIND "${stderr}" "frequency response probe error: ${expected}" match)
  if(match EQUAL -1)
    message(FATAL_ERROR
      "${name} did not name contract '${expected}'\nstderr:\n${stderr}")
  endif()
endfunction()

# These contracts are parser/task validation and must fail before MpiSession or
# IBAMR initialization. Deliberately use the executable directly, not mpiexec.
expect_usage_failure(
  "mixed probe modes" "--ratio and --task-file are mutually exclusive"
  --input-file "${INPUT_FILE}" --ratio 1.0 --task-file "${TASK_FILE}"
  --action 1.0 --decisions 2 --direction-x 1.0 --direction-y 0.0)
expect_usage_failure(
  "task mode without action" "--action is required in task mode"
  --input-file "${INPUT_FILE}" --task-file "${TASK_FILE}" --decisions 2)
expect_usage_failure(
  "direct mode with action" "--action is only valid with --task-file"
  --input-file "${INPUT_FILE}" --ratio 1.0 --action 1.0 --decisions 2
  --direction-x 1.0 --direction-y 0.0)

set(nonzero_warmup_task "${CMAKE_CURRENT_BINARY_DIR}/nonzero-warmup-task.conf")
file(READ "${TASK_FILE}" task_contents)
string(REGEX REPLACE "warmup_cycles=[^\r\n]+" "warmup_cycles=1.0"
       nonzero_warmup_contents "${task_contents}")
file(WRITE "${nonzero_warmup_task}" "${nonzero_warmup_contents}")
expect_usage_failure(
  "task file with warmup" "task-driven probe requires warmup_cycles=0"
  --input-file "${INPUT_FILE}" --task-file "${nonzero_warmup_task}"
  --action 1.0 --decisions 2)
expect_usage_failure(
  "task decisions above horizon" "--decisions exceeds task episode_decisions"
  --input-file "${INPUT_FILE}" --task-file "${TASK_FILE}"
  --action 1.0 --decisions 3)

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 1
          ${MPIEXEC_PREFLAGS} "${PROBE_EXECUTABLE}"
          --input-file "${INPUT_FILE}"
          --task-file "${TASK_FILE}"
          --action 1.0 --decisions 2
          ${MPIEXEC_POSTFLAGS}
  RESULT_VARIABLE status OUTPUT_VARIABLE stdout ERROR_VARIABLE stderr)
if(NOT status EQUAL 0)
  message(FATAL_ERROR
    "fixed-action probe failed with ${status}\nstdout:\n${stdout}\nstderr:\n${stderr}")
endif()

string(REGEX MATCHALL "EEL_FIXED_ACTION_STEP[^\r\n]*" step_lines "${stdout}")
string(REGEX MATCHALL "EEL_FIXED_ACTION_SUMMARY[^\r\n]*" summary_lines "${stdout}")
list(LENGTH step_lines step_count)
list(LENGTH summary_lines summary_count)
if(NOT step_count EQUAL 2)
  message(FATAL_ERROR "expected exactly two fixed-action steps, got ${step_count}")
endif()
if(NOT summary_count EQUAL 1)
  message(FATAL_ERROR "expected exactly one fixed-action summary, got ${summary_count}")
endif()

set(expected_ratios 1.1 1.2)
set(step_values)
foreach(index RANGE 0 1)
  list(GET step_lines ${index} line)
  math(EXPR expected_decision "${index} + 1")
  list(GET expected_ratios ${index} expected_ratio)
  foreach(key decision environment_ranks action target_ratio previous_ratio
              applied_ratio start_time end_time ibamr_steps start_com_x start_com_y
              end_com_x end_com_y displacement_x displacement_y
              forward_displacement forward_velocity phase_end lagrangian_points
              reward_tracking reward_frequency reward_smoothness reward_total)
    read_field("${line}" "${key}" value_${key})
  endforeach()
  if(NOT value_decision EQUAL expected_decision OR
     NOT value_environment_ranks EQUAL 1 OR
     NOT value_lagrangian_points EQUAL 2932)
    message(FATAL_ERROR "non-canonical fixed-action step: ${line}")
  endif()
  if(value_ibamr_steps LESS 1)
    message(FATAL_ERROR "fixed-action step did not advance IBAMR: ${line}")
  endif()
  foreach(key action target_ratio previous_ratio applied_ratio start_time end_time
              start_com_x start_com_y end_com_x end_com_y displacement_x
              displacement_y forward_displacement forward_velocity phase_end
              reward_tracking reward_frequency reward_smoothness reward_total)
    require_finite("${value_${key}}" "step ${expected_decision} ${key}")
  endforeach()
  execute_process(
    COMMAND "${AWK_EXECUTABLE}"
      -v "actual=${value_applied_ratio}" -v "expected=${expected_ratio}"
      -v "start=${value_start_time}" -v "end=${value_end_time}"
      "BEGIN { d=actual-expected; if (d<0) d=-d;
               exit ! (d <= 1e-12 && end > start); }"
    RESULT_VARIABLE numeric_status)
  if(NOT numeric_status EQUAL 0)
    message(FATAL_ERROR
      "step ${expected_decision} ratio/time contract failed: ${line}")
  endif()
  list(APPEND step_values
    "${value_ibamr_steps}" "${value_reward_tracking}"
    "${value_reward_frequency}" "${value_reward_smoothness}"
    "${value_reward_total}")
endforeach()

list(GET summary_lines 0 summary)
foreach(key environment_ranks decisions ibamr_steps elapsed_time displacement_x
            displacement_y forward_displacement final_phase lagrangian_points
            reward_tracking reward_frequency reward_smoothness reward_total)
  read_field("${summary}" "${key}" summary_${key})
endforeach()
if(NOT summary_environment_ranks EQUAL 1 OR NOT summary_decisions EQUAL 2 OR
   NOT summary_lagrangian_points EQUAL 2932)
  message(FATAL_ERROR "non-canonical fixed-action summary: ${summary}")
endif()
foreach(key elapsed_time displacement_x displacement_y forward_displacement
            final_phase reward_tracking reward_frequency reward_smoothness
            reward_total)
  require_finite("${summary_${key}}" "summary ${key}")
endforeach()
list(GET step_values 0 steps_1)
list(GET step_values 5 steps_2)
list(GET step_values 1 tracking_1)
list(GET step_values 6 tracking_2)
list(GET step_values 2 frequency_1)
list(GET step_values 7 frequency_2)
list(GET step_values 3 smoothness_1)
list(GET step_values 8 smoothness_2)
list(GET step_values 4 total_1)
list(GET step_values 9 total_2)
execute_process(
  COMMAND "${AWK_EXECUTABLE}"
    -v "s1=${steps_1}" -v "s2=${steps_2}" -v "ss=${summary_ibamr_steps}"
    -v "t1=${tracking_1}" -v "t2=${tracking_2}" -v "ts=${summary_reward_tracking}"
    -v "f1=${frequency_1}" -v "f2=${frequency_2}" -v "fs=${summary_reward_frequency}"
    -v "m1=${smoothness_1}" -v "m2=${smoothness_2}" -v "ms=${summary_reward_smoothness}"
    -v "r1=${total_1}" -v "r2=${total_2}" -v "rs=${summary_reward_total}"
    -v "elapsed=${summary_elapsed_time}"
    "BEGIN { dt=(t1+t2)-ts; if(dt<0)dt=-dt;
             df=(f1+f2)-fs; if(df<0)df=-df;
             dm=(m1+m2)-ms; if(dm<0)dm=-dm;
             dr=(r1+r2)-rs; if(dr<0)dr=-dr;
             exit ! (elapsed>0 && ss==s1+s2 && dt<=1e-12 && df<=1e-12 &&
                     dm<=1e-12 && dr<=1e-12); }"
  RESULT_VARIABLE summary_status)
if(NOT summary_status EQUAL 0)
  message(FATAL_ERROR "fixed-action summary does not equal the two step sums: ${summary}")
endif()

# A failure while initialize is still in progress is not evidence for the
# post-initialize fatal boundary.
execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 1
          ${MPIEXEC_PREFLAGS} "${PROBE_EXECUTABLE}"
          --input-file "__missing_fixed_action_probe_input__"
          --task-file "${TASK_FILE}" --action 1.0 --decisions 2
          --fault-after-initialize ${MPIEXEC_POSTFLAGS}
  RESULT_VARIABLE missing_status OUTPUT_VARIABLE missing_stdout
  ERROR_VARIABLE missing_stderr)
set(missing_output "${missing_stdout}\n${missing_stderr}")
if(missing_output MATCHES "frequency response probe fatal error: injected failure after IBAMR initialization" OR
   missing_output MATCHES "MPI_ABORT was invoked")
  message(FATAL_ERROR "missing input incorrectly satisfied post-initialize fatal assertion")
endif()

execute_process(
  COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 1
          ${MPIEXEC_PREFLAGS} "${PROBE_EXECUTABLE}"
          --input-file "${INPUT_FILE}" --task-file "${TASK_FILE}"
          --action 1.0 --decisions 2 --fault-after-initialize
          ${MPIEXEC_POSTFLAGS}
  RESULT_VARIABLE fault_status OUTPUT_VARIABLE fault_stdout
  ERROR_VARIABLE fault_stderr)
set(fault_output "${fault_stdout}\n${fault_stderr}")
foreach(expected
    "frequency response probe fatal error: injected failure after IBAMR initialization"
    "MPI_ABORT was invoked"
    "errorcode 64")
  string(FIND "${fault_output}" "${expected}" match)
  if(match EQUAL -1)
    message(FATAL_ERROR
      "post-initialize fault output is missing '${expected}'\n${fault_output}")
  endif()
endforeach()
