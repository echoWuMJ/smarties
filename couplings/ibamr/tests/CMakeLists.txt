add_executable(borrowed_engine_shutdown test_borrowed_engine_shutdown.cpp)
target_link_libraries(borrowed_engine_shutdown PRIVATE libsmarties MPI::MPI_CXX)

add_executable(owned_engine_shutdown test_owned_engine_shutdown.cpp)
target_link_libraries(owned_engine_shutdown PRIVATE libsmarties MPI::MPI_CXX)

add_executable(mpi_session test_mpi_session.cpp)
target_link_libraries(mpi_session PRIVATE ibamr_coupling_core)

add_executable(communicator_layout test_communicator_layout.cpp)
target_link_libraries(communicator_layout PRIVATE ibamr_coupling_core)

add_test(
  NAME borrowed_engine_shutdown
  COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 1
          ${MPIEXEC_PREFLAGS} $<TARGET_FILE:borrowed_engine_shutdown>
          ${MPIEXEC_POSTFLAGS})

add_test(NAME owned_engine_shutdown COMMAND owned_engine_shutdown)

add_test(NAME mpi_session COMMAND mpi_session)

if(UNIX)
  add_test(
    NAME node3_scripts
    COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/test_node3_scripts.sh")

  if(DEFINED ENV{SAMRAI_SOURCE_ROOT})
    add_test(
      NAME samrai_subcommunicator_patch
      COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/test_samrai_subcommunicator_patch.sh")
    set_tests_properties(samrai_subcommunicator_patch PROPERTIES
      ENVIRONMENT "SAMRAI_SOURCE_ROOT=$ENV{SAMRAI_SOURCE_ROOT}")
  endif()
endif()

add_test(
  NAME communicator_layout
  COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 2
          ${MPIEXEC_PREFLAGS} $<TARGET_FILE:communicator_layout>
          ${MPIEXEC_POSTFLAGS})

if(BUILD_IBAMR_COUPLING)
  add_executable(eel_smoke_protocol test_eel_smoke_protocol.cpp)
  target_include_directories(eel_smoke_protocol PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../core
    ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
  target_link_libraries(eel_smoke_protocol PRIVATE
    ibamr_eel2d_adapter
    ibamr_coupling_core
    libsmarties)

  add_executable(eel_environment_smoke test_eel_environment_smoke.cpp)
  target_link_libraries(eel_environment_smoke PRIVATE
    ibamr_eel2d_environment
    ibamr_coupling_core)

  set(EEL_ENVIRONMENT_RUN_DIR "${CMAKE_CURRENT_BINARY_DIR}/eel-environment-smoke")
  file(MAKE_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DFIDELITY_FILE=${CMAKE_CURRENT_SOURCE_DIR}/../configs/fidelity/coarse.conf"
      "-DOUTPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/render_input.cmake"
    COMMAND_ERROR_IS_FATAL ANY)
  configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d/upstream/eel2d.vertex"
    "${EEL_ENVIRONMENT_RUN_DIR}/eel2d.vertex"
    COPYONLY)
  configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/../configs/training/smoke.json"
    "${EEL_ENVIRONMENT_RUN_DIR}/settings.json"
    COPYONLY)

  add_test(
    NAME eel_environment_smoke
    COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 1
            ${MPIEXEC_PREFLAGS} $<TARGET_FILE:eel_environment_smoke>
            input2d ${MPIEXEC_POSTFLAGS})
  set_tests_properties(eel_environment_smoke PROPERTIES
    WORKING_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}"
    TIMEOUT 180)

  add_test(
    NAME eel_smoke_protocol
    COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 2
            ${MPIEXEC_PREFLAGS} $<TARGET_FILE:eel_smoke_protocol>
            --nMasters 1
            --nThreads 1
            --nEnvironments 1
            --workerProcessesPerEnv 1
            --learnersOnWorkers 0
            --nTrainSteps 0
            --restart none
            --setupFolder .
            --input-file input2d
            --smoke-steps 1
            ${MPIEXEC_POSTFLAGS})
  set_tests_properties(eel_smoke_protocol PROPERTIES
    WORKING_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}"
    TIMEOUT 300)
endif()
