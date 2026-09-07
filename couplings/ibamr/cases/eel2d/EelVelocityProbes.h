#ifndef IBAMR_SMARTIES_EEL_VELOCITY_PROBES_H
#define IBAMR_SMARTIES_EEL_VELOCITY_PROBES_H

#include <array>
#include <cstddef>

namespace ibamr_smarties
{
namespace eel2d
{

constexpr std::size_t EEL_PROBE_COUNT = 6;
constexpr std::size_t EEL_PROBE_COMPONENT_COUNT = 2;
constexpr std::size_t EEL_CONTROL_STATE_DIMENSION =
  5 + EEL_PROBE_COUNT * EEL_PROBE_COMPONENT_COUNT;

using EelPoint = std::array<double, 2>;
using EelProbePoints = std::array<EelPoint, EEL_PROBE_COUNT>;
using EelProbeVelocities = std::array<EelPoint, EEL_PROBE_COUNT>;
using EelState = std::array<double, EEL_CONTROL_STATE_DIMENSION>;

struct EelVelocityProbeSample
{
  EelProbePoints positions;
  EelProbeVelocities velocities;
};

EelProbePoints makeEelProbePoints(const EelPoint& center_of_mass,
                                  double body_axis_angle);

} // namespace eel2d
} // namespace ibamr_smarties

#endif
