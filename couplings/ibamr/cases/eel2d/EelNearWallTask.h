#ifndef IBAMR_SMARTIES_EEL_NEAR_WALL_TASK_H
#define IBAMR_SMARTIES_EEL_NEAR_WALL_TASK_H

#include "EelVelocityProbes.h"
#include <array>
#include <string>

namespace ibamr_smarties { namespace eel2d {

// Two-dimensional forces are per unit span. The wall is horizontal;
// the official eel swims in the negative global x direction.
struct NearWallConfig
{
  double length = 1.0;
  double density = 1.0;
  double period = 6.2831853071795864769 / 6.28;
  double wall_y = -1.52;
  double maximum_height = 0.7;
  double initial_height_min = 0.25;
  double initial_height_max = 0.60;
  double target_distance = 4.0;
  double maximum_periods = 10.0;
  double failure_penalty = -1.0;
  unsigned decisions_per_period = 8;
  void validate() const;
  double referenceSpeed() const { return length / period; }
  double controlInterval() const { return period / decisions_per_period; }
};

enum class NearWallEnd { running, collision, escaped, goal, time_limit, domain_limit };
const char* nearWallEndName(NearWallEnd end);
bool nearWallIsTerminal(NearWallEnd end);

struct NearWallObservation
{
  double time = 0.0;
  double height = 0.0;
  double minimum_gap = 0.0;
  EelPoint velocity{{0.0, 0.0}};
  // Angle of the positive body x axis in global coordinates.
  double body_angle = 0.0;
  double angular_velocity = 0.0;
  double phase = 0.0;
  double frequency_ratio = 1.0;
  double previous_frequency_ratio = 1.0;
  EelProbeVelocities fluid_velocity{};
  double progress = 0.0;
  bool outside_safe_domain = false;
};

using NearWallState = std::array<double, 25>;
NearWallState makeNearWallState(const NearWallObservation& observation,
                               const NearWallConfig& config);
NearWallEnd nearWallEnd(const NearWallObservation& observation,
                       const NearWallConfig& config);
double nearWallForceCoefficient(double global_fx, const NearWallConfig& config);
double nearWallReward(double force_impulse_x, NearWallEnd end,
                      const NearWallConfig& config);

} }
#endif
