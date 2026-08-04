add_library(ibamr_coupling_core STATIC
  core/MpiSession.cpp
  core/CommunicatorLayout.cpp)
target_include_directories(ibamr_coupling_core PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/core)
target_link_libraries(ibamr_coupling_core PUBLIC MPI::MPI_CXX)

if(BUILD_IBAMR_COUPLING_TESTS)
  add_subdirectory(tests)
endif()
