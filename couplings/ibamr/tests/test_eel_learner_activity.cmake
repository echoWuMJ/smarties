cmake_minimum_required(VERSION 3.5)

function(activity_failure verdict report)
  message(STATUS "EEL_LEARNER_ACTIVITY verdict=${verdict} report=${report}")
  message(FATAL_ERROR "eel learner activity failed: ${verdict}: ${report}")
endfunction()

function(activity_field line key output)
  if("${line}" MATCHES "(^| )${key}=([^ ]+)")
    set(${output} "${CMAKE_MATCH_2}" PARENT_SCOPE)
  else()
    set(${output} "" PARENT_SCOPE)
  endif()
endfunction()

function(require_zero_status path label)
  if(NOT EXISTS "${path}")
    activity_failure(OPERATIONAL_INCOMPLETE "missing ${label} status")
  endif()
  file(READ "${path}" status)
  string(STRIP "${status}" status)
  if(NOT status STREQUAL "0")
    activity_failure(OPERATIONAL_INCOMPLETE "${label} exited ${status}")
  endif()
endfunction()

function(require_empty_snapshot path label)
  if(NOT EXISTS "${path}")
    activity_failure(OPERATIONAL_INCOMPLETE "missing ${label} process snapshot")
  endif()
  file(SIZE "${path}" size)
  if(NOT size EQUAL 0)
    activity_failure(OPERATIONAL_INCOMPLETE "${label} left a run-scoped process")
  endif()
endfunction()

function(activity_signature path stage verdict output)
  if(NOT EXISTS "${path}")
    activity_failure(${verdict} "missing audit log ${path}")
  endif()
  file(STRINGS "${path}" records
       REGEX "^SMARTIES_NETWORK_AUDIT .*stage=${stage} ")
  if(NOT records)
    activity_failure(${verdict} "missing ${stage} audit record")
  endif()
  set(signature)
  foreach(record IN LISTS records)
    activity_field("${record}" network network)
    activity_field("${record}" digest digest)
    activity_field("${record}" finite finite)
    if(network STREQUAL "" OR NOT digest MATCHES "^[0-9a-fA-F]+$")
      activity_failure(${verdict} "malformed ${stage} audit record")
    endif()
    if(NOT finite STREQUAL "1")
      activity_failure(NONFINITE_UPDATE "non-finite ${stage} audit record")
    endif()
    list(APPEND signature "${network}=${digest}")
  endforeach()
  list(SORT signature)
  set(${output} "${signature}" PARENT_SCOPE)
endfunction()

if(NOT DEFINED RUN_DIR OR NOT IS_DIRECTORY "${RUN_DIR}")
  activity_failure(OPERATIONAL_INCOMPLETE "RUN_DIR is missing")
endif()

require_zero_status("${RUN_DIR}/exit_code.txt" "eel child")
require_zero_status("${RUN_DIR}/restart_exit_code.txt" "checkpoint reload child")
require_empty_snapshot("${RUN_DIR}/processes-after.txt" "eel child")
require_empty_snapshot("${RUN_DIR}/restart-processes-after.txt"
                       "checkpoint reload child")

set(training_audit "${RUN_DIR}/learner-audit/learner_audit.log")
if(NOT EXISTS "${training_audit}")
  activity_failure(UPDATE_NOT_OBSERVED "missing learner audit log")
endif()
file(STRINGS "${training_audit}" audit_records
     REGEX "^SMARTIES_NETWORK_AUDIT ")
foreach(record IN LISTS audit_records)
  activity_field("${record}" finite finite)
  if(NOT finite STREQUAL "1")
    activity_failure(NONFINITE_UPDATE "non-finite learner audit record")
  endif()
endforeach()
file(STRINGS "${training_audit}" updates
     REGEX "^SMARTIES_NETWORK_AUDIT .*stage=update ")
list(LENGTH updates update_count)
if(NOT update_count EQUAL 2)
  activity_failure(UPDATE_NOT_OBSERVED
    "expected exactly two optimizer updates, observed ${update_count}")
endif()
set(expected_update_step 1)
foreach(update IN LISTS updates)
  activity_field("${update}" step update_step)
  if(NOT update_step STREQUAL "${expected_update_step}")
    activity_failure(UPDATE_NOT_OBSERVED
      "optimizer update step is ${update_step}, expected ${expected_update_step}")
  endif()
  math(EXPR expected_update_step "${expected_update_step} + 1")
endforeach()

activity_signature("${training_audit}" initialized UPDATE_NOT_OBSERVED
                   initialized_signature)
activity_signature("${training_audit}" final UPDATE_NOT_OBSERVED
                   final_signature)
if(initialized_signature STREQUAL final_signature)
  activity_failure(UPDATE_NOT_OBSERVED
    "final learner parameters equal initialized parameters")
endif()
file(STRINGS "${training_audit}" final_records
     REGEX "^SMARTIES_NETWORK_AUDIT .*stage=final ")
foreach(record IN LISTS final_records)
  activity_field("${record}" step final_step)
  if(NOT final_step STREQUAL "2")
    activity_failure(UPDATE_NOT_OBSERVED "final optimizer step is ${final_step}")
  endif()
