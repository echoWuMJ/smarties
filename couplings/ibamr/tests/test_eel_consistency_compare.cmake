include("${COMPARE_MODULE}")

function(expect_result name one two expected report_pattern)
  compare_eel_consistency_streams(
    ONE_STREAM "${one}" TWO_STREAM "${two}"
    EXPECTED_DECISIONS 2 OUT_VERDICT verdict OUT_REPORT report)
  if(NOT verdict STREQUAL "${expected}")
    message(FATAL_ERROR "${name}: expected ${expected}, got ${verdict}: ${report}")
  endif()
  if(NOT report MATCHES "${report_pattern}")
    message(FATAL_ERROR "${name}: report '${report}' did not match '${report_pattern}'")
  endif()
endfunction()

# This fails if the comparator treats decomposition rank count as physical output.
set(one_stream [=[
EEL_FIXED_ACTION_STEP decision=1 environment_ranks=1 action=1 target_ratio=1.5 previous_ratio=1 applied_ratio=1.1 start_time=0 end_time=0.1251 ibamr_steps=1251 start_com_x=0 start_com_y=0 end_com_x=0.01 end_com_y=0 displacement_x=0.01 displacement_y=0 forward_displacement=0.01 forward_velocity=0.07993605115907275 phase_end=0.785628 lagrangian_points=2932 reward_tracking=-0.057648 reward_frequency=-0.03 reward_smoothness=-0.04 reward_total=-0.127648
EEL_FIXED_ACTION_STEP decision=2 environment_ranks=1 action=1 target_ratio=1.5 previous_ratio=1.1 applied_ratio=1.2 start_time=0.1251 end_time=0.2502 ibamr_steps=1251 start_com_x=0.01 start_com_y=0 end_com_x=0.021 end_com_y=0 displacement_x=0.011 displacement_y=0 forward_displacement=0.011 forward_velocity=0.08792965627498002 phase_end=1.649256 lagrangian_points=2932 reward_tracking=-0.05023 reward_frequency=-0.12 reward_smoothness=-0.04 reward_total=-0.21023
EEL_FIXED_ACTION_SUMMARY environment_ranks=1 decisions=2 ibamr_steps=2502 elapsed_time=0.2502 displacement_x=0.021 displacement_y=0 forward_displacement=0.021 final_phase=1.649256 lagrangian_points=2932 reward_tracking=-0.107878 reward_frequency=-0.15 reward_smoothness=-0.08 reward_total=-0.337878
]=])
string(REPLACE "environment_ranks=1" "environment_ranks=2" two_stream "${one_stream}")
expect_result("matching physical streams" "${one_stream}" "${two_stream}" "PASS" "all fields match")

# These literal deltas enforce the required numerical acceptance contract.
# A permissive 1e-9/1e-6 comparator incorrectly accepts every "outside" case.
string(REPLACE "target_ratio=1.5" "target_ratio=1.500000000002" control_step_inside "${two_stream}")
expect_result("control step inside tolerance" "${one_stream}" "${control_step_inside}" "PASS" "all fields match")
string(REPLACE "target_ratio=1.5" "target_ratio=1.500000000003" control_step_outside "${two_stream}")
expect_result("control step outside tolerance" "${one_stream}" "${control_step_outside}" "PHYSICAL_MISMATCH" "decision=1 field=target_ratio")

string(REPLACE "end_com_x=0.01" "end_com_x=0.0100000001" physical_step_inside "${two_stream}")
expect_result("physical step inside tolerance" "${one_stream}" "${physical_step_inside}" "PASS" "all fields match")
string(REPLACE "end_com_x=0.01" "end_com_x=0.0100000003" physical_step_outside "${two_stream}")
expect_result("physical step outside tolerance" "${one_stream}" "${physical_step_outside}" "PHYSICAL_MISMATCH" "decision=1 field=end_com_x")

string(REPLACE "reward_total=-0.127648" "reward_total=-0.127648001" reward_step_inside "${two_stream}")
expect_result("reward step inside tolerance" "${one_stream}" "${reward_step_inside}" "PASS" "all fields match")
string(REPLACE "reward_total=-0.127648" "reward_total=-0.127648002" reward_step_outside "${two_stream}")
expect_result("reward step outside tolerance" "${one_stream}" "${reward_step_outside}" "REWARD_MISMATCH" "decision=1 field=reward_total")

