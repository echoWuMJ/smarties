#include "EelEnvironment.h"
#include "EelControlTask.h"
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
  enum class Mode
  {
    direct_ratio,
    task_driven
  };

  std::string input_file;
  std::string task_file;
  double ratio = 0.0;
  double action = 0.0;
  unsigned decisions = 0;
  double direction_x = 0.0;
  double direction_y = 0.0;
  bool has_ratio = false;
  bool has_action = false;
  bool has_direction_x = false;
  bool has_direction_y = false;
  bool fault_after_initialize = false;
  Mode mode = Mode::direct_ratio;
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
    else if (argument == "--task-file") {
      if (++i >= argc) throw std::invalid_argument("missing value after --task-file");
      options.task_file = argv[i];
    }
    else if (argument == "--action") {
      if (++i >= argc) throw std::invalid_argument("missing value after --action");
      options.action = parseFiniteDouble(argv[i], "--action");
      options.has_action = true;
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
    else if (argument == "--fault-after-initialize") {
      options.fault_after_initialize = true;
    }
    else {
      throw std::invalid_argument("unknown frequency probe option: " + argument);
    }
  }

  if (options.input_file.empty())
    throw std::invalid_argument("--input-file is required");
  if (options.decisions == 0)
    throw std::invalid_argument("--decisions is required");
  if (options.has_ratio && !options.task_file.empty())
    throw std::invalid_argument("--ratio and --task-file are mutually exclusive");
  if (!options.task_file.empty()) {
    options.mode = ProbeOptions::Mode::task_driven;
    if (!options.has_action)
      throw std::invalid_argument("--action is required in task mode");
    if (options.has_direction_x || options.has_direction_y)
      throw std::invalid_argument("direction components are only valid in direct mode");
  }
  else {
    options.mode = ProbeOptions::Mode::direct_ratio;
    if (options.has_action)
      throw std::invalid_argument("--action is only valid with --task-file");
    if (!options.has_ratio || options.ratio <= 0.0)
      throw std::invalid_argument("--ratio must be finite and positive");
    if (!options.has_direction_x || !options.has_direction_y)
      throw std::invalid_argument("both direction components are required");
    const double direction_norm =
      std::hypot(options.direction_x, options.direction_y);
    if (!std::isfinite(direction_norm) ||
        std::abs(direction_norm - 1.0) > 1.0e-12)
      throw std::invalid_argument("probe direction must be a finite unit vector");
  }
  return options;
}

void runDirectRatioProbe(const ProbeOptions& options,
                         ibamr_smarties::eel2d::EelEnvironment& environment)
{
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
}

