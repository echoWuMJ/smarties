#include "TailBeatPhase.h"

#include <cmath>

namespace
{
bool near(const double actual, const double expected, const double tolerance = 1.0e-14)
{
  return std::abs(actual - expected) <= tolerance;
}
} // namespace

int main()
{
  using ibamr_smarties::eel2d::TailBeatPhase;

  const double pi = 3.1415926535897932384626433832795;
  const double sample_positions[] = { 0.0, 0.25, 0.75, 1.0 };
  const double sample_times[] = { 0.0, 0.125, 0.5, 1.25 };
  TailBeatPhase phase(6.28, 0.0);

  for (const double position : sample_positions)
  {
    for (const double time : sample_times)
    {
      const double body_fraction = (position + 0.03125) / 1.03125;
      const double envelope = 0.125 * body_fraction;
      const double official_argument = 2.0 * pi * position - 6.28 * time;

      const double official_shape = envelope * std::sin(official_argument);
      const double controlled_shape =
        envelope * std::sin(2.0 * pi * position - phase.valueAt(time));
      if (!near(controlled_shape, official_shape)) return 1;

      const double official_normal_speed =
        -0.785 * body_fraction * std::cos(official_argument);
      const double controlled_normal_speed =
        -envelope * phase.angularFrequency() *
        std::cos(2.0 * pi * position - phase.valueAt(time));
      if (!near(controlled_normal_speed, official_normal_speed)) return 2;
    }
  }

  return 0;
}
