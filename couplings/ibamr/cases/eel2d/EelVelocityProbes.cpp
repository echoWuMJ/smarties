#include "EelVelocityProbes.h"

#include <cmath>
#include <stdexcept>

namespace ibamr_smarties
{
namespace eel2d
{

EelProbePoints
makeEelProbePoints(const EelPoint& center_of_mass,
                   const double body_axis_angle)
{
  if (!std::isfinite(center_of_mass[0]) ||
      !std::isfinite(center_of_mass[1]) ||
      !std::isfinite(body_axis_angle))
    throw std::invalid_argument("eel probe pose must be finite");

  constexpr std::array<double, 3> longitudinal_offsets =
    {{ -0.35, 0.0, 0.35 }};
  constexpr double normal_offset = 0.10;
  constexpr std::array<double, 2> normal_offsets =
    {{ normal_offset, -normal_offset }};
  const double cosine = std::cos(body_axis_angle);
  const double sine = std::sin(body_axis_angle);

  EelProbePoints points;
  std::size_t probe = 0;
  for (const double longitudinal : longitudinal_offsets)
  {
    for (const double normal : normal_offsets)
    {
      points[probe][0] = center_of_mass[0] +
        longitudinal * cosine - normal * sine;
      points[probe][1] = center_of_mass[1] +
        longitudinal * sine + normal * cosine;
      ++probe;
    }
  }
  return points;
}

} // namespace eel2d
} // namespace ibamr_smarties
