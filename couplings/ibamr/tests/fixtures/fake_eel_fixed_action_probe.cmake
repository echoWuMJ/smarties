foreach(required FAKE_RANK INPUT_FILE TASK_FILE ACTION DECISIONS)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "fake probe requires ${required}")
  endif()
endforeach()

if(NOT EXISTS "${INPUT_FILE}" OR NOT EXISTS "${TASK_FILE}")
  message(FATAL_ERROR "fake probe did not receive copied input/task files")
endif()
if(NOT EXISTS "eel2d.vertex")
  message(FATAL_ERROR "fake probe did not run in an isolated fixture directory")
endif()
if(NOT ACTION STREQUAL "1.0" OR NOT DECISIONS STREQUAL "2")
  message(FATAL_ERROR "fake probe received action=${ACTION} decisions=${DECISIONS}")
endif()
if(DEFINED FAKE_SLEEP_SECONDS AND NOT FAKE_SLEEP_SECONDS STREQUAL "")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E sleep "${FAKE_SLEEP_SECONDS}"
    COMMAND_ERROR_IS_FATAL ANY)
endif()

set(stream [=[
EEL_FIXED_ACTION_STEP decision=1 environment_ranks=@RANK@ action=1 target_ratio=1.5 previous_ratio=1 applied_ratio=1.1 start_time=0 end_time=0.1251 ibamr_steps=1251 start_com_x=0 start_com_y=0 end_com_x=0.01 end_com_y=0 displacement_x=0.01 displacement_y=0 forward_displacement=0.01 forward_velocity=0.07993605115907275 phase_end=0.785628 lagrangian_points=2932 reward_tracking=-0.057648 reward_frequency=-0.03 reward_smoothness=-0.04 reward_total=-0.127648
EEL_FIXED_ACTION_STEP decision=2 environment_ranks=@RANK@ action=1 target_ratio=1.5 previous_ratio=1.1 applied_ratio=1.2 start_time=0.1251 end_time=0.2502 ibamr_steps=1251 start_com_x=0.01 start_com_y=0 end_com_x=0.021 end_com_y=0 displacement_x=0.011 displacement_y=0 forward_displacement=0.011 forward_velocity=0.08792965627498002 phase_end=1.649256 lagrangian_points=2932 reward_tracking=-0.05023 reward_frequency=-0.12 reward_smoothness=-0.04 reward_total=-0.21023
EEL_FIXED_ACTION_SUMMARY environment_ranks=@RANK@ decisions=2 ibamr_steps=2502 elapsed_time=0.2502 displacement_x=0.021 displacement_y=0 forward_displacement=0.021 final_phase=1.649256 lagrangian_points=2932 reward_tracking=-0.107878 reward_frequency=-0.15 reward_smoothness=-0.08 reward_total=-0.337878
]=])
string(REPLACE "@RANK@" "${FAKE_RANK}" stream "${stream}")
if(FAKE_MUTATE_COM AND FAKE_RANK STREQUAL "2")
  string(REPLACE "end_com_x=0.01" "end_com_x=0.02" stream "${stream}")
endif()
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E echo
    "FAKE_PROBE_INVOCATION rank=${FAKE_RANK} input-file=${INPUT_FILE} task-file=${TASK_FILE} action=${ACTION} decisions=${DECISIONS}\n${stream}")
