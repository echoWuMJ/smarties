#include "TailBeatPhase.h"

#include <cmath>
#include <limits>
#include <stdexcept>

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
} // namespace

int main()
{
  using ibamr_smarties::eel2d::TailBeatPhase;

  // Catches replacement of the official 6.28 angular frequency by exact 2*pi.
  TailBeatPhase baseline(6.28, 0.0);
  if (!near(baseline.valueAt(0.25), 1.57)) return 1;
  if (!near(baseline.angularFrequency(), 6.28)) return 2;
  if (!near(baseline.frequencyRatio(), 1.0)) return 3;
  if (!near(baseline.baselineAngularFrequency(), 6.28)) return 28;

  // Catches mutation of phase by query/callback count.
  const double first_query = baseline.valueAt(0.3);
  if (!near(first_query, 1.884)) return 4;
  if (!near(baseline.valueAt(0.3), first_query)) return 5;

  // Catches a phase jump when a new frequency becomes effective.
  const double switching_time = 0.4;
  const double phase_before_switch = baseline.valueAt(switching_time);
  if (!near(phase_before_switch, 2.512)) return 6;
  baseline.setFrequencyRatio(1.25, switching_time);
  if (!near(baseline.valueAt(switching_time), 2.512)) return 7;
  if (!near(baseline.angularFrequency(), 7.85)) return 8;
  if (!near(baseline.valueAt(0.5), 3.297)) return 9;

  // Catches loss of the accumulated phase at a second command boundary.
  baseline.setFrequencyRatio(0.75, 0.6);
  if (!near(baseline.valueAt(0.6), 4.082)) return 10;
  if (!near(baseline.valueAt(0.8), 5.024)) return 11;

  // Catches a restart/nonzero-start phase that no longer matches omega0*t.
  TailBeatPhase restarted(6.28, 0.25);
  if (!near(restarted.valueAt(0.25), 1.57)) return 12;

  // Catches acceptance of commands that make the kinematics undefined.
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const double inf = std::numeric_limits<double>::infinity();
  if (!throws<std::invalid_argument>([&] { restarted.setFrequencyRatio(0.0, 0.25); })) return 13;
  if (!throws<std::invalid_argument>([&] { restarted.setFrequencyRatio(-0.5, 0.25); })) return 14;
  if (!throws<std::invalid_argument>([&] { restarted.setFrequencyRatio(nan, 0.25); })) return 15;
  if (!throws<std::invalid_argument>([&] { restarted.setFrequencyRatio(inf, 0.25); })) return 16;
  if (!throws<std::invalid_argument>([&] { TailBeatPhase invalid(0.0, 0.0); })) return 17;
  if (!throws<std::invalid_argument>([&] { TailBeatPhase invalid(inf, 0.0); })) return 18;
  if (!throws<std::invalid_argument>([&] { TailBeatPhase invalid(6.28, nan); })) return 19;
  if (!throws<std::invalid_argument>([&] { TailBeatPhase invalid(-6.28, 0.0); })) return 20;
  if (!throws<std::invalid_argument>([&] { TailBeatPhase invalid(6.28, -0.1); })) return 21;
  if (!throws<std::invalid_argument>([&] { restarted.setFrequencyRatio(1.0, nan); })) return 22;
  if (!throws<std::invalid_argument>([&] { restarted.setFrequencyRatio(1.0, inf); })) return 23;
  if (!throws<std::invalid_argument>([&] { restarted.valueAt(nan); })) return 24;
  if (!throws<std::invalid_argument>([&] { restarted.valueAt(inf); })) return 25;

  // Catches silent backwards extrapolation across a command boundary.
  restarted.setFrequencyRatio(1.1, 0.5);
  if (!throws<std::logic_error>([&] { restarted.setFrequencyRatio(1.0, 0.49); })) return 26;
  if (!throws<std::logic_error>([&] { restarted.valueAt(0.49); })) return 27;

  return 0;
}
