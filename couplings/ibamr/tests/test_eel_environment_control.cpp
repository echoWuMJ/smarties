#include "EelEnvironment.h"
#include "MpiSession.h"

#include <mpi.h>

#include <array>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace
{
bool near(const double actual, const double expected, const double tolerance = 1.0e-11)
{
  return std::abs(actual - expected) <= tolerance;
}

bool finitePoint(const std::array<double, 2>& point)
{
  return std::isfinite(point[0]) && std::isfinite(point[1]);
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

int main(int argc, char** argv)
{
  using ibamr_smarties::eel2d::ControlIntervalResult;
  using ibamr_smarties::eel2d::EelEnvironment;
  if (argc != 2) return 64;

  ibamr_smarties::MpiSession mpi(argc, argv);
  EelEnvironment environment;
  if (!throws<std::logic_error>([&] { environment.currentTime(); })) return 16;
  if (!throws<std::logic_error>([&] { environment.globalLagrangianPointCount(); })) return 17;
  environment.initialize(mpi.world(), argv[1]);
  if (environment.globalLagrangianPointCount() != 2932) return 7;

  const double nan = std::numeric_limits<double>::quiet_NaN();
  if (!throws<std::invalid_argument>([&] { environment.setTailBeatFrequencyRatio(0.0); })) return 17;
  if (!throws<std::invalid_argument>([&] { environment.advanceControlInterval(0.0); })) return 18;
  if (!throws<std::invalid_argument>([&] { environment.advanceControlInterval(nan); })) return 19;

  const double initial_time = environment.currentTime();
  const std::array<double, 2> initial_com = environment.currentCenterOfMass();
  const double initial_phase = environment.currentTailBeatPhase();
  if (!std::isfinite(initial_time) || !finitePoint(initial_com) ||
      !std::isfinite(initial_phase)) return 1;
  if (!near(environment.currentTailBeatFrequencyRatio(), 1.0)) return 2;

  // Catches phase discontinuity at a command-safe point.
  environment.setTailBeatFrequencyRatio(1.0);
  if (!near(environment.currentTailBeatPhase(), initial_phase)) return 3;
  environment.setTailBeatFrequencyRatio(0.9);
  if (!near(environment.currentTailBeatPhase(), initial_phase)) return 4;
  if (!near(environment.currentTailBeatFrequencyRatio(), 0.9)) return 5;

  // Catches an adapter-owned or assumed-dt loop instead of a real IBAMR advance.
  const ControlIntervalResult result = environment.advanceControlInterval(1.0e-6);
  if (result.ibamr_steps == 0) return 6;
  if (!near(result.start_time, initial_time)) return 7;
  if (!(result.end_time > result.start_time)) return 8;
  if (result.end_time - result.start_time < 1.0e-6) return 9;
  if (!finitePoint(result.start_com) || !finitePoint(result.end_com)) return 10;
  if (!near(result.start_com[0], initial_com[0]) ||
      !near(result.start_com[1], initial_com[1])) return 11;
  if (!near(environment.currentTime(), result.end_time)) return 12;
  const std::array<double, 2> final_com = environment.currentCenterOfMass();
  if (!near(final_com[0], result.end_com[0]) ||
      !near(final_com[1], result.end_com[1])) return 13;

  // Catches phase advancement based on requested rather than actual elapsed time.
  const double expected_phase =
    initial_phase + 6.28 * 0.9 * (result.end_time - result.start_time);
  if (!near(environment.currentTailBeatPhase(), expected_phase)) return 14;

  environment.shutdown();
  int finalized = 0;
  MPI_Finalized(&finalized);
  if (finalized != 0) return 15;
  return 0;
}
