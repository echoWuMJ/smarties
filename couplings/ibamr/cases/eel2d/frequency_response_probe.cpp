#include "EelEnvironment.h"
#include "MpiSession.h"

#include <array>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <stdexcept>
#include <string>

namespace
{
struct ProbeOptions
{
  std::string input_file;
  double ratio = 0.0;
  unsigned decisions = 0;
  double direction_x = 0.0;
  double direction_y = 0.0;
  bool has_ratio = false;
  bool has_direction_x = false;
  bool has_direction_y = false;
};

double parseFiniteDouble(const char* text, const char* option)
{
  errno = 0;
  char* end = nullptr;
  const double value = std::strtod(text, &end);
  if (errno != 0 || end == text || *end != '\0' || !std::isfinite(value))
    throw std::invalid_argument(std::string(option) + " requires a finite number");
  return value;
}

unsigned parsePositiveUnsigned(const char* text, const char* option)
{
  if (text == nullptr || *text == '\0' || *text == '-' || *text == '+')
    throw std::invalid_argument(std::string(option) + " requires a positive integer");
  errno = 0;
  char* end = nullptr;
  const unsigned long value = std::strtoul(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value == 0 ||
      value > std::numeric_limits<unsigned>::max())
    throw std::invalid_argument(std::string(option) + " requires a positive integer");
  return static_cast<unsigned>(value);
}

ProbeOptions parseOptions(const int argc, char** const argv)
{
  ProbeOptions options;
  for (int i = 1; i < argc; ++i) {
    const std::string argument(argv[i]);
    if (argument == "--input-file") {
      if (++i >= argc) throw std::invalid_argument("missing value after --input-file");
      options.input_file = argv[i];
    }
    else if (argument == "--ratio") {
      if (++i >= argc) throw std::invalid_argument("missing value after --ratio");
      options.ratio = parseFiniteDouble(argv[i], "--ratio");
      options.has_ratio = true;
    }
    else if (argument == "--decisions") {
      if (++i >= argc) throw std::invalid_argument("missing value after --decisions");
      options.decisions = parsePositiveUnsigned(argv[i], "--decisions");
    }
    else if (argument == "--direction-x") {
      if (++i >= argc) throw std::invalid_argument("missing value after --direction-x");
      options.direction_x = parseFiniteDouble(argv[i], "--direction-x");
      options.has_direction_x = true;
    }
    else if (argument == "--direction-y") {
      if (++i >= argc) throw std::invalid_argument("missing value after --direction-y");
      options.direction_y = parseFiniteDouble(argv[i], "--direction-y");
      options.has_direction_y = true;
    }
    else {
      throw std::invalid_argument("unknown frequency probe option: " + argument);
    }
  }

  if (options.input_file.empty())
    throw std::invalid_argument("--input-file is required");
  if (!options.has_ratio || options.ratio <= 0.0)
    throw std::invalid_argument("--ratio must be finite and positive");
  if (options.decisions == 0)
    throw std::invalid_argument("--decisions is required");
  if (!options.has_direction_x || !options.has_direction_y)
    throw std::invalid_argument("both direction components are required");
  const double direction_norm =
    std::hypot(options.direction_x, options.direction_y);
  if (!std::isfinite(direction_norm) || std::abs(direction_norm - 1.0) > 1.0e-12)
    throw std::invalid_argument("probe direction must be a finite unit vector");
  return options;
}
} // namespace

int main(int argc, char** argv)
{
  try {
    const ProbeOptions options = parseOptions(argc, argv);
    ibamr_smarties::MpiSession mpi(argc, argv);
    ibamr_smarties::eel2d::EelEnvironment environment;
    environment.initialize(mpi.world(), options.input_file);
    environment.setTailBeatFrequencyRatio(options.ratio);

    const double start_time = environment.currentTime();
    const std::array<double, 2> start_com = environment.currentCenterOfMass();
    const double phase_start = environment.currentTailBeatPhase();
    unsigned completed_decisions = 0;
    unsigned ibamr_steps = 0;
    const double control_interval =
      2.0 * 3.1415926535897932384626433832795 / (8.0 * 6.28);
    for (; completed_decisions < options.decisions; ++completed_decisions) {
      if (!environment.stepsRemaining())
        throw std::runtime_error("eel simulation ended during frequency probe");
      const ibamr_smarties::eel2d::ControlIntervalResult interval =
        environment.advanceControlInterval(control_interval);
      ibamr_steps += interval.ibamr_steps;
    }

    const double end_time = environment.currentTime();
    const std::array<double, 2> end_com = environment.currentCenterOfMass();
    const double phase_end = environment.currentTailBeatPhase();
    const double elapsed_time = end_time - start_time;
    const double displacement_x = end_com[0] - start_com[0];
    const double displacement_y = end_com[1] - start_com[1];
    const double forward_displacement =
      displacement_x * options.direction_x +
      displacement_y * options.direction_y;
    const double mean_forward_velocity = forward_displacement / elapsed_time;
    if (!std::isfinite(elapsed_time) || elapsed_time <= 0.0 ||
        !std::isfinite(displacement_x) || !std::isfinite(displacement_y) ||
        !std::isfinite(forward_displacement) ||
        !std::isfinite(mean_forward_velocity) ||
        !std::isfinite(phase_start) || !std::isfinite(phase_end))
      throw std::runtime_error("frequency probe produced non-finite output");

    environment.shutdown();
    std::printf(
      "EEL_FREQUENCY_PROBE ratio=%.17g decisions=%u ibamr_steps=%u "
      "elapsed_time=%.17g displacement_x=%.17g displacement_y=%.17g "
      "forward_displacement=%.17g mean_forward_velocity=%.17g "
      "phase_start=%.17g phase_end=%.17g\n",
      options.ratio, completed_decisions, ibamr_steps, elapsed_time,
      displacement_x, displacement_y, forward_displacement,
      mean_forward_velocity, phase_start, phase_end);
    return 0;
  }
  catch (const std::exception& error) {
    std::fprintf(stderr, "frequency response probe error: %s\n", error.what());
    return 64;
  }
}
