#ifndef IBAMR_SMARTIES_EEL_CONTROL_TASK_H
#define IBAMR_SMARTIES_EEL_CONTROL_TASK_H

#include <array>
#include <iosfwd>
#include <string>

namespace ibamr_smarties
{
namespace eel2d
{

struct EelTaskConfig
{
  double baseline_angular_frequency;
  double minimum_frequency_ratio;
  double maximum_frequency_ratio;
  double maximum_ratio_delta;
  unsigned decisions_per_baseline_period;
  double target_forward_speed;
  double forward_direction_x;
  double forward_direction_y;
  double velocity_scale;
  double tracking_weight;
  double frequency_weight;
  double smoothness_weight;
  double warmup_cycles;
  unsigned episode_decisions;
};

EelTaskConfig parseEelTaskConfig(std::istream& input);
EelTaskConfig loadEelTaskConfig(const std::string& path);

struct ControlDecision
{
  double requested_action;
  double target_ratio;
  double previous_ratio;
  double applied_ratio;
  bool clipped;
};

struct RewardBreakdown
{
  double tracking;
  double frequency;
  double smoothness;
  double total;
};

class EelControlTask
{
public:
  explicit EelControlTask(EelTaskConfig config);

  ControlDecision applyAction(double action);
  std::array<double, 5> makeState(double forward_velocity, double phase) const;
  RewardBreakdown reward(double forward_velocity, double previous_ratio) const;
  double controlInterval() const;
  unsigned clippedActionCount() const;

private:
  EelTaskConfig config_;
  double applied_ratio_ = 1.0;
  unsigned clipped_action_count_ = 0;
};

} // namespace eel2d
} // namespace ibamr_smarties

#endif