void runTaskDrivenProbe(const ProbeOptions& options,
                        const ibamr_smarties::eel2d::EelTaskConfig& config,
                        ibamr_smarties::eel2d::EelEnvironment& environment,
                        const int world_rank,
                        const int world_size)
{
  using namespace ibamr_smarties::eel2d;
  EelControlTask task(config);
  const double summary_start_time = environment.currentTime();
  const std::array<double, 2> summary_start_com =
    environment.currentCenterOfMass();
  const std::size_t lagrangian_points =
    environment.globalLagrangianPointCount();
  unsigned completed_decisions = 0;
  unsigned completed_steps = 0;
  RewardBreakdown cumulative_reward = { 0.0, 0.0, 0.0, 0.0 };

  for (; completed_decisions < options.decisions; ++completed_decisions) {
    if (!environment.stepsRemaining())
      throw std::runtime_error("eel simulation ended during fixed-action probe");
    const ControlDecision decision = task.applyAction(options.action);
    environment.setTailBeatFrequencyRatio(decision.applied_ratio);
    const ControlIntervalResult interval =
      environment.advanceControlInterval(task.controlInterval());
    const double forward_velocity = forwardVelocity(interval, config);
    const double phase_end = environment.currentTailBeatPhase();
    const EelVelocityProbeSample probe_sample =
      environment.sampleVelocityProbes();
    const EelState state =
      task.makeState(forward_velocity, phase_end, probe_sample.velocities);
    const RewardBreakdown reward =
      task.reward(forward_velocity, decision.previous_ratio);
    for (const double value : state) {
      if (!std::isfinite(value))
        throw std::runtime_error("fixed-action probe produced non-finite state");
    }
    if (!std::isfinite(reward.tracking) || !std::isfinite(reward.frequency) ||
        !std::isfinite(reward.smoothness) || !std::isfinite(reward.total))
      throw std::runtime_error("fixed-action probe produced non-finite reward");

    const double elapsed_time = interval.end_time - interval.start_time;
    const double displacement_x = interval.end_com[0] - interval.start_com[0];
    const double displacement_y = interval.end_com[1] - interval.start_com[1];
    const double forward_displacement =
      displacement_x * config.forward_direction_x +
      displacement_y * config.forward_direction_y;
    if (!std::isfinite(elapsed_time) || elapsed_time <= 0.0 ||
        !std::isfinite(displacement_x) || !std::isfinite(displacement_y) ||
        !std::isfinite(forward_displacement) ||
        !std::isfinite(forward_velocity) || !std::isfinite(phase_end))
      throw std::runtime_error("fixed-action probe produced non-finite output");

    completed_steps += interval.ibamr_steps;
    cumulative_reward.tracking += reward.tracking;
    cumulative_reward.frequency += reward.frequency;
    cumulative_reward.smoothness += reward.smoothness;
    cumulative_reward.total += reward.total;
    if (world_rank == 0) {
      std::printf(
        "EEL_FIXED_ACTION_STEP decision=%u environment_ranks=%d action=%.17g "
        "target_ratio=%.17g previous_ratio=%.17g applied_ratio=%.17g "
        "start_time=%.17g end_time=%.17g ibamr_steps=%u "
        "start_com_x=%.17g start_com_y=%.17g end_com_x=%.17g end_com_y=%.17g "
        "displacement_x=%.17g displacement_y=%.17g "
        "forward_displacement=%.17g forward_velocity=%.17g phase_end=%.17g "
        "lagrangian_points=%zu reward_tracking=%.17g reward_frequency=%.17g "
        "reward_smoothness=%.17g reward_total=%.17g\n",
        completed_decisions + 1, world_size, options.action,
        decision.target_ratio, decision.previous_ratio, decision.applied_ratio,
        interval.start_time, interval.end_time, interval.ibamr_steps,
        interval.start_com[0], interval.start_com[1], interval.end_com[0],
        interval.end_com[1], displacement_x, displacement_y,
        forward_displacement, forward_velocity, phase_end, lagrangian_points,
        reward.tracking, reward.frequency, reward.smoothness, reward.total);
      std::fflush(stdout);
    }
  }

  const double summary_end_time = environment.currentTime();
  const std::array<double, 2> summary_end_com =
    environment.currentCenterOfMass();
  const double elapsed_time = summary_end_time - summary_start_time;
  const double displacement_x = summary_end_com[0] - summary_start_com[0];
  const double displacement_y = summary_end_com[1] - summary_start_com[1];
  const double forward_displacement =
    displacement_x * config.forward_direction_x +
    displacement_y * config.forward_direction_y;
  const double final_phase = environment.currentTailBeatPhase();
  if (!std::isfinite(elapsed_time) || elapsed_time <= 0.0 ||
      !std::isfinite(displacement_x) || !std::isfinite(displacement_y) ||
      !std::isfinite(forward_displacement) || !std::isfinite(final_phase))
    throw std::runtime_error("fixed-action probe produced non-finite summary");

  environment.shutdown();
  if (world_rank == 0) {
    std::printf(
      "EEL_FIXED_ACTION_SUMMARY environment_ranks=%d decisions=%u "
      "ibamr_steps=%u elapsed_time=%.17g displacement_x=%.17g "
      "displacement_y=%.17g forward_displacement=%.17g final_phase=%.17g "
      "lagrangian_points=%zu reward_tracking=%.17g reward_frequency=%.17g "
      "reward_smoothness=%.17g reward_total=%.17g\n",
      world_size, completed_decisions, completed_steps, elapsed_time,
      displacement_x, displacement_y, forward_displacement, final_phase,
      lagrangian_points, cumulative_reward.tracking,
      cumulative_reward.frequency, cumulative_reward.smoothness,
      cumulative_reward.total);
    std::fflush(stdout);
  }
}
} // namespace

int main(int argc, char** argv)
{
  try {
    const ProbeOptions options = parseOptions(argc, argv);
    ibamr_smarties::eel2d::EelTaskConfig task_config;
    if (options.mode == ProbeOptions::Mode::task_driven) {
      task_config = ibamr_smarties::eel2d::loadEelTaskConfig(options.task_file);
      if (task_config.warmup_cycles != 0.0)
        throw std::invalid_argument(
          "task-driven probe requires warmup_cycles=0");
      if (options.decisions > task_config.episode_decisions)
        throw std::invalid_argument(
          "--decisions exceeds task episode_decisions");
    }

    ibamr_smarties::MpiSession mpi(argc, argv);
    int world_rank = 0;
    int world_size = 0;
    MPI_Comm_rank(mpi.world(), &world_rank);
    MPI_Comm_size(mpi.world(), &world_size);
    ibamr_smarties::eel2d::EelEnvironment environment;
    bool environment_initialized = false;
    try {
      environment.initialize(mpi.world(), options.input_file);
      environment_initialized = true;
      if (options.fault_after_initialize)
        throw std::runtime_error(
          "injected failure after IBAMR initialization");
      if (options.mode == ProbeOptions::Mode::task_driven)
        runTaskDrivenProbe(options, task_config, environment, world_rank,
                           world_size);
      else
        runDirectRatioProbe(options, environment);
    }
    catch (const std::exception& error) {
      if (environment_initialized) {
        if (world_rank == 0) {
          std::fprintf(stderr, "frequency response probe fatal error: %s\n",
                       error.what());
          std::fflush(stderr);
        }
        MPI_Abort(MPI_COMM_WORLD, 64);
        std::abort();
      }
      throw;
    }
    return 0;
  }
  catch (const std::exception& error) {
    std::fprintf(stderr, "frequency response probe error: %s\n", error.what());
    return 64;
  }
}
