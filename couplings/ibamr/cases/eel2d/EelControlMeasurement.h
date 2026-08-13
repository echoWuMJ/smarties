#ifndef IBAMR_SMARTIES_EEL_CONTROL_MEASUREMENT_H
#define IBAMR_SMARTIES_EEL_CONTROL_MEASUREMENT_H

#include "EelControlTask.h"

#include <array>

namespace ibamr_smarties
{
namespace eel2d
{

struct ControlIntervalResult
{
  double start_time;
  double end_time;
  std::array<double, 2> start_com;
  std::array<double, 2> end_com;
  unsigned ibamr_steps;
};

double forwardVelocity(const ControlIntervalResult& interval,
                       const EelTaskConfig& config);

} // namespace eel2d
} // namespace ibamr_smarties

#endif
