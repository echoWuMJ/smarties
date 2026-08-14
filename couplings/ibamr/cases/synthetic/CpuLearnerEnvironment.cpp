#include "CpuLearnerEnvironment.h"

#include <algorithm>
#include <stdexcept>

namespace ibamr_smarties
{
namespace synthetic
{

namespace
{
constexpr std::uint64_t mix_a = UINT64_C(0x9E3779B97F4A7C15);
constexpr std::uint64_t mix_b = UINT64_C(0xBF58476D1CE4E5B9);
constexpr std::uint64_t mix_c = UINT64_C(0x94D049BB133111EB);
constexpr std::uint64_t mix_d = UINT64_C(0xD6E8FEB86659FD93);
constexpr double two_to_53 = 9007199254740992.0;
} // namespace

CpuLearnerEnvironment::CpuLearnerEnvironment(const std::uint64_t seed,
                                             const std::uint64_t environment_id)
  : seed_(seed), environment_id_(environment_id)
{
}

std::uint64_t CpuLearnerEnvironment::splitMix64(std::uint64_t value)
{
  value += mix_a;
  value = (value ^ (value >> 30U)) * mix_b;
  value = (value ^ (value >> 27U)) * mix_c;
  return value ^ (value >> 31U);
}

double CpuLearnerEnvironment::stateValue(const std::uint64_t episode,
                                         const unsigned decision,
                                         const std::size_t component) const
{
  std::uint64_t key = seed_;
  key ^= mix_a * (environment_id_ + 1U);
  key ^= mix_b * (episode + 1U);
  key ^= mix_c * (static_cast<std::uint64_t>(decision) + 1U);
  key ^= mix_d * (static_cast<std::uint64_t>(component) + 1U);
  const std::uint64_t high_53_bits = splitMix64(key) >> 11U;
  const double unit = static_cast<double>(high_53_bits) / two_to_53;
  return 2.0 * unit - 1.0;
}

CpuLearnerEnvironment::State CpuLearnerEnvironment::generateState(
  const std::uint64_t episode, const unsigned decision) const
{
  State generated;
  for(std::size_t component=0; component<generated.size(); ++component)
    generated[component] = stateValue(episode, decision, component);
  return generated;
}

void CpuLearnerEnvironment::reset()
{
  episode_ = next_episode_++;
  decision_ = 0;
  state_ = generateState(episode_, decision_);
  active_ = true;
}

double CpuLearnerEnvironment::targetAction(const State& state)
{
  const double linear = 0.60 * state[0] - 0.25 * state[1] +
                        0.15 * state[2];
  return std::max(-0.80, std::min(0.80, linear));
}

CpuLearnerEnvironment::Transition CpuLearnerEnvironment::advance(
  const double action)
{
  if(!active_ || decision_ >= episode_length)
    throw std::logic_error("synthetic environment must be reset before advance");

  const double target = targetAction(state_);
  const double error = action - target;
  ++decision_;
  state_ = generateState(episode_, decision_);

  Transition transition;
  transition.state = state_;
  transition.target_action = target;
  transition.reward = -error * error;
  transition.terminal = decision_ == episode_length;
  transition.episode = episode_;
  transition.decision = decision_;
  if(transition.terminal) active_ = false;
  return transition;
}

} // namespace synthetic
} // namespace ibamr_smarties
