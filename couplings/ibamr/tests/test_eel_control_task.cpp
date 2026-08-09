#include "EelControlTask.h"

#include <cmath>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>

namespace
{
bool near(const double actual, const double expected, const double tolerance = 1.0e-13)
{
  return std::abs(actual - expected) <= tolerance;
}

template <class Exception, class Function>
bool throws(Function function)
{
  try
  {
    function();
  }
  catch (const Exception&)
  {
    return true;
  }
  catch (...)
  {
  }
  return false;
}

std::string validConfig()
{
  return
    "baseline_angular_frequency=6.28\n"
    "minimum_frequency_ratio=0.5\n"
    "maximum_frequency_ratio=1.5\n"
    "maximum_ratio_delta=0.1\n"
    "decisions_per_baseline_period=8\n"
    "target_forward_speed=0.2\n"
    "forward_direction_x=1.0\n"
    "forward_direction_y=0.0\n"
    "velocity_scale=0.5\n"
    "tracking_weight=2.0\n"
    "frequency_weight=3.0\n"
    "smoothness_weight=4.0\n"
    "warmup_cycles=1.0\n"
    "episode_decisions=16\n";
}

std::string replaceOnce(std::string text, const std::string& from, const std::string& to)
{
  const std::size_t position = text.find(from);
  if (position == std::string::npos) throw std::logic_error("test fixture replacement failed");
  text.replace(position, from.size(), to);
  return text;
}

bool rejectedConfig(const std::string& text)
{
  return throws<std::invalid_argument>([&] {
    std::istringstream input(text);
    ibamr_smarties::eel2d::parseEelTaskConfig(input);
  });
}
} // namespace

int main(int argc, char** argv)
{
  using namespace ibamr_smarties::eel2d;
  if (argc != 2) return 64;

  // Catches a parser that ignores the real task file or its comments.
  const EelTaskConfig loaded = loadEelTaskConfig(argv[1]);
  if (!near(loaded.baseline_angular_frequency, 6.28)) return 1;
  if (!near(loaded.target_forward_speed, 0.2)) return 2;
  if (loaded.episode_decisions != 16) return 3;
  if (!throws<std::runtime_error>([&] {
        loadEelTaskConfig("__missing_eel_task_config__");
      })) return 40;

  // Catches silent acceptance of ambiguous or incomplete run identities.
  if (!rejectedConfig(validConfig() + "unknown_key=1\n")) return 4;
  if (!rejectedConfig(validConfig() + "velocity_scale=1\n")) return 5;
  if (!rejectedConfig(replaceOnce(validConfig(), "episode_decisions=16\n", ""))) return 6;
  if (!rejectedConfig(replaceOnce(validConfig(), "episode_decisions=16", "episode_decisions=16x"))) return 7;

  // Catches numerically unsafe task definitions.
  if (!rejectedConfig(replaceOnce(validConfig(), "baseline_angular_frequency=6.28",
                                  "baseline_angular_frequency=6.29"))) return 8;
  if (!rejectedConfig(replaceOnce(validConfig(), "velocity_scale=0.5", "velocity_scale=nan"))) return 9;
  if (!rejectedConfig(replaceOnce(validConfig(), "velocity_scale=0.5", "velocity_scale=0"))) return 10;
  if (!rejectedConfig(replaceOnce(validConfig(), "minimum_frequency_ratio=0.5",
                                  "minimum_frequency_ratio=1.6"))) return 11;
  if (!rejectedConfig(replaceOnce(validConfig(), "maximum_ratio_delta=0.1",
                                  "maximum_ratio_delta=0"))) return 12;
  if (!rejectedConfig(replaceOnce(validConfig(), "forward_direction_x=1.0",
                                  "forward_direction_x=0.0"))) return 13;
  if (!rejectedConfig(replaceOnce(validConfig(), "tracking_weight=2.0",
                                  "tracking_weight=-1.0"))) return 14;
  if (!rejectedConfig(replaceOnce(validConfig(), "forward_direction_x=1.0",
                                  "forward_direction_x=0.5"))) return 39;

  // Catches wrong action scaling, clipping, and slew limiting.
  EelControlTask lower_task(loaded);
  const ControlDecision lower = lower_task.applyAction(-1.0);
  if (!near(lower.target_ratio, 0.5) || !near(lower.applied_ratio, 0.9)) return 15;
  if (lower.clipped) return 16;

  EelControlTask center_task(loaded);
  const ControlDecision center = center_task.applyAction(0.0);
  if (!near(center.target_ratio, 1.0) || !near(center.applied_ratio, 1.0)) return 17;

  EelControlTask upper_task(loaded);
  const ControlDecision upper = upper_task.applyAction(1.0);
  if (!near(upper.target_ratio, 1.5) || !near(upper.applied_ratio, 1.1)) return 18;
  if (!near(upper.previous_ratio, 1.0)) return 19;

  EelControlTask clipped_task(loaded);
  const ControlDecision clipped = clipped_task.applyAction(2.0);
  if (!clipped.clipped || clipped_task.clippedActionCount() != 1) return 20;
  if (!near(clipped.target_ratio, 1.5) || !near(clipped.applied_ratio, 1.1)) return 21;

  const double nan = std::numeric_limits<double>::quiet_NaN();
  const double inf = std::numeric_limits<double>::infinity();
  if (!throws<std::invalid_argument>([&] { clipped_task.applyAction(nan); })) return 22;
  if (!throws<std::invalid_argument>([&] { clipped_task.applyAction(inf); })) return 23;

  // Catches use of exact one-second periods instead of the official 6.28 wave.
  if (!near(center_task.controlInterval(), 0.12506340181488029)) return 24;

  // Catches state reordering or wrapped phase representation.
  const double half_pi = 1.57079632679489661923;
  const std::array<double, 5> state = upper_task.makeState(0.25, half_pi);
  if (!near(state[0], 0.5)) return 25;
  if (!near(state[1], 0.4)) return 26;
  if (!near(state[2], 1.1)) return 27;
  if (!near(state[3], 1.0)) return 28;
  if (!near(state[4], 0.0)) return 29;

  // Catches reward sign, normalization, term separation, or wrong previous ratio.
  const RewardBreakdown reward = upper_task.reward(0.25, upper.previous_ratio);
  if (!near(reward.tracking, -0.02)) return 30;
  if (!near(reward.frequency, -0.03)) return 31;
  if (!near(reward.smoothness, -0.04)) return 32;
  if (!near(reward.total, -0.09)) return 33;

  EelControlTask perfect_task(loaded);
  const RewardBreakdown perfect = perfect_task.reward(0.2, 1.0);
  if (!near(perfect.total, 0.0)) return 34;
  if (!throws<std::invalid_argument>([&] { perfect_task.makeState(nan, 0.0); })) return 35;
  if (!throws<std::invalid_argument>([&] { perfect_task.makeState(0.0, inf); })) return 36;
  if (!throws<std::invalid_argument>([&] { perfect_task.reward(nan, 1.0); })) return 37;
  if (!throws<std::invalid_argument>([&] { perfect_task.reward(0.0, inf); })) return 38;

  return 0;
}
