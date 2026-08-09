#include "TailBeatPhase.h"

#include <cmath>
#include <stdexcept>

namespace ibamr_smarties
{
namespace eel2d
{

TailBeatPhase::TailBeatPhase(const double baseline_angular_frequency,
                             const double initial_time)
  : omega0_(baseline_angular_frequency),
    anchor_time_(initial_time),
    anchor_phase_(0.0),
    ratio_(1.0)
{
  if (!std::isfinite(omega0_) || omega0_ <= 0.0)
    throw std::invalid_argument("baseline angular frequency must be finite and positive");
  if (!std::isfinite(anchor_time_) || anchor_time_ < 0.0)
    throw std::invalid_argument("initial time must be finite and nonnegative");
  anchor_phase_ = omega0_ * anchor_time_;
}

void
TailBeatPhase::setFrequencyRatio(const double ratio, const double effective_time)
{
  if (!std::isfinite(ratio) || ratio <= 0.0)
    throw std::invalid_argument("tail-beat frequency ratio must be finite and positive");
  if (!std::isfinite(effective_time))
    throw std::invalid_argument("frequency command time must be finite");
  if (effective_time < anchor_time_)
    throw std::logic_error("frequency command time precedes the current phase anchor");

  anchor_phase_ = valueAt(effective_time);
  anchor_time_ = effective_time;
  ratio_ = ratio;
}

double
TailBeatPhase::valueAt(const double time) const
{
  if (!std::isfinite(time)) throw std::invalid_argument("phase query time must be finite");
  if (time < anchor_time_)
    throw std::logic_error("phase query time precedes the current phase anchor");
  return anchor_phase_ + angularFrequency() * (time - anchor_time_);
}

double
TailBeatPhase::angularFrequency() const
{
  return omega0_ * ratio_;
}

double
TailBeatPhase::frequencyRatio() const
{
  return ratio_;
}

double
TailBeatPhase::baselineAngularFrequency() const
{
  return omega0_;
}

} // namespace eel2d
} // namespace ibamr_smarties
