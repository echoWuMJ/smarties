cmake_minimum_required(VERSION 3.10)

if(NOT DEFINED FIDELITY_FILE OR FIDELITY_FILE STREQUAL "")
  message(FATAL_ERROR "FIDELITY_FILE is required")
endif()
if(NOT EXISTS "${FIDELITY_FILE}")
  message(FATAL_ERROR "fidelity file does not exist: ${FIDELITY_FILE}")
endif()
if(NOT DEFINED OUTPUT_FILE OR OUTPUT_FILE STREQUAL "")
  message(FATAL_ERROR "OUTPUT_FILE is required")
endif()
if(NOT DEFINED EEL_END_TIME OR EEL_END_TIME STREQUAL "")
  message(FATAL_ERROR "EEL_END_TIME is required")
endif()
if(NOT EEL_END_TIME MATCHES
   "^[+]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][-+]?[0-9]+)?$")
  message(FATAL_ERROR "EEL_END_TIME must be a positive finite number")
endif()
string(REGEX REPLACE "[eE].*$" "" EEL_END_TIME_MANTISSA "${EEL_END_TIME}")
string(REGEX REPLACE "^[+]" "" EEL_END_TIME_MANTISSA
       "${EEL_END_TIME_MANTISSA}")
string(REPLACE "." "" EEL_END_TIME_DIGITS "${EEL_END_TIME_MANTISSA}")
string(REGEX REPLACE "0" "" EEL_END_TIME_NONZERO "${EEL_END_TIME_DIGITS}")
if(EEL_END_TIME_NONZERO STREQUAL "")
  message(FATAL_ERROR "EEL_END_TIME must be greater than zero")
endif()
find_program(EEL_AWK_EXECUTABLE NAMES awk gawk)
if(NOT EEL_AWK_EXECUTABLE)
  message(FATAL_ERROR "awk is required to validate EEL_END_TIME")
endif()
execute_process(
  COMMAND "${EEL_AWK_EXECUTABLE}" -v "value=${EEL_END_TIME}"
    "BEGIN {
       numeric = value + 0
       rendered = sprintf(\"%.17g\", numeric)
       if (!(numeric > 0) || tolower(rendered) ~ /(inf|nan)/) exit 1
     }"
  RESULT_VARIABLE EEL_END_TIME_NUMERIC_STATUS
  OUTPUT_QUIET ERROR_QUIET)
if(NOT EEL_END_TIME_NUMERIC_STATUS EQUAL 0)
  message(FATAL_ERROR
    "EEL_END_TIME must be positive and representable by the runtime numeric parser")
endif()

include("${FIDELITY_FILE}")

if(NOT DEFINED EEL_OUTPUT_INTERVAL)
  set(EEL_OUTPUT_INTERVAL 1)
endif()
if(NOT DEFINED EEL_VIZ_DUMP_INTERVAL)
  set(EEL_VIZ_DUMP_INTERVAL 40)
endif()
if(NOT DEFINED EEL_RESTART_DUMP_INTERVAL)
  set(EEL_RESTART_DUMP_INTERVAL 150)
endif()
if(NOT DEFINED EEL_TIMER_DUMP_INTERVAL)
  set(EEL_TIMER_DUMP_INTERVAL 100)
endif()

foreach(VARIABLE EEL_OUTPUT_INTERVAL EEL_VIZ_DUMP_INTERVAL)
  if(NOT "${${VARIABLE}}" MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR "${VARIABLE} must be a positive integer")
  endif()
endforeach()
foreach(VARIABLE EEL_RESTART_DUMP_INTERVAL EEL_TIMER_DUMP_INTERVAL)
  if(NOT "${${VARIABLE}}" MATCHES "^(0|[1-9][0-9]*)$")
    message(FATAL_ERROR "${VARIABLE} must be a nonnegative integer")
  endif()
endforeach()

foreach(VARIABLE EEL_N EEL_MAX_LEVELS EEL_REF_RATIO)
  if(NOT DEFINED ${VARIABLE} OR NOT "${${VARIABLE}}" MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR "${VARIABLE} must be a positive integer")
  endif()
endforeach()

get_filename_component(OUTPUT_DIRECTORY "${OUTPUT_FILE}" DIRECTORY)
file(MAKE_DIRECTORY "${OUTPUT_DIRECTORY}")

configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/../cases/eel2d/upstream/input2d.in"
  "${OUTPUT_FILE}"
  @ONLY)

file(READ "${OUTPUT_FILE}" CONTENT)
string(REGEX REPLACE "(^|\n)N[ \t]*=[ \t]*[0-9]+" "\\1N = ${EEL_N}" CONTENT "${CONTENT}")
string(REGEX REPLACE "(^|\n)MAX_LEVELS[ \t]*=[ \t]*[0-9]+" "\\1MAX_LEVELS = ${EEL_MAX_LEVELS}" CONTENT "${CONTENT}")
string(REGEX REPLACE "(^|\n)REF_RATIO[ \t]*=[ \t]*[0-9]+" "\\1REF_RATIO = ${EEL_REF_RATIO}" CONTENT "${CONTENT}")
string(REGEX MATCHALL "(^|\n)END_TIME[ \t]*=[ \t]*[^\n]+"
       END_TIME_ASSIGNMENTS "${CONTENT}")
list(LENGTH END_TIME_ASSIGNMENTS END_TIME_ASSIGNMENT_COUNT)
if(NOT END_TIME_ASSIGNMENT_COUNT EQUAL 1)
  message(FATAL_ERROR
    "expected exactly one top-level END_TIME assignment, found ${END_TIME_ASSIGNMENT_COUNT}")
endif()
string(REGEX REPLACE "(^|\n)END_TIME[ \t]*=[ \t]*[^\n]+"
       "\\1END_TIME = ${EEL_END_TIME}" CONTENT "${CONTENT}")
string(REGEX REPLACE "(^|\n)[ \t]*output_interval[ \t]*=[ \t]*[^\n]+"
       "\\1   output_interval = ${EEL_OUTPUT_INTERVAL}" CONTENT "${CONTENT}")
string(REGEX REPLACE "(^|\n)[ \t]*viz_dump_interval[ \t]*=[ \t]*[^\n]+"
       "\\1   viz_dump_interval = ${EEL_VIZ_DUMP_INTERVAL}" CONTENT "${CONTENT}")
string(REGEX REPLACE "(^|\n)[ \t]*restart_dump_interval[ \t]*=[ \t]*[^\n]+"
       "\\1   restart_dump_interval = ${EEL_RESTART_DUMP_INTERVAL}" CONTENT "${CONTENT}")
string(REGEX REPLACE "(^|\n)[ \t]*timer_dump_interval[ \t]*=[ \t]*[^\n]+"
       "\\1   timer_dump_interval = ${EEL_TIMER_DUMP_INTERVAL}" CONTENT "${CONTENT}")
file(WRITE "${OUTPUT_FILE}" "${CONTENT}")
