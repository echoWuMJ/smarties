#include "EelControlMeasurement.h"

#include <cmath>
#include <stdexcept>

using namespace ibamr_smarties::eel2d;

int main()
{
  EelTaskConfig config{};
  config.forward_direction_x = 0.6;
  config.forward_direction_y = 0.8;
  ControlIntervalResult interval{ 1.0, 1.5, {{2.0, 3.0}}, {{2.3, 3.4}}, 5 };
  if (std::abs(forwardVelocity(interval, config) - 1.0) > 1.0e-14) return 1;
  interval.end_time = interval.start_time;
  try { forwardVelocity(interval, config); }
  catch (const std::runtime_error&) { return 0; }
  return 2;
}
