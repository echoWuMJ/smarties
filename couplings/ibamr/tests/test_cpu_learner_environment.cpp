#include "CpuLearnerEnvironment.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace
{
using Environment = ibamr_smarties::synthetic::CpuLearnerEnvironment;
using State = Environment::State;

bool exactState(const State& actual, const State& expected)
{
  for (std::size_t i=0; i<actual.size(); ++i)
    if (actual[i] != expected[i]) return false;
  return true;
}
} // namespace

int main()
{
  struct ExactCase
  {
    std::uint64_t seed;
    State expected;
  };
  const std::array<ExactCase, 3> exact_cases {{
    { 11, {{ 0.82566917093464842, -0.31664722515748056,
             0.85025606013930277, 0.014067420517401175,
            -0.19623872862921887 }} },
    { 29, {{-0.073570121021675927, 0.40961220727348224,
             0.16887115572395150, 0.42284036192565710,
             0.11143849426178942 }} },
    { 47, {{-0.36019417009735633, 0.46382522092987388,
            -0.72603824769846126, -0.91392700220124801,
             0.28522324717136471 }} }
  }};

  for (const ExactCase& test : exact_cases)
  {
    Environment environment(test.seed, 0);
    environment.reset();
    if (!exactState(environment.state(), test.expected)) return 1;
  }

  Environment bounded(11, 3);
  for (unsigned episode=0; episode<8; ++episode)
  {
    bounded.reset();
    for (unsigned decision=0; decision<Environment::episode_length; ++decision)
    {
      for (const double value : bounded.state())
        if (!std::isfinite(value) || value < -1.0 || value > 1.0) return 2;
      const double target = Environment::targetAction(bounded.state());
      const auto transition = bounded.advance(target);
      if (transition.reward != 0.0) return 3;
    }
  }

  const State clipped_high {{ 1.0, -1.0, 0.5, 0.0, 0.0 }};
  const State clipped_low  {{-1.0,  1.0,-0.5, 0.0, 0.0 }};
  const State linear       {{ 0.5,  0.4,-0.2, 0.0, 0.0 }};
  if (Environment::targetAction(clipped_high) != 0.8) return 4;
  if (Environment::targetAction(clipped_low) != -0.8) return 5;
  if (std::abs(Environment::targetAction(linear) - 0.17) > 1e-15) return 6;

  Environment reward_test(29, 2);
  reward_test.reset();
  const double target = Environment::targetAction(reward_test.state());
  const auto rewarded = reward_test.advance(target + 0.25);
  if (rewarded.target_action != target || rewarded.reward != -0.0625) return 7;

  Environment terminal_test(47, 1);
  terminal_test.reset();
  for (unsigned decision=1; decision<=Environment::episode_length; ++decision)
  {
    const auto transition = terminal_test.advance(
      Environment::targetAction(terminal_test.state()));
    if (transition.decision != decision) return 8;
    if (transition.terminal != (decision == Environment::episode_length))
      return 9;
  }

  Environment reset_test(11, 0);
  reset_test.reset();
  const State first_episode = reset_test.state();
  reset_test.reset();
  const State second_expected {{
    -0.14533215388837961, -0.36806280132334979,
    -0.46617744702922415, -0.42864640696043455,
     0.75777811855834365
  }};
  if (reset_test.episode() != 1 || reset_test.decision() != 0) return 10;
  if (exactState(first_episode, reset_test.state())) return 11;
  if (!exactState(reset_test.state(), second_expected)) return 12;

  return 0;
}
