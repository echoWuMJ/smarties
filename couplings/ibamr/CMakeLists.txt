add_library(ibamr_coupling_core STATIC
  core/MpiSession.cpp
  core/CommunicatorLayout.cpp
  core/CouplingDriver.cpp)
target_include_directories(ibamr_coupling_core PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/core)
target_link_libraries(ibamr_coupling_core PUBLIC MPI::MPI_CXX libsmarties)

add_library(ibamr_eel_control STATIC
  cases/eel2d/TailBeatPhase.cpp
  cases/eel2d/EelLayoutInvariant.cpp
  cases/eel2d/EelControlMeasurement.cpp
  cases/eel2d/EelControlTask.cpp
  cases/eel2d/EelLogicalSegments.cpp)
target_include_directories(ibamr_eel_control PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/cases/eel2d)
target_compile_features(ibamr_eel_control PUBLIC cxx_std_14)

add_library(cpu_learner_environment_model STATIC
  cases/synthetic/CpuLearnerEnvironment.cpp)
target_include_directories(cpu_learner_environment_model PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/cases/synthetic)
target_compile_features(cpu_learner_environment_model PUBLIC cxx_std_14)

add_executable(smarties_cpu_learner_environment
  cases/synthetic/main.cpp)
target_link_libraries(smarties_cpu_learner_environment PRIVATE
  cpu_learner_environment_model
  ibamr_coupling_core)
set_target_properties(smarties_cpu_learner_environment PROPERTIES
  BUILD_RPATH "${lib_output}")

if(BUILD_IBAMR_COUPLING)
  find_package(IBAMR CONFIG REQUIRED
    PATHS "$ENV{IBAMR_ROOT}/lib64/cmake/ibamr"
    NO_DEFAULT_PATH)

  add_library(ibamr_eel2d_support STATIC
    cases/eel2d/upstream/IBEELKinematics.cpp)
  target_include_directories(ibamr_eel2d_support PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/cases/eel2d/upstream
    ${CMAKE_CURRENT_SOURCE_DIR}/cases/eel2d)
  target_link_libraries(ibamr_eel2d_support PUBLIC
    ibamr_eel_control
    IBAMR::IBAMR2d)

  add_library(ibamr_eel2d_environment STATIC
    cases/eel2d/EelEnvironment.cpp)
  target_include_directories(ibamr_eel2d_environment PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/cases/eel2d)
  target_link_libraries(ibamr_eel2d_environment PUBLIC
    ibamr_eel2d_support
    ibamr_coupling_core
    IBAMR::IBAMR2d)

  add_library(ibamr_eel2d_adapter STATIC
    cases/eel2d/EelSmartiesAdapter.cpp)
  target_include_directories(ibamr_eel2d_adapter PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/cases/eel2d)
  target_link_libraries(ibamr_eel2d_adapter PUBLIC
    ibamr_eel2d_environment
    libsmarties)

  add_executable(ibamr_eel2d_smoke cases/eel2d/main.cpp)
  target_link_libraries(ibamr_eel2d_smoke PRIVATE
    ibamr_coupling_core
    ibamr_eel2d_adapter)
  set_target_properties(ibamr_eel2d_smoke PROPERTIES
    BUILD_RPATH "${lib_output}")

  add_executable(frequency_response_probe
    cases/eel2d/frequency_response_probe.cpp)
  target_link_libraries(frequency_response_probe PRIVATE
    ibamr_coupling_core
    ibamr_eel2d_environment)
endif()

if(BUILD_IBAMR_COUPLING_TESTS)
  add_subdirectory(tests)
endif()
