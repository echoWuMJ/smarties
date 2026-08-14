#ifndef IBAMR_SMARTIES_CPU_LEARNER_ENVIRONMENT_H
#define IBAMR_SMARTIES_CPU_LEARNER_ENVIRONMENT_H

#include <array>
#include <cstddef>
#include <cstdint>

namespace ibamr_smarties
{
namespace synthetic
{

class CpuLearnerEnvironment
{
public:
  static constexpr std::size_t state_dimension = 5;
  static constexpr unsigned episode_length = 32;
  using State = std::array<double, state_dimension>;

  struct Transition
  {
    State state;
    double target_action = 0.0;
    double reward = 0.0;
    bool terminal = false;
    std::uint64_t episode = 0;
    unsigned decision = 0;
  };

  CpuLearnerEnvironment(std::uint64_t seed, std::uint64_t environment_id);

  void reset();
  Transition advance(double action);

  const State& state() const { return state_; }
  std::uint64_t episode() const { return episode_; }
  unsigned decision() const { return decision_; }

  static double targetAction(const State& state);

private:
  static std::uint64_t splitMix64(std::uint64_t value);
  double stateValue(std::uint64_t episode,
                    unsigned decision,
                    std::size_t component) const;
  State generateState(std::uint64_t episode, unsigned decision) const;

  const std::uint64_t seed_;
  const std::uint64_t environment_id_;
  std::uint64_t next_episode_ = 0;
  std::uint64_t episode_ = 0;
  unsigned decision_ = 0;
  bool active_ = false;
  State state_ {{ 0.0, 0.0, 0.0, 0.0, 0.0 }};
};

} // namespace synthetic
} // namespace ibamr_smarties

#endif
