cmake_minimum_required(VERSION 3.10)

get_filename_component(COUPLING_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(TEMPLATE "${COUPLING_ROOT}/cases/eel2d/upstream/input2d.in")
set(RENDERER "${COUPLING_ROOT}/scripts/render_input.cmake")
set(OUTPUT_DIR "${COUPLING_ROOT}/build/render-input-test")

file(REMOVE_RECURSE "${OUTPUT_DIR}")
file(MAKE_DIRECTORY "${OUTPUT_DIR}")
file(SHA256 "${TEMPLATE}" HASH_BEFORE)

function(assert_rendered_fidelity NAME EXPECTED_N EXPECTED_LEVELS EXPECTED_RATIO)
  set(FIDELITY "${COUPLING_ROOT}/configs/fidelity/${NAME}.conf")
  set(OUTPUT "${OUTPUT_DIR}/input2d-${NAME}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DFIDELITY_FILE=${FIDELITY}"
      "-DEEL_END_TIME=12.5"
      "-DOUTPUT_FILE=${OUTPUT}"
      -P "${RENDERER}"
    RESULT_VARIABLE RESULT)
  if(NOT RESULT EQUAL 0)
    message(FATAL_ERROR "rendering ${NAME} failed with exit code ${RESULT}")
  endif()

  file(READ "${OUTPUT}" CONTENT)

  string(REGEX MATCH "(^|\n)N[ \t]*=[ \t]*([0-9]+)" N_MATCH "${CONTENT}")
  if(NOT CMAKE_MATCH_2 STREQUAL "${EXPECTED_N}")
    message(FATAL_ERROR "${NAME}: expected N = ${EXPECTED_N}, got '${CMAKE_MATCH_2}'")
  endif()

  string(REGEX MATCH "(^|\n)MAX_LEVELS[ \t]*=[ \t]*([0-9]+)" LEVELS_MATCH "${CONTENT}")
  if(NOT CMAKE_MATCH_2 STREQUAL "${EXPECTED_LEVELS}")
    message(FATAL_ERROR "${NAME}: expected MAX_LEVELS = ${EXPECTED_LEVELS}, got '${CMAKE_MATCH_2}'")
  endif()

  string(REGEX MATCH "(^|\n)REF_RATIO[ \t]*=[ \t]*([0-9]+)" RATIO_MATCH "${CONTENT}")
  if(NOT CMAKE_MATCH_2 STREQUAL "${EXPECTED_RATIO}")
    message(FATAL_ERROR "${NAME}: expected REF_RATIO = ${EXPECTED_RATIO}, got '${CMAKE_MATCH_2}'")
  endif()

  string(FIND "${CONTENT}" "PHI" PHASE_VARIABLE_INDEX)
  if(PHASE_VARIABLE_INDEX EQUAL -1)
    message(FATAL_ERROR "${NAME}: rendered eel kinematics do not use continuous PHI")
  endif()

  string(FIND "${CONTENT}" "OMEGA" OMEGA_VARIABLE_INDEX)
  if(OMEGA_VARIABLE_INDEX EQUAL -1)
    message(FATAL_ERROR "${NAME}: rendered eel velocity does not use controlled OMEGA")
  endif()

  string(FIND "${CONTENT}" "(0.785/0.125)*T" FIXED_TIME_INDEX)
  if(NOT FIXED_TIME_INDEX EQUAL -1)
    message(FATAL_ERROR "${NAME}: rendered eel kinematics still use the fixed temporal phase")
  endif()

  string(REGEX MATCHALL "(^|\n)END_TIME[ \t]*=[ \t]*12[.]5(\n|[ \t]|$)"
         END_TIME_ASSIGNMENTS "${CONTENT}")
  list(LENGTH END_TIME_ASSIGNMENTS END_TIME_ASSIGNMENT_COUNT)
  if(NOT END_TIME_ASSIGNMENT_COUNT EQUAL 1)
    message(FATAL_ERROR
      "${NAME}: expected one top-level END_TIME = 12.5 assignment, got ${END_TIME_ASSIGNMENT_COUNT}")
  endif()

  string(REGEX MATCHALL "end_time[ \t]*=[ \t]*END_TIME"
         END_TIME_REFERENCES "${CONTENT}")
  list(LENGTH END_TIME_REFERENCES END_TIME_REFERENCE_COUNT)
  if(NOT END_TIME_REFERENCE_COUNT EQUAL 2)
    message(FATAL_ERROR
      "${NAME}: expected two integrator END_TIME references, got ${END_TIME_REFERENCE_COUNT}")
  endif()
endfunction()

function(assert_end_time_rejected VALUE LABEL)
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DFIDELITY_FILE=${COUPLING_ROOT}/configs/fidelity/medium.conf"
      "-DEEL_END_TIME=${VALUE}"
      "-DOUTPUT_FILE=${OUTPUT_DIR}/invalid-${LABEL}"
      -P "${RENDERER}"
    RESULT_VARIABLE RESULT
    OUTPUT_QUIET ERROR_QUIET)
  if(RESULT EQUAL 0)
    message(FATAL_ERROR "renderer accepted invalid EEL_END_TIME=${VALUE}")
  endif()
