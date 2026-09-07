#include "EelVelocityProbes.h"

#include <cmath>
#include <limits>

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
  using namespace ibamr_smarties::eel2d;
  const double half_pi = 1.57079632679489661923;

  // Catches probes that do not retain the three station/two side body layout.
  const EelProbePoints horizontal =
    makeEelProbePoints({{ 2.0, 3.0 }}, 0.0);
  const EelProbePoints expected_horizontal = {{
    {{ 1.65, 3.10 }}, {{ 1.65, 2.90 }},
    {{ 2.00, 3.10 }}, {{ 2.00, 2.90 }},
    {{ 2.35, 3.10 }}, {{ 2.35, 2.90 }}
  }};
  for (std::size_t i = 0; i < EEL_PROBE_COUNT; ++i)
    for (std::size_t d = 0; d < 2; ++d)
      if (!near(horizontal[i][d], expected_horizontal[i][d])) return 1;

  // Catches use of global fixed offsets instead of a body-following rotation.
  const EelProbePoints vertical =
    makeEelProbePoints({{ 2.0, 3.0 }}, half_pi);
  const EelProbePoints expected_vertical = {{
    {{ 1.90, 2.65 }}, {{ 2.10, 2.65 }},
    {{ 1.90, 3.00 }}, {{ 2.10, 3.00 }},
    {{ 1.90, 3.35 }}, {{ 2.10, 3.35 }}
  }};
  for (std::size_t i = 0; i < EEL_PROBE_COUNT; ++i)
    for (std::size_t d = 0; d < 2; ++d)
      if (!near(vertical[i][d], expected_vertical[i][d])) return 2;

  const double nan = std::numeric_limits<double>::quiet_NaN();
  if (!throws<std::invalid_argument>([&] {
        makeEelProbePoints({{ nan, 0.0 }}, 0.0);
      })) return 3;
  if (!throws<std::invalid_argument>([&] {
        makeEelProbePoints({{ 0.0, 0.0 }}, nan);
      })) return 4;

  return 0;
}
