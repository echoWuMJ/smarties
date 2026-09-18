add_executable(borrowed_engine_shutdown test_borrowed_engine_shutdown.cpp)
target_link_libraries(borrowed_engine_shutdown PRIVATE libsmarties MPI::MPI_CXX)

add_executable(smarties_network_precision_probe test_network_precision.cpp)
target_include_directories(smarties_network_precision_probe PRIVATE
  "${PROJECT_SOURCE_DIR}/source")
target_compile_definitions(smarties_network_precision_probe PRIVATE
  SMARTIES_EXPECT_NNREAL_BYTES=${SMARTIES_EXPECT_NNREAL_BYTES})
target_link_libraries(smarties_network_precision_probe PRIVATE libsmarties)

add_executable(network_audit_test test_network_audit.cpp)
target_include_directories(network_audit_test PRIVATE
  "${PROJECT_SOURCE_DIR}/source")
target_link_libraries(network_audit_test PRIVATE libsmarties)

add_executable(smarties_network_update_probe network_update_probe.cpp)
target_include_directories(smarties_network_update_probe PRIVATE
  "${PROJECT_SOURCE_DIR}/source")
target_link_libraries(smarties_network_update_probe PRIVATE
  libsmarties MPI::MPI_CXX)

add_executable(learner_audit_options test_learner_audit_options.cpp)
target_include_directories(learner_audit_options PRIVATE
  "${PROJECT_SOURCE_DIR}/source")