endfunction()

function(assert_end_time_preserved VALUE LABEL)
  set(OUTPUT "${OUTPUT_DIR}/valid-${LABEL}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DFIDELITY_FILE=${COUPLING_ROOT}/configs/fidelity/medium.conf"
      "-DEEL_END_TIME=${VALUE}"
      "-DOUTPUT_FILE=${OUTPUT}"
      -P "${RENDERER}"
    RESULT_VARIABLE RESULT)
  if(NOT RESULT EQUAL 0)
    message(FATAL_ERROR "renderer rejected valid EEL_END_TIME=${VALUE}")
  endif()
  file(STRINGS "${OUTPUT}" ASSIGNMENTS REGEX "^END_TIME[ \t]*=")
  list(LENGTH ASSIGNMENTS ASSIGNMENT_COUNT)
  if(NOT ASSIGNMENT_COUNT EQUAL 1)
    message(FATAL_ERROR
      "renderer emitted ${ASSIGNMENT_COUNT} top-level END_TIME assignments")
  endif()
  list(GET ASSIGNMENTS 0 ASSIGNMENT)
  if(NOT ASSIGNMENT STREQUAL "END_TIME = ${VALUE}")
    message(FATAL_ERROR
      "renderer did not preserve exact EEL_END_TIME=${VALUE}")
  endif()
endfunction()

assert_rendered_fidelity(coarse 32 2 4)
assert_rendered_fidelity(medium 64 3 4)
assert_rendered_fidelity(fine 128 3 4)

execute_process(
  COMMAND "${CMAKE_COMMAND}"
    "-DFIDELITY_FILE=${COUPLING_ROOT}/configs/fidelity/medium.conf"
    "-DOUTPUT_FILE=${OUTPUT_DIR}/missing-end-time"
    -P "${RENDERER}"
  RESULT_VARIABLE MISSING_END_TIME_RESULT
  OUTPUT_QUIET ERROR_QUIET)
if(MISSING_END_TIME_RESULT EQUAL 0)
  message(FATAL_ERROR "renderer accepted a missing EEL_END_TIME")
endif()

execute_process(
  COMMAND "${CMAKE_COMMAND}"
    "-DFIDELITY_FILE=${COUPLING_ROOT}/configs/fidelity/medium.conf"
    "-DEEL_END_TIME=0"
    "-DOUTPUT_FILE=${OUTPUT_DIR}/zero-end-time"
    -P "${RENDERER}"
  RESULT_VARIABLE ZERO_END_TIME_RESULT
  OUTPUT_QUIET ERROR_QUIET)
if(ZERO_END_TIME_RESULT EQUAL 0)
  message(FATAL_ERROR "renderer accepted EEL_END_TIME=0")
endif()

assert_end_time_rejected("-1" negative)
assert_end_time_rejected("NaN" nan)
assert_end_time_rejected("Inf" infinity)
assert_end_time_rejected("1e9999" overflow)
assert_end_time_rejected("1e-9999" underflow)
assert_end_time_preserved("12.5" decimal)
assert_end_time_preserved("1.25e1" scientific)

file(SHA256 "${TEMPLATE}" HASH_AFTER)
if(NOT HASH_BEFORE STREQUAL HASH_AFTER)
  message(FATAL_ERROR "source input2d.in was modified during rendering")
endif()

message(STATUS "input rendering checks passed; source hash ${HASH_AFTER}")
