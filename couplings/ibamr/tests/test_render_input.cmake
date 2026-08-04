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
endfunction()

assert_rendered_fidelity(coarse 32 2 4)
assert_rendered_fidelity(medium 64 3 4)
assert_rendered_fidelity(fine 128 3 4)

file(SHA256 "${TEMPLATE}" HASH_AFTER)
if(NOT HASH_BEFORE STREQUAL HASH_AFTER)
  message(FATAL_ERROR "source input2d.in was modified during rendering")
endif()

message(STATUS "input rendering checks passed; source hash ${HASH_AFTER}")
