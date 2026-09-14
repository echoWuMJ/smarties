#include "EelNearWallTask.h"
#include <cmath>
#include <stdexcept>

namespace ibamr_smarties { namespace eel2d {

void NearWallConfig::validate() const
{
  const double values[] = {length, density, period, wall_y, maximum_height,
    initial_height_min, initial_height_max, target_distance, maximum_periods,
    failure_penalty};
  for (double value : values)
    if (!std::isfinite(value)) throw std::invalid_argument("non-finite near-wall configuration");
  if (length <= 0 || density <= 0 || period <= 0 || maximum_height <= 0 ||
      initial_height_min <= 0 || initial_height_max < initial_height_min ||
      initial_height_max >= maximum_height || target_distance <= 0 ||
      maximum_periods <= 0 || decisions_per_period == 0 || failure_penalty > 0)
    throw std::invalid_argument("invalid near-wall configuration bounds");
}

const char* nearWallEndName(NearWallEnd end)
{
  switch (end) {
    case NearWallEnd::running: return "running";
    case NearWallEnd::collision: return "collision";
    case NearWallEnd::escaped: return "wall_distance";
    case NearWallEnd::goal: return "goal";
    case NearWallEnd::time_limit: return "time_limit";
    case NearWallEnd::domain_limit: return "domain_limit";
  }
  throw std::invalid_argument("invalid near-wall ending");
}

bool nearWallIsTerminal(NearWallEnd end)
{
  return end == NearWallEnd::collision || end == NearWallEnd::escaped ||
         end == NearWallEnd::goal;
}

NearWallEnd nearWallEnd(const NearWallObservation& o, const NearWallConfig& c)
{
  if (!std::isfinite(o.minimum_gap) || !std::isfinite(o.height) ||
      !std::isfinite(o.time) || !std::isfinite(o.progress))
    throw std::invalid_argument("non-finite near-wall terminal observation");
  if (o.minimum_gap <= 0) return NearWallEnd::collision;
  if (o.height >= c.maximum_height * c.length) return NearWallEnd::escaped;
  if (o.outside_safe_domain) return NearWallEnd::domain_limit;
  if (o.progress >= c.target_distance * c.length) return NearWallEnd::goal;
  if (o.time >= c.maximum_periods * c.period) return NearWallEnd::time_limit;
  return NearWallEnd::running;
}

NearWallState makeNearWallState(const NearWallObservation& o, const NearWallConfig& c)
{
  const double uref = c.referenceSpeed();
  NearWallState s{};
  s[0] = o.height / c.length;
  s[1] = o.minimum_gap / c.length;
  s[2] = -o.velocity[0] / uref;
  s[3] = o.velocity[1] / uref;
  // Forward heading is the negative body axis; relative to global -x its
  // signed angle is the body angle. Do not add pi a second time.
  s[4] = std::sin(o.body_angle);
  s[5] = std::cos(o.body_angle);
  s[6] = o.angular_velocity * c.period;
  s[7] = std::sin(o.phase);
  s[8] = std::cos(o.phase);
  s[9] = o.frequency_ratio;
  s[10] = o.previous_frequency_ratio;
  for (std::size_t p = 0; p < EEL_PROBE_COUNT; ++p) {
    s[11 + 2*p] = -(o.fluid_velocity[p][0] - o.velocity[0]) / uref;
    s[12 + 2*p] = (o.fluid_velocity[p][1] - o.velocity[1]) / uref;
  }
  s[23] = (c.target_distance * c.length - o.progress) / c.length;
  s[24] = 1.0 - o.time / (c.maximum_periods * c.period);
  for (double value : s)
    if (!std::isfinite(value)) throw std::invalid_argument("non-finite near-wall state");
  return s;
}

double nearWallForceCoefficient(double fx, const NearWallConfig& c)
{
  if (!std::isfinite(fx)) throw std::invalid_argument("non-finite Fx");
  return -fx / (0.5 * c.density * c.referenceSpeed() * c.referenceSpeed() * c.length);
}

double nearWallReward(double impulse_x, NearWallEnd end, const NearWallConfig& c)
{
  const double force_reward = nearWallForceCoefficient(impulse_x, c) / c.controlInterval();
  return force_reward + ((end == NearWallEnd::collision || end == NearWallEnd::escaped)
                         ? c.failure_penalty : 0.0);
}

} }
