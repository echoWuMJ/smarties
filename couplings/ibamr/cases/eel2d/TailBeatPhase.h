#ifndef IBAMR_SMARTIES_TAIL_BEAT_PHASE_H
#define IBAMR_SMARTIES_TAIL_BEAT_PHASE_H

#include <array>

namespace ibamr_smarties
{
namespace eel2d
{

class TailBeatPhase
{
public:
  TailBeatPhase(double baseline_angular_frequency, double initial_time);

  void setFrequencyRatio(double ratio, double effective_time);

  double valueAt(double time) const;
  double angularFrequency() const;
  double frequencyRatio() const;
  double baselineAngularFrequency() const;

  // Stable restart fields: baseline omega, anchor time, anchor phase, ratio.
  std::array<double, 4> saveState() const;
  void restoreState(const std::array<double, 4>& state);

private:
  double omega0_;
  double anchor_time_;
  double anchor_phase_;
  double ratio_;
};

} // namespace eel2d
} // namespace ibamr_smarties

#endif
