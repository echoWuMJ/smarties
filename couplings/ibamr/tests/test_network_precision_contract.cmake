if(NOT DEFINED ROOT_CMAKE OR NOT EXISTS "${ROOT_CMAKE}")
  message(FATAL_ERROR "precision contract requires ROOT_CMAKE")
endif()

file(READ "${ROOT_CMAKE}" source)

string(REGEX MATCH
  "if *\\(SINGLE_PRECISION\\)[\r\n ]+target_compile_definitions *\\([^\n]+SINGLE_PREC"
  precision_block "${source}")
if(precision_block STREQUAL "")
  message(FATAL_ERROR "SINGLE_PRECISION does not control SINGLE_PREC")
endif()

string(REGEX MATCH
  "if *\\(COMPILE_PY_SO\\)[^#]*target_compile_(options|definitions) *\\([^\n]+SINGLE_PREC"
  python_coupled_block "${source}")
if(NOT python_coupled_block STREQUAL "")
  message(FATAL_ERROR "network precision still depends on COMPILE_PY_SO")
endif()