string(REPLACE "elapsed_time=0.2502" "elapsed_time=0.250200000001" control_summary_inside "${two_stream}")
expect_result("control summary inside tolerance" "${one_stream}" "${control_summary_inside}" "PASS" "all fields match")
string(REPLACE "elapsed_time=0.2502" "elapsed_time=0.250200000002" control_summary_outside "${two_stream}")
expect_result("control summary outside tolerance" "${one_stream}" "${control_summary_outside}" "PHYSICAL_MISMATCH" "decision=2 field=elapsed_time")

string(REPLACE "displacement_x=0.021" "displacement_x=0.0210000001" physical_summary_inside "${two_stream}")
expect_result("physical summary inside tolerance" "${one_stream}" "${physical_summary_inside}" "PASS" "all fields match")
string(REPLACE "displacement_x=0.021" "displacement_x=0.0210000004" physical_summary_outside "${two_stream}")
expect_result("physical summary outside tolerance" "${one_stream}" "${physical_summary_outside}" "PHYSICAL_MISMATCH" "decision=2 field=displacement_x")

string(REPLACE "reward_total=-0.337878" "reward_total=-0.337878001" reward_summary_inside "${two_stream}")
expect_result("reward summary inside tolerance" "${one_stream}" "${reward_summary_inside}" "PASS" "all fields match")
string(REPLACE "reward_total=-0.337878" "reward_total=-0.337878005" reward_summary_outside "${two_stream}")
expect_result("reward summary outside tolerance" "${one_stream}" "${reward_summary_outside}" "REWARD_MISMATCH" "decision=2 field=reward_total")

string(REPLACE "end_com_x=0.01" "end_com_x=0.02" physical_stream "${two_stream}")
expect_result("physical difference" "${one_stream}" "${physical_stream}" "PHYSICAL_MISMATCH" "decision=1 field=end_com_x")

string(REPLACE "reward_total=-0.127648" "reward_total=-0.227648" reward_stream "${two_stream}")
expect_result("reward difference" "${one_stream}" "${reward_stream}" "REWARD_MISMATCH" "decision=1 field=reward_total")

string(REPLACE "lagrangian_points=2932" "lagrangian_points=76" wrong_points_stream "${two_stream}")
expect_result("wrong point count" "${one_stream}" "${wrong_points_stream}" "MALFORMED" "lagrangian_points")

string(REPLACE "end_com_x=0.01" "end_com_x=nan" nan_stream "${two_stream}")
expect_result("nondecimal value" "${one_stream}" "${nan_stream}" "MALFORMED" "end_com_x")

string(REGEX REPLACE "EEL_FIXED_ACTION_STEP decision=2[^\n]*\n" "" missing_step_stream "${two_stream}")
expect_result("missing step" "${one_stream}" "${missing_step_stream}" "MALFORMED" "step count")

string(REGEX MATCH "EEL_FIXED_ACTION_STEP decision=1[^\n]*" duplicate_step "${two_stream}")
string(REPLACE "EEL_FIXED_ACTION_STEP decision=2" "${duplicate_step}\nEEL_FIXED_ACTION_STEP decision=2" duplicate_record_stream "${two_stream}")
expect_result("duplicate decision" "${one_stream}" "${duplicate_record_stream}" "MALFORMED" "duplicate.*decision")

string(REPLACE "action=1 target_ratio" "action=1 action=1 target_ratio" duplicate_field_stream "${two_stream}")
expect_result("duplicate field" "${one_stream}" "${duplicate_field_stream}" "MALFORMED" "action.*exactly once")

string(REPLACE "phase_end=0.785628 " "" missing_field_stream "${two_stream}")
expect_result("missing field" "${one_stream}" "${missing_field_stream}" "MALFORMED" "phase_end.*exactly once")

string(REPLACE "end_com_x=0.01" "end_com_x=0.01junk" trailing_value_stream "${two_stream}")
expect_result("trailing value text" "${one_stream}" "${trailing_value_stream}" "MALFORMED" "end_com_x.*nondecimal")