target_compile_definitions(learner_audit_options PRIVATE
  SMARTIES_LEARNER_APPROXIMATOR_SOURCE=\"${PROJECT_SOURCE_DIR}/source/smarties/Learners/Learner_approximator.cpp\")
target_link_libraries(learner_audit_options PRIVATE libsmarties MPI::MPI_CXX)

add_executable(cpu_learner_environment_test test_cpu_learner_environment.cpp)
target_link_libraries(cpu_learner_environment_test PRIVATE
  cpu_learner_environment_model)

add_executable(borrowed_communicator_alias test_borrowed_communicator_alias.cpp)
target_include_directories(borrowed_communicator_alias PRIVATE
  "${PROJECT_SOURCE_DIR}/source")
target_link_libraries(borrowed_communicator_alias PRIVATE libsmarties MPI::MPI_CXX)

add_executable(curriculum_arguments test_curriculum_arguments.cpp)
target_include_directories(curriculum_arguments PRIVATE
  "${PROJECT_SOURCE_DIR}/source")
target_link_libraries(curriculum_arguments PRIVATE libsmarties MPI::MPI_CXX)

add_executable(owned_engine_shutdown test_owned_engine_shutdown.cpp)
target_link_libraries(owned_engine_shutdown PRIVATE libsmarties MPI::MPI_CXX)

add_executable(mpi_session test_mpi_session.cpp)
target_link_libraries(mpi_session PRIVATE ibamr_coupling_core)

add_executable(communicator_layout test_communicator_layout.cpp)
target_link_libraries(communicator_layout PRIVATE ibamr_coupling_core)

add_executable(distributed_environment_shutdown
  test_distributed_environment_shutdown.cpp)
target_include_directories(distributed_environment_shutdown PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../core)
target_link_libraries(distributed_environment_shutdown PRIVATE
  ibamr_coupling_core
  libsmarties
  MPI::MPI_CXX)

add_executable(tail_beat_phase_test test_tail_beat_phase.cpp)

add_executable(eel_control_restart_test test_eel_control_restart.cpp)
target_link_libraries(eel_control_restart_test PRIVATE ibamr_eel_control)
add_test(NAME eel_control_restart COMMAND eel_control_restart_test)

add_executable(paired_episode_state_test test_paired_episode_state.cpp)
target_link_libraries(paired_episode_state_test PRIVATE ibamr_eel_control)
add_test(NAME paired_episode_state COMMAND paired_episode_state_test)

add_executable(episode_checkpoint_test test_episode_checkpoint.cpp)
target_include_directories(episode_checkpoint_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
target_link_libraries(episode_checkpoint_test PRIVATE MPI::MPI_CXX)

if(BUILD_IBAMR_COUPLING)
  add_executable(eel_cfd_restart_probe eel_cfd_restart_probe.cpp)
  target_link_libraries(eel_cfd_restart_probe PRIVATE ibamr_eel2d_environment)
endif()
target_include_directories(tail_beat_phase_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
target_link_libraries(tail_beat_phase_test PRIVATE ibamr_eel_control)

add_executable(official_eel_formula_test test_official_eel_formula.cpp)
target_include_directories(official_eel_formula_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
target_link_libraries(official_eel_formula_test PRIVATE ibamr_eel_control)

add_executable(eel_control_task_test test_eel_control_task.cpp)
target_include_directories(eel_control_task_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
target_link_libraries(eel_control_task_test PRIVATE ibamr_eel_control)

add_executable(eel_velocity_probes_test test_eel_velocity_probes.cpp)
target_include_directories(eel_velocity_probes_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
target_link_libraries(eel_velocity_probes_test PRIVATE ibamr_eel_control)

add_executable(eel_near_wall_task_test test_eel_near_wall_task.cpp)
target_link_libraries(eel_near_wall_task_test PRIVATE ibamr_eel_control)
add_test(NAME eel_near_wall_task COMMAND eel_near_wall_task_test)

add_executable(eel_control_measurement_test test_eel_control_measurement.cpp)
target_include_directories(eel_control_measurement_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
target_link_libraries(eel_control_measurement_test PRIVATE ibamr_eel_control)

add_executable(eel_layout_invariant_test test_eel_layout_invariant.cpp)
target_include_directories(eel_layout_invariant_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
target_link_libraries(eel_layout_invariant_test PRIVATE ibamr_eel_control)

add_executable(eel_logical_segments_test test_eel_logical_segments.cpp)
target_include_directories(eel_logical_segments_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
target_link_libraries(eel_logical_segments_test PRIVATE ibamr_eel_control)

add_test(
  NAME borrowed_engine_shutdown
  COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 1
          ${MPIEXEC_PREFLAGS} $<TARGET_FILE:borrowed_engine_shutdown>
          ${MPIEXEC_POSTFLAGS})

add_test(
  NAME borrowed_communicator_alias
  COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 1
          ${MPIEXEC_PREFLAGS} $<TARGET_FILE:borrowed_communicator_alias>
          ${MPIEXEC_POSTFLAGS})

add_test(
  NAME curriculum_arguments
  COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 1
          ${MPIEXEC_PREFLAGS} $<TARGET_FILE:curriculum_arguments>
          ${MPIEXEC_POSTFLAGS})

add_test(NAME owned_engine_shutdown COMMAND owned_engine_shutdown)

add_test(NAME smarties_network_precision
  COMMAND smarties_network_precision_probe)

add_test(NAME smarties_network_audit COMMAND network_audit_test)

add_test(
  NAME smarties_network_update_consistency
  COMMAND "${CMAKE_COMMAND}"
    "-DPROBE_EXECUTABLE=$<TARGET_FILE:smarties_network_update_probe>"
    "-DCOMPARE_MODULE=${CMAKE_CURRENT_SOURCE_DIR}/NetworkAuditCompare.cmake"
    "-DRUN_ROOT=${CMAKE_CURRENT_BINARY_DIR}/network-update-consistency"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/test_network_update_consistency.cmake")
set_tests_properties(smarties_network_update_consistency PROPERTIES TIMEOUT 300)

add_test(
  NAME learner_audit_options
  COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 1
          ${MPIEXEC_PREFLAGS} $<TARGET_FILE:learner_audit_options>
          ${MPIEXEC_POSTFLAGS})

add_test(NAME cpu_learner_environment COMMAND cpu_learner_environment_test)

if(UNIX)
  set(CPU_LEARNER_PROTOCOL_RUN_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/cpu-learner-protocol")
  add_test(
    NAME cpu_learner_protocol
    COMMAND "${CMAKE_COMMAND}"
      "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
      "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
      "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
      "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
      "-DPROBE_EXECUTABLE=$<TARGET_FILE:smarties_cpu_learner_environment>"
      "-DSETTINGS_FILE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/cpu_learner_smoke.json"
      "-DRUN_ROOT=${CPU_LEARNER_PROTOCOL_RUN_DIR}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/test_exact_train_updates.cmake")
  set_tests_properties(cpu_learner_protocol PROPERTIES
    TIMEOUT 120)

  add_test(
    NAME cpu_learner_evaluation
    COMMAND "${CMAKE_COMMAND}"
      "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
      "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
      "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
      "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
      "-DPROBE_EXECUTABLE=$<TARGET_FILE:smarties_cpu_learner_environment>"
      "-DSETTINGS_FILE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/cpu_learner_smoke.json"
      "-DRUN_ROOT=${CMAKE_CURRENT_BINARY_DIR}/cpu-learner-evaluation"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/test_cpu_learner_evaluation.cmake")
  set_tests_properties(cpu_learner_evaluation PROPERTIES TIMEOUT 75)
endif()

add_test(NAME mpi_session COMMAND mpi_session)

add_test(NAME tail_beat_phase COMMAND tail_beat_phase_test)

add_test(NAME official_eel_formula COMMAND official_eel_formula_test)

add_test(
  NAME eel_control_task
  COMMAND eel_control_task_test
          ${CMAKE_CURRENT_SOURCE_DIR}/fixtures/speed_tracking_test.conf)

add_test(NAME eel_velocity_probes COMMAND eel_velocity_probes_test)

add_test(NAME eel_control_measurement COMMAND eel_control_measurement_test)

add_test(NAME eel_layout_invariant COMMAND eel_layout_invariant_test)

add_test(NAME eel_logical_segments COMMAND eel_logical_segments_test)

add_test(
  NAME eel_final_visualization_contract
  COMMAND "${CMAKE_COMMAND}"
    "-DCOUPLING_ROOT=${CMAKE_CURRENT_SOURCE_DIR}/.."
    -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_final_visualization_contract.cmake")

add_test(
  NAME eel_consistency_compare
  COMMAND "${CMAKE_COMMAND}"
    "-DCOMPARE_MODULE=${CMAKE_CURRENT_SOURCE_DIR}/EelConsistencyCompare.cmake"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_consistency_compare.cmake")

add_test(
  NAME eel_mpi_consistency_orchestration
  COMMAND "${CMAKE_COMMAND}"
    "-DORCHESTRATOR=${CMAKE_CURRENT_SOURCE_DIR}/test_eel_mpi_consistency.cmake"
    "-DFAKE_PROBE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/fake_eel_fixed_action_probe.cmake"
    "-DREGISTRATION_FILE=${CMAKE_CURRENT_LIST_FILE}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_mpi_consistency_orchestration.cmake")

if(UNIX)
  add_test(
    NAME cpu_learner_validation_scripts
    COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/test_cpu_learner_validation_scripts.sh")
  set_tests_properties(cpu_learner_validation_scripts PROPERTIES
    LABELS "fast;learner"
    TIMEOUT 30)

  add_test(
    NAME node3_scripts
    COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/test_node3_scripts.sh")

  if(DEFINED ENV{SAMRAI_SOURCE_ROOT})
    if(DEFINED ENV{SAMRAI_PRISTINE_SOURCE_ROOT})
      set(SAMRAI_PATCH_FIXTURE_SOURCE_ROOT "$ENV{SAMRAI_PRISTINE_SOURCE_ROOT}")
    else()
      set(SAMRAI_PATCH_FIXTURE_SOURCE_ROOT "$ENV{SAMRAI_SOURCE_ROOT}")
    endif()
    add_test(
      NAME samrai_subcommunicator_patch
      COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/test_samrai_subcommunicator_patch.sh")
    set_tests_properties(samrai_subcommunicator_patch PROPERTIES
      ENVIRONMENT "SAMRAI_SOURCE_ROOT=${SAMRAI_PATCH_FIXTURE_SOURCE_ROOT}")
  endif()
endif()

add_test(
  NAME communicator_layout
  COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 2
          ${MPIEXEC_PREFLAGS} $<TARGET_FILE:communicator_layout>
          ${MPIEXEC_POSTFLAGS})

if(UNIX)
  add_test(
    NAME distributed_environment_shutdown
    COMMAND "${CMAKE_COMMAND}"
      "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
      "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
      "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
      "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
      "-DTEST_EXECUTABLE=$<TARGET_FILE:distributed_environment_shutdown>"
      "-DSETTINGS_FILE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/cpu_learner_smoke.json"
      "-DRUN_ROOT=${CMAKE_CURRENT_BINARY_DIR}/distributed-environment-shutdown"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/test_distributed_environment_shutdown.cmake")
  set_tests_properties(distributed_environment_shutdown PROPERTIES TIMEOUT 30)
endif()

if(BUILD_IBAMR_COUPLING)
  add_executable(eel_smoke_protocol test_eel_smoke_protocol.cpp)
  target_include_directories(eel_smoke_protocol PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../core
    ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
  target_link_libraries(eel_smoke_protocol PRIVATE
    ibamr_eel2d_adapter
    ibamr_coupling_core
    libsmarties)

  add_executable(eel_control_protocol test_eel_control_protocol.cpp)
  target_include_directories(eel_control_protocol PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../core
    ${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d)
  target_link_libraries(eel_control_protocol PRIVATE
    ibamr_eel2d_adapter
    ibamr_coupling_core
    libsmarties)

  add_executable(eel_environment_smoke test_eel_environment_smoke.cpp)
  target_link_libraries(eel_environment_smoke PRIVATE
    ibamr_eel2d_environment
    ibamr_coupling_core)

  add_executable(eel_environment_control test_eel_environment_control.cpp)
  target_link_libraries(eel_environment_control PRIVATE
    ibamr_eel2d_environment
    ibamr_coupling_core)

  add_executable(eel_terminal_visualization test_eel_terminal_visualization.cpp)
  target_link_libraries(eel_terminal_visualization PRIVATE
    ibamr_eel2d_environment
    ibamr_coupling_core)

  set(EEL_ENVIRONMENT_RUN_DIR "${CMAKE_CURRENT_BINARY_DIR}/eel-environment-smoke")
  file(MAKE_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DFIDELITY_FILE=${CMAKE_CURRENT_SOURCE_DIR}/../configs/fidelity/coarse.conf"
      "-DEEL_END_TIME=10.0"
      "-DOUTPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d.coarse"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/render_input.cmake"
    COMMAND_ERROR_IS_FATAL ANY)
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DFIDELITY_FILE=${CMAKE_CURRENT_SOURCE_DIR}/../configs/fidelity/medium.conf"
      "-DEEL_END_TIME=10.0"
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
  configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/fixtures/speed_tracking_protocol.conf"
    "${EEL_ENVIRONMENT_RUN_DIR}/task.conf"
    COPYONLY)
  configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/fixtures/speed_tracking_continuing.conf"
    "${EEL_ENVIRONMENT_RUN_DIR}/task.continuing.conf"
    COPYONLY)

  set(EEL_TERMINAL_VISUALIZATION_RUN_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/eel-terminal-visualization")
  file(MAKE_DIRECTORY "${EEL_TERMINAL_VISUALIZATION_RUN_DIR}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DFIDELITY_FILE=${CMAKE_CURRENT_SOURCE_DIR}/../configs/fidelity/medium.conf"
      "-DEEL_END_TIME=0.0001"
      "-DEEL_VIZ_DUMP_INTERVAL=1"
      "-DEEL_RESTART_DUMP_INTERVAL=0"
      "-DEEL_TIMER_DUMP_INTERVAL=0"
      "-DOUTPUT_FILE=${EEL_TERMINAL_VISUALIZATION_RUN_DIR}/input2d"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/render_input.cmake"
    COMMAND_ERROR_IS_FATAL ANY)
  configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/../cases/eel2d/upstream/eel2d.vertex"
    "${EEL_TERMINAL_VISUALIZATION_RUN_DIR}/eel2d.vertex"
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
    NAME eel_environment_control
    COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 1
            ${MPIEXEC_PREFLAGS} $<TARGET_FILE:eel_environment_control>
            input2d ${MPIEXEC_POSTFLAGS})
  set_tests_properties(eel_environment_control PROPERTIES
    WORKING_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}"
    TIMEOUT 180)

  add_test(
    NAME eel_terminal_visualization
    COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 1
            ${MPIEXEC_PREFLAGS} $<TARGET_FILE:eel_terminal_visualization>
            input2d ${MPIEXEC_POSTFLAGS})
  set_tests_properties(eel_terminal_visualization PROPERTIES
    WORKING_DIRECTORY "${EEL_TERMINAL_VISUALIZATION_RUN_DIR}"
    TIMEOUT 180)

  add_test(
    NAME eel_layout_mismatch_guard
    COMMAND "${CMAKE_COMMAND}"
      "-DTEST_EXECUTABLE=$<TARGET_FILE:eel_environment_smoke>"
      "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
      "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
      "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
      "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
      "-DINPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d.coarse"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_layout_mismatch.cmake")
  set_tests_properties(eel_layout_mismatch_guard PROPERTIES
    WORKING_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}"
    TIMEOUT 360)

  add_test(
    NAME frequency_response_probe
    COMMAND "${CMAKE_COMMAND}"
      "-DPROBE_EXECUTABLE=${CMAKE_CURRENT_BINARY_DIR}/../frequency_response_probe"
      "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
      "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
      "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
      "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
      "-DINPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/test_frequency_response_probe.cmake")
  set_tests_properties(frequency_response_probe PROPERTIES
    WORKING_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}"
    TIMEOUT 900)

  add_test(
    NAME eel_fixed_action_probe
    COMMAND "${CMAKE_COMMAND}"
      "-DPROBE_EXECUTABLE=${CMAKE_CURRENT_BINARY_DIR}/../frequency_response_probe"
      "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
      "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
      "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
      "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
      "-DINPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d"
      "-DTASK_FILE=${EEL_ENVIRONMENT_RUN_DIR}/task.conf"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_fixed_action_probe.cmake")
  set_tests_properties(eel_fixed_action_probe PROPERTIES
    WORKING_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}"
    TIMEOUT 900)

  add_test(
    NAME eel_mpi_consistency
    COMMAND "${CMAKE_COMMAND}"
      "-DPROBE_EXECUTABLE=$<TARGET_FILE:frequency_response_probe>"
      "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
      "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
      "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
      "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
      "-DCHILD_TIMEOUT_SECONDS=900"
      "-DINPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d"
      "-DVERTEX_FILE=${EEL_ENVIRONMENT_RUN_DIR}/eel2d.vertex"
      "-DTASK_FILE=${EEL_ENVIRONMENT_RUN_DIR}/task.conf"
      "-DCOMPARE_MODULE=${CMAKE_CURRENT_SOURCE_DIR}/EelConsistencyCompare.cmake"
      "-DRUN_ROOT=${CMAKE_CURRENT_BINARY_DIR}/eel-mpi-consistency"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_mpi_consistency.cmake")
  set_tests_properties(eel_mpi_consistency PROPERTIES
    LABELS "physical;node3"
    TIMEOUT 1860)

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

  add_test(
    NAME eel_control_protocol
    COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 2
            ${MPIEXEC_PREFLAGS} $<TARGET_FILE:eel_control_protocol>
            --nMasters 1
            --nThreads 1
            --nEnvironments 1
            --workerProcessesPerEnv 1
            --learnersOnWorkers 0
            --nTrainSteps 0
            --restart none
            --setupFolder .
            --eel-mode speed-tracking
            --input-file input2d
            --task-file task.conf
            ${MPIEXEC_POSTFLAGS})
  set_tests_properties(eel_control_protocol PROPERTIES
    WORKING_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}"
    TIMEOUT 1800)

  add_test(
    NAME eel_continuing_protocol
    COMMAND "${CMAKE_COMMAND}"
      "-DTEST_EXECUTABLE=$<TARGET_FILE:eel_control_protocol>"
      "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
      "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
      "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
      "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
      "-DINPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d"
      "-DSETTINGS_FILE=${CMAKE_CURRENT_SOURCE_DIR}/../configs/training/cpu_learner_eel_activity.json"
      "-DTASK_FILE=${EEL_ENVIRONMENT_RUN_DIR}/task.continuing.conf"
      "-DVERTEX_FILE=${EEL_ENVIRONMENT_RUN_DIR}/eel2d.vertex"
      "-DRUN_ROOT=${CMAKE_CURRENT_BINARY_DIR}/eel-continuing-protocol"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_continuing_protocol.cmake")
  set_tests_properties(eel_continuing_protocol PROPERTIES
    WORKING_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}"
    TIMEOUT 1920)

  add_test(
    NAME eel_smoke_failure_after_mpi
    COMMAND "${CMAKE_COMMAND}"
      "-DTEST_EXECUTABLE=$<TARGET_FILE:eel_smoke_protocol>"
      "-DMPIEXEC_EXECUTABLE=${MPIEXEC_EXECUTABLE}"
      "-DMPIEXEC_NUMPROC_FLAG=${MPIEXEC_NUMPROC_FLAG}"
      "-DMPIEXEC_PREFLAGS=${MPIEXEC_PREFLAGS}"
      "-DMPIEXEC_POSTFLAGS=${MPIEXEC_POSTFLAGS}"
      "-DINPUT_FILE=${EEL_ENVIRONMENT_RUN_DIR}/input2d"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/test_eel_smoke_failure_after_mpi.cmake")
  set_tests_properties(eel_smoke_failure_after_mpi PROPERTIES
    WORKING_DIRECTORY "${EEL_ENVIRONMENT_RUN_DIR}"
    TIMEOUT 300)

  option(IBAMR_SMARTIES_ENABLE_NODE3_EEL_LEARNER_ACTIVITY
    "Register the explicit node3-only eel learner activity target" OFF)
  if(IBAMR_SMARTIES_ENABLE_NODE3_EEL_LEARNER_ACTIVITY)
    add_test(
      NAME eel_learner_activity_node3
      COMMAND bash
        "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/run_node3.sh" train
        --source "${PROJECT_SOURCE_DIR}"
        --build "${PROJECT_BINARY_DIR}"
        --envs 1
        --ranks-per-env 2
        --learner-ranks 1
        --learner-threads 4
        --fidelity medium
        --training
          couplings/ibamr/configs/training/cpu_learner_eel_activity.json
        --task
          couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf
        --train-updates 2)
    set_tests_properties(eel_learner_activity_node3 PROPERTIES
      LABELS "physical;node3;learner"
      RUN_SERIAL TRUE
      TIMEOUT 7200)
  endif()
endif()

add_executable(native_training_restart_test native_training_restart.cpp)
target_include_directories(native_training_restart_test PRIVATE "${PROJECT_SOURCE_DIR}/source")
target_link_libraries(native_training_restart_test PRIVATE libsmarties MPI::MPI_CXX)
add_test(NAME native_training_restart COMMAND native_training_restart_test)
