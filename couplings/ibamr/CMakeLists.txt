add_library(ibamr_coupling_core STATIC
  core/MpiSession.cpp
  core/CommunicatorLayout.cpp)
target_include_directories(ibamr_coupling_core PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/core)
target_link_libraries(ibamr_coupling_core PUBLIC MPI::MPI_CXX)

if(BUILD_IBAMR_COUPLING)
  find_package(IBAMR CONFIG REQUIRED
    PATHS "$ENV{IBAMR_ROOT}/lib64/cmake/ibamr"
    NO_DEFAULT_PATH)

  add_library(ibamr_eel2d_support STATIC
    cases/eel2d/upstream/IBEELKinematics.cpp)
  target_include_directories(ibamr_eel2d_support PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/cases/eel2d/upstream)
  target_link_libraries(ibamr_eel2d_support PUBLIC IBAMR::IBAMR2d)
endif()

if(BUILD_IBAMR_COUPLING_TESTS)
  add_subdirectory(tests)
endif()