endforeach()

activity_signature("${RUN_DIR}/restart-audit/learner_audit.log" restart
                   CHECKPOINT_MISMATCH restart_signature)
if(NOT final_signature STREQUAL restart_signature)
  activity_failure(CHECKPOINT_MISMATCH
    "reloaded synthetic policy digest differs from eel final digest")
endif()

file(GLOB application_outputs "${RUN_DIR}/simulation_*/output_*")
if(application_outputs)
  set(control_logs ${application_outputs})
elseif(EXISTS "${RUN_DIR}/stdout.log")
  set(control_logs "${RUN_DIR}/stdout.log")
else()
  activity_failure(COUPLING_PROTOCOL_FAILURE "missing eel control output")
endif()

set(transitions)
set(segments)
set(terminals)
set(completions)
foreach(control_log IN LISTS control_logs)
  file(STRINGS "${control_log}" log_transitions
       REGEX "^EEL_CONTROL ")
  file(STRINGS "${control_log}" log_segments
       REGEX "^EEL_CONTROL_SEGMENT ")
  file(STRINGS "${control_log}" log_terminals
       REGEX "^EEL_CONTROL_TERMINAL ")
  file(STRINGS "${control_log}" log_completions
       REGEX "^EEL_CONTROL_COMPLETE ")
  list(APPEND transitions ${log_transitions})
  list(APPEND segments ${log_segments})
  list(APPEND terminals ${log_terminals})
  list(APPEND completions ${log_completions})
endforeach()
list(LENGTH transitions decision_count)
if(decision_count EQUAL 0)
  activity_failure(COUPLING_PROTOCOL_FAILURE
    "no eel decisions were observed")
endif()
foreach(line IN LISTS transitions)
  activity_field("${line}" lagrangian_points points)
  string(TOLOWER "${line}" lower_line)
  if(NOT points STREQUAL "2932")
    activity_failure(COUPLING_PROTOCOL_FAILURE
      "eel transition lagrangian_points is ${points}")
  endif()
  if(lower_line MATCHES "(^|[= ])[-+]?(nan|inf)( |$)")
    activity_failure(COUPLING_PROTOCOL_FAILURE
      "eel transition contains non-finite data")
  endif()
endforeach()
list(LENGTH segments segment_count)
if(segment_count LESS 2)
  activity_failure(COUPLING_PROTOCOL_FAILURE
    "expected at least two truncated eel segments, observed ${segment_count}")
endif()
foreach(segment IN LISTS segments)
  activity_field("${segment}" status segment_status)
  if(NOT segment_status STREQUAL "truncated")
    activity_failure(COUPLING_PROTOCOL_FAILURE
      "eel segment status is ${segment_status}")
  endif()
endforeach()
list(LENGTH terminals terminal_count)
if(NOT terminal_count EQUAL 0)
  activity_failure(COUPLING_PROTOCOL_FAILURE
    "unexpected eel terminal records: ${terminal_count}")
endif()
list(LENGTH completions completion_count)
if(NOT completion_count EQUAL 1)
  activity_failure(COUPLING_PROTOCOL_FAILURE
    "expected one eel completion record, observed ${completion_count}")
endif()
list(GET completions 0 completion)
activity_field("${completion}" stopped_by stopped_by)
if(NOT stopped_by STREQUAL "smarties")
  activity_failure(COUPLING_PROTOCOL_FAILURE
    "eel completion stopped_by is ${stopped_by}")
endif()

if(NOT EXISTS "${RUN_DIR}/restart_stdout.log")
  activity_failure(OPERATIONAL_INCOMPLETE "missing checkpoint reload stdout")
endif()
file(STRINGS "${RUN_DIR}/restart_stdout.log" synthetic_steps
     REGEX "^SMARTIES_SYNTHETIC_STEP ")
if(NOT synthetic_steps)
  activity_failure(CHECKPOINT_MISMATCH
    "reloaded checkpoint produced no synthetic actions")
endif()
foreach(line IN LISTS synthetic_steps)
  activity_field("${line}" finite finite)
  string(TOLOWER "${line}" lower_line)
  if(NOT finite STREQUAL "1" OR
     lower_line MATCHES "(^|[= ])[-+]?(nan|inf)( |$)")
    activity_failure(CHECKPOINT_MISMATCH
      "reloaded checkpoint produced a non-finite action")
  endif()
endforeach()
file(READ "${RUN_DIR}/restart_stdout.log" restart_stdout)
if(NOT restart_stdout MATCHES "COUPLING_DRIVER_RETURNED_MPI_ACTIVE" OR
   NOT restart_stdout MATCHES "COUPLING_DRIVER_DESTROYED_MPI_FINALIZED")
  activity_failure(OPERATIONAL_INCOMPLETE
    "checkpoint reload did not return through CouplingDriver")
endif()

message(STATUS
  "EEL_LEARNER_ACTIVITY verdict=PASS report=two native CPU updates, continuing segments, and checkpoint reload verified")
