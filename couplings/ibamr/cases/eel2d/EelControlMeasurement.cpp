#include "EelControlMeasurement.h"

#include <cmath>
#include <stdexcept>

namespace ibamr_smarties
{
namespace eel2d
{

double
forwardVelocity(const ControlIntervalResult& interval,
                const EelTaskConfig& config)
{
  const double elapsed = interval.end_time - interval.start_time;
  if (!std::isfinite(elapsed) || elapsed <= 0.0)
    throw std::runtime_error("non-positive or non-finite eel control interval");
  const double displacement_x = interval.end_com[0] - interval.start_com[0];
  const double displacement_y = interval.end_com[1] - interval.start_com[1];
  const double velocity =
    (displacement_x * config.forward_direction_x +
     displacement_y * config.forward_direction_y) / elapsed;
  if (!std::isfinite(velocity))
    throw std::runtime_error("non-finite eel forward velocity");
  return velocity;
}

} // namespace eel2d
} // namespace ibamr_smarties
